# frozen_string_literal: true

require 'test_helper'
require_relative 'test_support'
require 'timeout'

class SecretaryMutationNativeWriterGuardTest < ActiveSupport::TestCase
  include SecretaryMutationTestSupport
  self.use_transactional_tests = false
  EXPECTED_NATIVE_DATABASE = 'chrono_flow_native_writer_lock_test_20260928'

  setup do
    expected_database = ENV['NATIVE_WRITER_LOCK_EXPECTED_DATABASE']
    skip 'set NATIVE_WRITER_LOCK_EXPECTED_DATABASE for the dedicated PostgreSQL run' if expected_database.blank?
    assert_equal EXPECTED_NATIVE_DATABASE, expected_database,
      'native writer concurrency tests require the fixed dedicated database name'
    assert_equal expected_database, ActiveRecord::Base.connection_db_config.database,
      'native writer concurrency tests must use the dedicated local test database'
    assert_equal expected_database, ActiveRecord::Base.connection.select_value('SELECT current_database()')
    assert_equal 'PostgreSQL', ActiveRecord::Base.connection.adapter_name
    @now = Time.zone.parse('2026-09-28 09:00:00.123456')
    @clock = -> { @now }
    @user = User.create!(name: 'Native writer owner',
      email: "native-writer-#{SecureRandom.hex(6)}@example.test", password: 'Password-123!',
      identity_issuer: TEST_IDENTITY_ISSUER, identity_subject: "native|#{SecureRandom.uuid}")
    @home_subject = SecureRandom.uuid
    @configuration = mutation_configuration.validate!
    @claims = { 'sub' => @home_subject, 'identity_issuer' => @user.identity_issuer,
      'identity_subject' => @user.identity_subject }
    @event = Event.create!(created_by: @user, title: 'Native target',
      start_at: @now + 1.day, end_at: @now + 1.day + 1.hour, color: '#3b82f6')
  end

  teardown do
    SecretaryMutationProposal.where(user_id: @user&.id).destroy_all
    SecretaryCreationProposal.where(user_id: @user&.id).delete_all
    AiConversation.where(user_id: @user&.id).destroy_all
    Event.where(created_by_id: @user&.id).find_each(&:destroy!)
    User.where(id: @user&.id).delete_all
  end

  test 'waits on the byte-identical target advisory lock and re-fetches after it' do
    holder_ready = Queue.new
    release_holder = Queue.new
    holder_errors = Queue.new
    worker_results = Queue.new
    worker_errors = Queue.new
    before_target_lock = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Event.transaction do
          SecretaryMutation::AdvisoryLock.acquire_target!(event_id: @event.id)
          Event.find(@event.id).update!(title: 'Committed before native writer')
          holder_ready << connection.select_value('SELECT pg_backend_pid()').to_i
          release_holder.pop
        end
      rescue StandardError => error
        holder_errors << error
      end
    end
    holder_pid = Timeout.timeout(5) { holder_ready.pop }

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        worker_pid = connection.select_value('SELECT pg_backend_pid()').to_i
        worker_results << [:pid, worker_pid]
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [@event.id], before_target_locks: -> { before_target_lock << true }
        ) do |events|
          worker_results << [:title, events.fetch(@event.id).title]
        end
      rescue StandardError => error
        worker_errors << error
      end
    end
    worker_pid = Timeout.timeout(5) { worker_results.pop.fetch(1) }
    Timeout.timeout(5) { before_target_lock.pop }
    sleep 0.05
    assert worker.alive?
    release_holder << true
    holder.join
    worker.join

    assert_empty drain(holder_errors)
    assert_empty drain(worker_errors)
    assert_not_equal holder_pid, worker_pid
    assert_equal [:title, 'Committed before native writer'], worker_results.pop
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'reverse-order multi-target writers finish and recheck after the lock wait' do
    second_event = Event.create!(created_by: @user, title: 'Second target',
      start_at: @now + 2.days, end_at: @now + 2.days + 1.hour, color: '#3b82f6')
    event_ids = [@event.id, second_event.id].sort
    holder_ready = Queue.new
    release_holder = Queue.new
    holder_errors = Queue.new
    worker_ready = Queue.new
    worker_before_target_locks = Queue.new
    worker_results = Queue.new
    worker_errors = Queue.new
    verify_calls = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Event.transaction do
          SecretaryMutation::AdvisoryLock.acquire_targets!(event_ids: event_ids)
          Event.find(event_ids.first).update!(title: 'First committed target')
          Event.find(event_ids.last).update!(title: 'Second committed target')
          holder_ready << connection.select_value('SELECT pg_backend_pid()').to_i
          release_holder.pop
        end
      rescue StandardError => error
        holder_errors << error
      end
    end
    holder_pid = Timeout.timeout(5) { holder_ready.pop }

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        worker_ready << connection.select_value('SELECT pg_backend_pid()').to_i
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user,
          event_ids: event_ids.reverse,
          verify_event_ids: lambda do
            verify_calls << true
            Event.where(id: event_ids).order(:id).pluck(:id)
          end,
          before_target_locks: -> { worker_before_target_locks << true }
        ) do |events|
          worker_results << event_ids.map { |event_id| events.fetch(event_id).title }
        end
      rescue StandardError => error
        worker_errors << error
      end
    end
    worker_pid = Timeout.timeout(5) { worker_ready.pop }
    Timeout.timeout(5) { worker_before_target_locks.pop }
    sleep 0.05
    assert worker.alive?
    assert_empty drain(verify_calls), 'target verification must run only after the lock wait'

    release_holder << true
    Timeout.timeout(5) do
      holder.join
      worker.join
    end

    assert_not_equal holder_pid, worker_pid
    assert_empty drain(holder_errors)
    assert_empty drain(worker_errors)
    assert_equal [true], drain(verify_calls)
    assert_equal ['First committed target', 'Second committed target'], drain(worker_results).sole
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'rejects an actor suspended while the guard waits for the User row' do
    holder_ready = Queue.new
    release_holder = Queue.new
    worker_ready = Queue.new
    worker_errors = Queue.new
    entered = Queue.new
    before_user_lock = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        User.transaction do
          User.lock.find(@user.id).update!(status: 'suspended')
          holder_ready << connection.select_value('SELECT pg_backend_pid()').to_i
          release_holder.pop
        end
      end
    end
    holder_pid = Timeout.timeout(5) { holder_ready.pop }

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        worker_pid = connection.select_value('SELECT pg_backend_pid()').to_i
        worker_ready << worker_pid
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [@event.id], before_user_lock: -> { before_user_lock << true }
        ) do
          entered << true
        end
      rescue StandardError => error
        worker_errors << error
      end
    end
    worker_pid = Timeout.timeout(5) { worker_ready.pop }
    Timeout.timeout(5) { before_user_lock.pop }
    sleep 0.05
    assert worker.alive?
    release_holder << true
    holder.join
    worker.join

    assert_not_equal holder_pid, worker_pid
    assert_empty drain(entered)
    assert_instance_of SecretaryMutation::NativeWriterGuard::Forbidden, drain(worker_errors).fetch(0)
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'fails closed when a child target appears while parent deletion waits' do
    initial_target_ids = [@event.id]
    holder_ready = Queue.new
    release_holder = Queue.new
    worker_ready = Queue.new
    worker_errors = Queue.new
    before_user_lock = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(actor: @user, event_ids: [@event.id]) do
          Event.create!(created_by: @user, parent_id: @event.id, title: 'Late child',
            start_at: 2.days.from_now, end_at: 2.days.from_now + 1.hour, color: '#3b82f6')
          holder_ready << connection.select_value('SELECT pg_backend_pid()').to_i
          release_holder.pop
        end
      end
    end
    holder_pid = Timeout.timeout(5) { holder_ready.pop }

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        worker_pid = connection.select_value('SELECT pg_backend_pid()').to_i
        worker_ready << worker_pid
        verify_ids = -> { [@event.id, *Event.where(parent_id: @event.id).order(:id).pluck(:id)] }
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: initial_target_ids, verify_event_ids: verify_ids,
          before_user_lock: -> { before_user_lock << true }
        ) { flunk('changed target set must stop before the writer block') }
      rescue StandardError => error
        worker_errors << error
      end
    end
    worker_pid = Timeout.timeout(5) { worker_ready.pop }
    Timeout.timeout(5) { before_user_lock.pop }
    sleep 0.05
    assert worker.alive?
    release_holder << true
    holder.join
    worker.join

    assert_not_equal holder_pid, worker_pid
    assert_instance_of SecretaryMutation::NativeWriterGuard::TargetSetChanged,
      drain(worker_errors).fetch(0)
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'fails closed when a recommendation delete target disappears while waiting' do
    child = Event.create!(created_by: @user, parent: @event, title: 'Recommendation child',
      start_at: @now + 2.days, end_at: @now + 2.days + 1.hour, color: '#3b82f6')
    initial_target_ids = [@event.id, child.id]
    holder_ready = Queue.new
    release_holder = Queue.new
    holder_errors = Queue.new
    worker_waiting = Queue.new
    worker_errors = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: initial_target_ids
        ) do |events|
          events.fetch(child.id).destroy!
          holder_ready << true
          release_holder.pop
        end
      rescue StandardError => error
        holder_errors << error
      end
    end
    Timeout.timeout(5) { holder_ready.pop }

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        verify_ids = -> { [@event.id, *Event.where(parent_id: @event.id).order(:id).pluck(:id)] }
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: initial_target_ids, require_all: false,
          verify_event_ids: verify_ids, before_user_lock: -> { worker_waiting << true }
        ) { flunk('shrinking target set must stop before recommendation write') }
      rescue StandardError => error
        worker_errors << error
      end
    end
    Timeout.timeout(5) { worker_waiting.pop }
    sleep 0.05
    assert worker.alive?
    release_holder << true
    holder.join
    worker.join

    assert_empty drain(holder_errors)
    assert_instance_of SecretaryMutation::NativeWriterGuard::TargetSetChanged,
      drain(worker_errors).sole
    refute Event.exists?(child.id)
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'group destroy fails closed when a late event association commits while it waits for the group row' do
    other = User.create!(name: 'Late association owner',
      email: "late-association-#{SecureRandom.hex(6)}@example.test", password: 'Password-123!',
      identity_issuer: TEST_IDENTITY_ISSUER, identity_subject: "late|#{SecureRandom.uuid}")
    group = Group.create!(name: 'Late association group', owner_id: @user.id)
    GroupMember.create!(group: group, user: other, role: :member)
    event = Event.create!(created_by: other, title: 'Late grouped event',
      start_at: @now + 3.days, end_at: @now + 3.days + 1.hour, color: '#3b82f6')
    association_ready = Queue.new
    release_association = Queue.new
    association_errors = Queue.new
    destroy_waiting = Queue.new
    destroy_errors = Queue.new

    association = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SecretaryMutation::NativeWriterGuard.with_events(actor: other, event_ids: [event.id]) do
          EventGroup.create!(event: event, group: group)
          association_ready << true
          release_association.pop
        end
      rescue StandardError => error
        association_errors << error
      end
    end
    Timeout.timeout(5) { association_ready.pop }

    destroyer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        event_ids = EventGroup.where(group_id: group.id).order(:event_id).pluck(:event_id)
        verify_ids = -> { EventGroup.where(group_id: group.id).order(:event_id).pluck(:event_id) }
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: event_ids, verify_event_ids: verify_ids
        ) do
          destroy_waiting << true
          locked_group = Group.lock.find(group.id)
          current_ids = EventGroup.where(group_id: locked_group.id).order(:event_id).pluck(:event_id)
          unless current_ids == event_ids
            raise SecretaryMutation::NativeWriterGuard::TargetSetChanged,
              'group event targets changed while waiting for the group row lock'
          end
          flunk('late association must stop before group destroy')
        end
      rescue StandardError => error
        destroy_errors << error
      end
    end
    Timeout.timeout(5) { destroy_waiting.pop }
    sleep 0.05
    assert destroyer.alive?
    release_association << true
    association.join
    destroyer.join

    assert_empty drain(association_errors)
    assert_instance_of SecretaryMutation::NativeWriterGuard::TargetSetChanged,
      drain(destroy_errors).sole
    assert Group.exists?(group.id)
    assert EventGroup.exists?(event_id: event.id, group_id: group.id)
  ensure
    release_association << true if defined?(association) && association&.alive?
    association&.join
    destroyer&.join
    EventGroup.where(group_id: group&.id).delete_all if group&.id
    GroupMember.where(group_id: group&.id).delete_all if group&.id
    group&.destroy! if group&.persisted?
    event&.destroy! if event&.persisted?
    other&.destroy! if other&.persisted?
  end

  test 'event request rejects an admin demoted while it waits for permission rows' do
    owner = create_aux_user('permission-owner')
    target = create_aux_user('permission-target')
    group = Group.create!(name: 'Permission race group', owner_id: owner.id)
    GroupMember.create!(group: group, user: owner, role: :admin)
    actor_member = GroupMember.create!(group: group, user: @user, role: :admin)
    GroupMember.create!(group: group, user: target, role: :member)
    event = Event.create!(created_by: @user, title: 'Permission race event',
      start_at: @now + 4.days, end_at: @now + 4.days + 1.hour, color: '#3b82f6')
    EventGroup.create!(event: event, group: group)
    assert actor_member.admin?
    demotion_locked = Queue.new
    release_demotion = Queue.new
    demotion_errors = Queue.new
    request_waiting = Queue.new
    request_errors = Queue.new

    demoter = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        member_ids = GroupMember.where(group_id: group.id).pluck(:user_id)
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: owner, event_ids: [], user_ids: member_ids
        ) do
          Group.lock.find(group.id)
          members = GroupMember.where(group_id: group.id).order(:id).lock.to_a
          members.find { |member| member.user_id == @user.id }.update!(role: :member)
          demotion_locked << true
          release_demotion.pop
        end
      rescue StandardError => error
        demotion_errors << error
      end
    end
    Timeout.timeout(5) { demotion_locked.pop }

    requester = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [event.id], user_ids: [target.id],
          before_user_lock: -> { request_waiting << true }
        ) do
          locked_group = Group.lock.find(group.id)
          membership = GroupMember.where(group_id: group.id, user_id: @user.id).lock.first
          unless locked_group.owner_id == @user.id || membership&.admin?
            raise SecretaryMutation::NativeWriterGuard::Forbidden
          end
          EventRequest.create!(event: event, group: group, target_user: target,
            requested_by: @user, status: :pending)
        end
      rescue StandardError => error
        request_errors << error
      end
    end
    Timeout.timeout(5) { request_waiting.pop }
    sleep 0.05
    assert requester.alive?
    release_demotion << true
    demoter.join
    requester.join

    assert_empty drain(demotion_errors)
    assert_instance_of SecretaryMutation::NativeWriterGuard::Forbidden,
      drain(request_errors).sole
    assert actor_member.reload.member?
    refute EventRequest.exists?(event_id: event.id, target_user_id: target.id)
  ensure
    release_demotion << true if defined?(demoter) && demoter&.alive?
    demoter&.join
    requester&.join
    EventRequest.where(event_id: event&.id).delete_all if event&.id
    EventGroup.where(event_id: event&.id).delete_all if event&.id
    GroupMember.where(group_id: group&.id).delete_all if group&.id
    group&.destroy! if group&.persisted?
    event&.destroy! if event&.persisted?
    [owner, target].compact.each { |user| user.destroy! if user.persisted? }
  end

  test 'owner transfer and event request serialize without reversing group-member locks' do
    next_owner = create_aux_user('next-owner')
    target = create_aux_user('request-target')
    group = Group.create!(name: 'Transfer order group', owner_id: @user.id)
    GroupMember.create!(group: group, user: @user, role: :admin)
    GroupMember.create!(group: group, user: next_owner, role: :member)
    GroupMember.create!(group: group, user: target, role: :member)
    event = Event.create!(created_by: @user, title: 'Transfer order event',
      start_at: @now + 5.days, end_at: @now + 5.days + 1.hour, color: '#3b82f6')
    EventGroup.create!(event: event, group: group)
    transfer_locked = Queue.new
    release_transfer = Queue.new
    transfer_errors = Queue.new
    request_waiting = Queue.new
    request_errors = Queue.new

    transfer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        member_ids = GroupMember.where(group_id: group.id).pluck(:user_id)
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [], user_ids: member_ids
        ) do
          locked_group = Group.lock.find(group.id)
          members = GroupMember.where(group_id: group.id).order(:id).lock.to_a
          members.select { |member| [@user.id, next_owner.id].include?(member.user_id) }
            .each { |member| member.update!(role: :admin) }
          locked_group.update!(owner_id: next_owner.id)
          transfer_locked << true
          release_transfer.pop
        end
      rescue StandardError => error
        transfer_errors << error
      end
    end
    Timeout.timeout(5) { transfer_locked.pop }

    requester = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [event.id], user_ids: [target.id],
          before_user_lock: -> { request_waiting << true }
        ) do
          locked_group = Group.lock.find(group.id)
          membership = GroupMember.where(group_id: group.id, user_id: @user.id).lock.first
          unless locked_group.owner_id == @user.id || membership&.admin?
            raise SecretaryMutation::NativeWriterGuard::Forbidden
          end
          EventRequest.create!(event: event, group: group, target_user: target,
            requested_by: @user, status: :pending)
        end
      rescue StandardError => error
        request_errors << error
      end
    end
    Timeout.timeout(5) { request_waiting.pop }
    sleep 0.05
    assert requester.alive?
    release_transfer << true
    Timeout.timeout(5) { transfer.join }
    Timeout.timeout(5) { requester.join }

    assert_empty drain(transfer_errors)
    assert_empty drain(request_errors)
    assert_equal next_owner.id, group.reload.owner_id
    assert GroupMember.find_by!(group: group, user: @user).admin?
    assert EventRequest.exists?(event_id: event.id, target_user_id: target.id,
      requested_by_id: @user.id)
  ensure
    release_transfer << true if defined?(transfer) && transfer&.alive?
    transfer&.join
    requester&.join
    EventRequest.where(event_id: event&.id).delete_all if event&.id
    EventGroup.where(event_id: event&.id).delete_all if event&.id
    GroupMember.where(group_id: group&.id).delete_all if group&.id
    group&.destroy! if group&.persisted?
    event&.destroy! if event&.persisted?
    [next_owner, target].compact.each { |user| user.destroy! if user.persisted? }
  end

  test 'native update first makes the waiting mutation conflict without duplicate effects' do
    @event.update!(title: '競合予定')
    ready = propose_update('競合予定のタイトルをMutation変更に変更')
    native_locked = Queue.new
    release_native = Queue.new
    native_results = Queue.new
    native_errors = Queue.new
    mutation_waiting = Queue.new
    mutation_results = Queue.new
    mutation_errors = Queue.new

    native = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(actor: @user, event_ids: [@event.id]) do |events|
          events.fetch(@event.id).update!(title: 'Native変更')
          native_locked << connection.select_value('SELECT pg_backend_pid()').to_i
          release_native.pop
        end
        native_results << true
      rescue StandardError => error
        native_errors << error
      end
    end
    native_pid = Timeout.timeout(5) { native_locked.pop }

    mutation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        service = proposal_service(before_user_lock: lambda do |phase, user_id|
          mutation_waiting << connection.select_value('SELECT pg_backend_pid()').to_i if phase == 'execute' && user_id == @user.id
        end)
        mutation_results << execute_update(ready, service: service)
      rescue StandardError => error
        mutation_errors << error
      end
    end
    mutation_pid = Timeout.timeout(5) { mutation_waiting.pop }
    sleep 0.05
    assert mutation.alive?
    release_native << true
    native.join
    mutation.join

    assert_not_equal native_pid, mutation_pid
    assert_equal [true], drain(native_results)
    assert_empty drain(native_errors)
    assert_empty drain(mutation_errors)
    assert_equal 'conflicted', drain(mutation_results).sole.fetch('status')
    assert_equal 'Native変更', @event.reload.title
    assert_completion_effect_counts(ready, completed: 0)
  ensure
    release_native << true if defined?(native) && native&.alive?
    native&.join
    mutation&.join
  end

  test 'mutation first completes once before the waiting native delete' do
    @event.update!(title: '順序予定')
    ready = propose_update('順序予定のタイトルをMutation先行に変更')
    mutation_locked = Queue.new
    release_mutation = Queue.new
    mutation_results = Queue.new
    mutation_errors = Queue.new
    native_waiting = Queue.new
    native_results = Queue.new
    native_errors = Queue.new

    mutation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        service = proposal_service(before_event_lock: lambda do |event_id|
          next unless event_id == @event.id

          mutation_locked << connection.select_value('SELECT pg_backend_pid()').to_i
          release_mutation.pop
        end)
        mutation_results << execute_update(ready, service: service)
      rescue StandardError => error
        mutation_errors << error
      end
    end
    mutation_pid = Timeout.timeout(5) { mutation_locked.pop }

    native = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [@event.id],
          before_user_lock: -> { native_waiting << connection.select_value('SELECT pg_backend_pid()').to_i }
        ) do |events|
          events.fetch(@event.id).destroy!
          native_results << true
        end
      rescue StandardError => error
        native_errors << error
      end
    end
    native_pid = Timeout.timeout(5) { native_waiting.pop }
    sleep 0.05
    assert native.alive?
    release_mutation << true
    mutation.join
    native.join

    assert_not_equal mutation_pid, native_pid
    assert_empty drain(mutation_errors)
    assert_equal 'completed', drain(mutation_results).sole.fetch('status')
    assert_empty drain(native_errors)
    assert_equal [true], drain(native_results)
    refute Event.exists?(@event.id)
    assert_completion_effect_counts(ready, completed: 1)
  ensure
    release_mutation << true if defined?(mutation) && mutation&.alive?
    mutation&.join
    native&.join
  end

  test 'native delete first prevents the waiting mutation update without side effects' do
    @event.update!(title: '削除競合予定')
    ready = propose_update('削除競合予定のタイトルを更新不可に変更')
    native_locked = Queue.new
    release_native = Queue.new
    native_errors = Queue.new
    mutation_waiting = Queue.new
    mutation_results = Queue.new
    mutation_errors = Queue.new

    native = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(actor: @user, event_ids: [@event.id]) do |events|
          events.fetch(@event.id).destroy!
          native_locked << connection.select_value('SELECT pg_backend_pid()').to_i
          release_native.pop
        end
      rescue StandardError => error
        native_errors << error
      end
    end
    native_pid = Timeout.timeout(5) { native_locked.pop }

    mutation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        service = proposal_service(before_user_lock: lambda do |phase, user_id|
          mutation_waiting << connection.select_value('SELECT pg_backend_pid()').to_i if phase == 'execute' && user_id == @user.id
        end)
        mutation_results << execute_update(ready, service: service)
      rescue StandardError => error
        mutation_errors << error
      end
    end
    mutation_pid = Timeout.timeout(5) { mutation_waiting.pop }
    sleep 0.05
    assert mutation.alive?
    release_native << true
    native.join
    mutation.join

    assert_not_equal native_pid, mutation_pid
    assert_empty drain(native_errors)
    assert_empty drain(mutation_results)
    error = drain(mutation_errors).sole
    assert_instance_of SecretaryMutation::Error, error
    assert_equal 'target_changed', error.code
    refute Event.exists?(@event.id)
    assert_completion_effect_counts(ready, completed: 0)
  ensure
    release_native << true if defined?(native) && native&.alive?
    native&.join
    mutation&.join
  end

  test 'same-count different-id relationship replacement conflicts after the lock wait' do
    @event.update!(title: '関係競合予定')
    original = EventParticipant.create!(event: @event, user: @user, source: :copied)
    ready = propose_update('関係競合予定のタイトルを関係変更後に変更')
    native_locked = Queue.new
    release_native = Queue.new
    native_errors = Queue.new
    mutation_waiting = Queue.new
    mutation_results = Queue.new
    mutation_errors = Queue.new

    native = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SecretaryMutation::NativeWriterGuard.with_events(actor: @user, event_ids: [@event.id]) do
          original.destroy!
          EventParticipant.create!(event: @event, user: @user, source: :copied)
          native_locked << true
          release_native.pop
        end
      rescue StandardError => error
        native_errors << error
      end
    end
    Timeout.timeout(5) { native_locked.pop }

    mutation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        service = proposal_service(before_user_lock: lambda do |phase, user_id|
          mutation_waiting << true if phase == 'execute' && user_id == @user.id
        end)
        mutation_results << execute_update(ready, service: service)
      rescue StandardError => error
        mutation_errors << error
      end
    end
    Timeout.timeout(5) { mutation_waiting.pop }
    sleep 0.05
    assert mutation.alive?
    release_native << true
    native.join
    mutation.join

    assert_empty drain(native_errors)
    assert_empty drain(mutation_errors)
    result = drain(mutation_results).sole
    assert_equal 'conflicted', result.fetch('status')
    assert_equal 'relationships_changed', result.fetch('reason_code')
    assert_equal 1, EventParticipant.where(event_id: @event.id, user_id: @user.id).count
    refute EventParticipant.exists?(original.id)
    assert_completion_effect_counts(ready, completed: 0)
  ensure
    release_native << true if defined?(native) && native&.alive?
    native&.join
    mutation&.join
  end

  test 'lock timeout rolls back and a later native writer can reacquire exactly once' do
    holder_ready = Queue.new
    release_holder = Queue.new
    holder_errors = Queue.new
    timed_out_errors = Queue.new
    entered = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Event.transaction do
          SecretaryMutation::AdvisoryLock.acquire_target!(event_id: @event.id)
          holder_ready << true
          release_holder.pop
        end
      rescue StandardError => error
        holder_errors << error
      end
    end
    Timeout.timeout(5) { holder_ready.pop }

    timed_out = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [@event.id],
          before_target_locks: -> { connection.execute("SET LOCAL lock_timeout = '100ms'") }
        ) do |events|
          entered << true
          events.fetch(@event.id).update!(title: '書き込まれない')
        end
      rescue StandardError => error
        timed_out_errors << error
      end
    end
    timed_out.join

    assert_empty drain(entered)
    assert_instance_of ActiveRecord::LockWaitTimeout, drain(timed_out_errors).sole
    assert_equal 'Native target', @event.reload.title
    release_holder << true
    holder.join
    assert_empty drain(holder_errors)

    writes = 0
    SecretaryMutation::NativeWriterGuard.with_events(actor: @user, event_ids: [@event.id]) do |events|
      events.fetch(@event.id).update!(title: '再取得成功')
      writes += 1
    end
    assert_equal 1, writes
    assert_equal '再取得成功', @event.reload.title
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    timed_out&.join
  end

  test 'reverse-order multi-target timeout rolls back earlier locks and can reacquire' do
    second_event = Event.create!(created_by: @user, title: 'Second target',
      start_at: @now + 2.days, end_at: @now + 2.days + 1.hour, color: '#3b82f6')
    event_ids = [@event.id, second_event.id].sort
    low_id, high_id = event_ids
    holder_ready = Queue.new
    release_holder = Queue.new
    holder_errors = Queue.new
    timed_out_errors = Queue.new
    entered = Queue.new
    worker_before_target_locks = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Event.transaction do
          SecretaryMutation::AdvisoryLock.acquire_target!(event_id: high_id)
          holder_ready << connection.select_value('SELECT pg_backend_pid()').to_i
          release_holder.pop
        end
      rescue StandardError => error
        holder_errors << error
      end
    end
    holder_pid = Timeout.timeout(5) { holder_ready.pop }

    timed_out = Thread.new do
      timed_out_pid = nil
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        timed_out_pid = connection.select_value('SELECT pg_backend_pid()').to_i
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user,
          event_ids: event_ids.reverse,
          before_target_locks: lambda do
            connection.execute("SET LOCAL lock_timeout = '2s'")
            worker_before_target_locks << true
          end
        ) do |events|
          entered << true
          events.each_value { |event| event.update!(title: '書き込まれない') }
        end
        timed_out_pid
      rescue StandardError => error
        timed_out_errors << [timed_out_pid, error]
      end
    end
    Timeout.timeout(5) { worker_before_target_locks.pop }

    low_lock_observed = Timeout.timeout(1.5) do
      loop do
        low_available = nil
        ActiveRecord::Base.connection_pool.with_connection do
          Event.transaction do
            low_available = SecretaryMutation::AdvisoryLock.try_target(event_id: low_id)
            raise ActiveRecord::Rollback
          end
        end
        break true unless low_available

        sleep 0.01
      end
    end
    assert low_lock_observed,
      'reversed input must acquire the low-id target before waiting on the held high-id target'
    Timeout.timeout(5) { timed_out.join }

    assert_empty drain(entered)
    timed_out_pid, timeout_error = drain(timed_out_errors).sole
    assert_not_equal holder_pid, timed_out_pid
    assert_instance_of ActiveRecord::LockWaitTimeout, timeout_error
    refute_instance_of ActiveRecord::Deadlocked, timeout_error
    assert_equal ['Native target', 'Second target'],
      Event.where(id: event_ids).order(:id).pluck(:title)

    rollback_check = ActiveRecord::Base.connection_pool.with_connection do
      Event.transaction do
        result = [
          SecretaryMutation::AdvisoryLock.try_target(event_id: low_id),
          SecretaryMutation::AdvisoryLock.try_target(event_id: high_id)
        ]
        raise ActiveRecord::Rollback, result.inspect unless result == [true, false]

        result
      end
    end
    assert_equal [true, false], rollback_check,
      'timeout rollback must release the earlier low-id lock while the holder keeps the high-id lock'

    release_holder << true
    Timeout.timeout(5) { holder.join }
    assert_empty drain(holder_errors)

    writes = 0
    SecretaryMutation::NativeWriterGuard.with_events(
      actor: @user, event_ids: event_ids.reverse
    ) do |events|
      events.fetch(low_id).update!(title: 'First reacquired target')
      events.fetch(high_id).update!(title: 'Second reacquired target')
      writes += 1
    end
    assert_equal 1, writes
    assert_equal ['First reacquired target', 'Second reacquired target'],
      Event.where(id: event_ids).order(:id).pluck(:title)
  ensure
    release_holder << true if defined?(holder) && holder&.alive?
    holder&.join
    timed_out&.join
  end

  test 'native creation first makes secretary creation recheck the time conflict' do
    target_start = Time.zone.parse('2026-10-05 10:00:00')
    target_end = target_start + 1.hour
    creation_service = SecretaryCreation::Proposals.new(
      parser: lambda do |**|
        { status: 'ready', question: nil, details: {
          'kind' => 'event', 'title' => '作成競合予定', 'description' => '', 'location' => '',
          'start_at' => target_start.iso8601, 'end_at' => target_end.iso8601,
          'all_day' => false, 'time_zone' => 'Asia/Tokyo'
        } }
      end,
      clock: @clock
    )
    creation_claims = @claims.slice('sub', 'identity_issuer', 'identity_subject')
    ready = creation_service.call(operation: 'propose', request: creation_propose_request,
      claims: creation_claims, proposal_id: nil)
    assert_equal 'ready', ready.fetch('status')

    native_locked = Queue.new
    release_native = Queue.new
    native_errors = Queue.new
    creation_started = Queue.new
    creation_results = Queue.new
    creation_errors = Queue.new

    native = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(actor: @user, event_ids: []) do
          Event.create!(created_by: @user, title: '通常作成先行',
            start_at: target_start + 15.minutes, end_at: target_end - 15.minutes, color: '#3b82f6')
          native_locked << connection.select_value('SELECT pg_backend_pid()').to_i
          release_native.pop
        end
      rescue StandardError => error
        native_errors << error
      end
    end
    native_pid = Timeout.timeout(5) { native_locked.pop }

    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        creation_started << connection.select_value('SELECT pg_backend_pid()').to_i
        creation_results << creation_service.call(operation: 'create',
          request: creation_confirm_request(ready), claims: creation_claims,
          proposal_id: ready.fetch('proposal_id'))
      rescue StandardError => error
        creation_errors << error
      end
    end
    creation_pid = Timeout.timeout(5) { creation_started.pop }
    sleep 0.05
    assert creation.alive?
    release_native << true
    native.join
    creation.join

    assert_not_equal native_pid, creation_pid
    assert_empty drain(native_errors)
    assert_empty drain(creation_results)
    error = drain(creation_errors).sole
    assert_instance_of SecretaryCreation::Error, error
    assert_equal 'proposal_changed', error.code
    assert_equal 1, Event.where(created_by_id: @user.id, title: '通常作成先行').count
    proposal = SecretaryCreationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 'ready', proposal.status
    assert_nil proposal.created_event_id
    assert_nil proposal.result_id
  ensure
    release_native << true if defined?(native) && native&.alive?
    native&.join
    creation&.join
  end

  test 'travel acceptance rechecks time conflicts after a mutation finishes first' do
    @event.update!(title: '移動競合予定')
    ready = propose_update(
      '「移動競合予定」を変更。2026-10-05T10:15:00+09:00から2026-10-05T10:45:00+09:00'
    )
    assert_equal ['schedule'], ready.fetch('changed_fields')
    recommendation, provider = travel_recommendation(
      start_at: Time.zone.parse('2026-10-05 10:00:00'),
      end_at: Time.zone.parse('2026-10-05 11:00:00')
    )

    mutation_locked = Queue.new
    release_mutation = Queue.new
    mutation_results = Queue.new
    mutation_errors = Queue.new
    travel_waiting = Queue.new
    travel_results = Queue.new
    travel_errors = Queue.new

    mutation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        service = proposal_service(before_event_lock: lambda do |event_id|
          next unless event_id == @event.id

          mutation_locked << connection.select_value('SELECT pg_backend_pid()').to_i
          release_mutation.pop
        end)
        mutation_results << execute_update(ready, service: service)
      rescue StandardError => error
        mutation_errors << error
      end
    end
    mutation_pid = Timeout.timeout(5) { mutation_locked.pop }

    travel = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        SecretaryMutation::NativeWriterGuard.with_events(
          actor: @user, event_ids: [],
          before_user_lock: -> { travel_waiting << connection.select_value('SELECT pg_backend_pid()').to_i }
        ) do
          locked_recommendation = AiRecommendation.lock.find(recommendation.id)
          TravelRouting::RecommendationGuard.new(user: @user, now: @now, provider: provider)
            .revalidate!(locked_recommendation)
          event_attrs = locked_recommendation.payload.fetch('events').sole
          Event.create!(created_by: @user, title: '移動', start_at: Time.iso8601(event_attrs.fetch('start_at')),
            end_at: Time.iso8601(event_attrs.fetch('end_at')), all_day: false, color: '#3b82f6')
          travel_results << true
        end
      rescue StandardError => error
        travel_errors << error
      end
    end
    travel_pid = Timeout.timeout(5) { travel_waiting.pop }
    sleep 0.05
    assert travel.alive?
    release_mutation << true
    mutation.join
    travel.join

    assert_not_equal mutation_pid, travel_pid
    assert_empty drain(mutation_errors)
    assert_equal 'completed', drain(mutation_results).sole.fetch('status')
    assert_empty drain(travel_results)
    assert_instance_of TravelRouting::RecommendationGuard::Rejected, drain(travel_errors).sole
    assert_equal 0, Event.where(created_by_id: @user.id, title: '移動').count
    assert_completion_effect_counts(ready, completed: 1)
  ensure
    release_mutation << true if defined?(mutation) && mutation&.alive?
    mutation&.join
    travel&.join
  end

  private

  def proposal_service(**hooks)
    SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock, **hooks)
  end

  def propose_update(message)
    request = mutation_propose(operation: 'event.update', message: message)
    proposal_service.call(phase: 'propose', request: request, claims: @claims,
      proposal_id: nil, operation: 'event.update')
  end

  def execute_update(ready, service: proposal_service)
    service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
      proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
  end

  def assert_completion_effect_counts(ready, completed:)
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal completed,
      proposal.secretary_mutation_audits.where(event_type: 'mutation_completed').count
    assert_equal completed, proposal.secretary_mutation_outbox_entries.count
  end

  def creation_propose_request
    { 'proposal_id' => nil, 'expected_revision' => nil, 'message' => '作成競合予定を追加',
      'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid }
  end

  def creation_confirm_request(ready)
    { 'proposal_id' => ready.fetch('proposal_id'), 'revision' => ready.fetch('revision'),
      'content_digest' => ready.fetch('content_digest'), 'idempotency_key' => SecureRandom.uuid,
      'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid }
  end

  def travel_recommendation(start_at:, end_at:)
    result = TravelRouting::GoogleRoutesProvider::Result.new(
      code: 'ok', duration_seconds: (end_at - start_at).to_i, distance_meters: 5_000,
      walking_seconds: 0, departure_time: start_at.iso8601, arrival_time: end_at.iso8601,
      attribution: 'Google Maps'
    )
    candidate = {
      'kind' => 'draft_event', 'title' => '移動',
      'payload' => {
        'events' => [{ 'title' => '移動', 'start_at' => start_at.iso8601,
          'end_at' => end_at.iso8601, 'all_day' => false }],
        'routing' => {
          'source' => 'google_routes',
          'request' => { 'origin' => 'Synthetic origin', 'destination' => 'Synthetic destination',
            'mode' => 'DRIVE', 'departure_time' => start_at.iso8601 },
          'result' => result.to_h.stringify_keys.except('code', 'attribution'),
          'checked_at' => @now.iso8601
        }
      }
    }
    prepared = TravelRouting::RecommendationGuard.prepare_response(
      { recommendations: [candidate], routes_provenance: TravelRouting::RecommendationGuard::LOCAL_PROVENANCE },
      user: @user, now: @now
    )
    attributes = prepared.fetch(:recommendations).sole
    conversation = AiConversation.create!(user: @user, scope_type: 'home')
    recommendation = conversation.ai_recommendations.create!(
      user: @user, kind: attributes.fetch('kind'), title: attributes.fetch('title'),
      payload: attributes.fetch('payload')
    )
    provider = Object.new
    provider.define_singleton_method(:call) { |**| result }
    [recommendation, provider]
  end

  def create_aux_user(label)
    User.create!(name: label, email: "#{label}-#{SecureRandom.hex(6)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "#{label}|#{SecureRandom.uuid}")
  end

  def drain(queue)
    values = []
    values << queue.pop(true) while true
  rescue ThreadError
    values
  end
end
