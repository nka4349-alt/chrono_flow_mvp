# frozen_string_literal: true

require 'test_helper'
require_relative 'test_support'
require 'timeout'

class SecretaryMutationConcurrencyTest < ActiveSupport::TestCase
  include SecretaryMutationTestSupport
  self.use_transactional_tests = false

  setup do
    @now = Time.zone.parse('2026-09-21 09:00:00.123456')
    @clock = -> { @now }
    @user = User.create!(name: 'Concurrency owner', email: "concurrency-#{SecureRandom.hex(6)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "concurrency|#{SecureRandom.uuid}")
    @home_subject = SecureRandom.uuid
    @configuration = mutation_configuration.validate!
    @claims = { 'sub' => @home_subject, 'identity_issuer' => @user.identity_issuer,
      'identity_subject' => @user.identity_subject }
  end

  teardown do
    SecretaryMutationProposal.where(user_id: @user&.id).delete_all
    Event.where(created_by_id: @user&.id).delete_all
    User.where(id: @user&.id).delete_all
  end

  test 'same-key concurrent confirms use two PostgreSQL connections and execute once' do
    Event.create!(created_by: @user, title: '並行予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('並行予定のタイトルを並行予定改に変更')
    confirmation = mutation_confirm(ready, idempotency_key: SecureRandom.uuid)

    results, errors, backend_pids = concurrently(2) do
      service.call(phase: 'execute', request: confirmation, claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end

    assert_empty errors
    assert_equal 2, backend_pids.uniq.length
    assert_equal 1, results.map { |item| item.dig('receipt', 'result_id') }.uniq.length
    assert_equal '並行予定改', Event.find_by!(created_by_id: @user.id).title
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 1, proposal.secretary_mutation_audits.where(event_type: 'mutation_completed').count
    assert_equal 1, proposal.secretary_mutation_outbox_entries.count
  end

  test 'confirm versus cancel serializes to one terminal outcome without a partial write' do
    Event.create!(created_by: @user, title: '競合予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('競合予定のタイトルを競合予定改に変更')
    confirmation = mutation_confirm(ready)
    cancellation = mutation_cancel(ready)
    actions = [
      -> { service.call(phase: 'execute', request: confirmation, claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update') },
      -> { service.call(phase: 'cancel', request: cancellation, claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update') }
    ]

    results, errors, backend_pids = concurrently(2) do |index|
      actions.fetch(index).call
    end

    assert_equal 2, backend_pids.uniq.length
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_includes %w[completed cancelled], proposal.status
    if proposal.status == 'completed'
      assert_equal '競合予定改', Event.find_by!(created_by_id: @user.id).title
      assert_equal 1, (results.count { |item| item['status'] == 'completed' })
    else
      assert_equal '競合予定', Event.find_by!(created_by_id: @user.id).title
      assert_equal 1, (results.count { |item| item['status'] == 'cancelled' })
    end
    assert_equal 1, errors.length
    assert_instance_of SecretaryMutation::Error, errors.first
    assert_equal 'proposal_changed', errors.first.code
  end

  test 'different proposals for one target serialize on the target advisory lock and write once' do
    event = Event.create!(created_by: @user, title: '同一対象', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    first = propose('同一対象のタイトルを候補Aに変更')
    second = propose('同一対象のタイトルを候補Bに変更')
    confirmations = [mutation_confirm(first), mutation_confirm(second)]
    proposals = [first, second]

    results, errors, backend_pids = concurrently(2) do |index|
      ready = proposals.fetch(index)
      service.call(phase: 'execute', request: confirmations.fetch(index), claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end

    assert_empty errors
    assert_equal 2, backend_pids.uniq.length
    assert_equal %w[completed conflicted], results.map { |item| item.fetch('status') }.sort
    assert_includes %w[候補A 候補B], event.reload.title
    ids = proposals.map { |item| item.fetch('proposal_id') }
    assert_equal 1, SecretaryMutationAudit.joins(:secretary_mutation_proposal)
      .where(secretary_mutation_proposals: { public_id: ids }, event_type: 'mutation_completed').count
    assert_equal 1, SecretaryMutationOutboxEntry.joins(:secretary_mutation_proposal)
      .where(secretary_mutation_proposals: { public_id: ids }).count
  end

  test 'confirm that reaches the closed expiry while waiting for locks performs zero domain writes' do
    event = Event.create!(created_by: @user, title: '待機期限予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('待機期限予定のタイトルを実行禁止に変更')
    holder, release_holder, holder_failures = session_lock_holder
    about_to_wait = Queue.new
    results = Queue.new
    failures = Queue.new
    blocked_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
      before_session_lock: ->(*) { about_to_wait << true })
    worker = mutation_thread(results, failures) do
      blocked_service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end
    about_to_wait.pop
    @now = Time.iso8601(ready.fetch('execution_expires_at'))
    release_holder << true
    holder.join
    worker.join

    assert_empty drain(results)
    error = drain(failures).fetch(0)
    assert_instance_of SecretaryMutation::Error, error
    assert_equal 'expired', error.code
    assert_empty drain(holder_failures)
    assert_equal '待機期限予定', event.reload.title
    assert_equal 'expired', SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id')).status
  ensure
    release_holder << true if defined?(release_holder) && defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'blocked successful confirm timestamps completion after locks and domain persistence' do
    event = Event.create!(created_by: @user, title: '待機成功予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('待機成功予定のタイトルを待機成功済みに変更')
    holder, release_holder, holder_failures = session_lock_holder
    about_to_wait = Queue.new
    admitted_at = @now + 2.minutes
    event_locked_at = admitted_at + 2.seconds
    relationships_locked_at = admitted_at + 3.seconds
    before_write_at = admitted_at + 5.seconds
    completed_at = admitted_at + 7.654321.seconds
    clock_calls = 0
    post_lock_clock = lambda do
      clock_calls += 1
      {
        1 => admitted_at, 2 => event_locked_at, 3 => relationships_locked_at,
        4 => before_write_at
      }.fetch(clock_calls, completed_at)
    end
    results = Queue.new
    failures = Queue.new
    blocked_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: post_lock_clock,
      before_session_lock: ->(*) { about_to_wait << true })
    worker = mutation_thread(results, failures) do
      blocked_service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end
    about_to_wait.pop
    release_holder << true
    holder.join
    worker.join

    assert_empty drain(failures)
    assert_empty drain(holder_failures)
    completed = drain(results).fetch(0)
    assert_equal completed_at.utc.iso8601(6), completed.dig('receipt', 'completed_at')
    assert_equal completed_at + 30.days, Time.iso8601(completed.fetch('receipt_detail_available_until'))
    assert_equal completed_at + 400.days, Time.iso8601(completed.fetch('status_available_until'))
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal completed_at.utc.iso8601(6), proposal.completed_at.utc.iso8601(6)
    assert_equal '待機成功済み', event.reload.title
    assert_equal 5, clock_calls
  ensure
    release_holder << true if defined?(release_holder) && defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'confirm rechecks the closed expiry after waiting on a legacy event row lock' do
    event = Event.create!(created_by: @user, title: '行待機期限予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('行待機期限予定のタイトルを行待機実行禁止に変更')
    row_locked = Queue.new
    release_row = Queue.new
    holder_failures = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Event.transaction do
          Event.lock.find(event.id)
          row_locked << true
          release_row.pop
        end
      rescue StandardError => error
        holder_failures << error
        row_locked << false
      end
    end
    assert row_locked.pop
    before_event_lock = Queue.new
    results = Queue.new
    failures = Queue.new
    blocked_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
      before_event_lock: ->(event_id) { before_event_lock << true if event_id == event.id })
    worker = mutation_thread(results, failures) do
      blocked_service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end
    before_event_lock.pop
    @now = Time.iso8601(ready.fetch('execution_expires_at'))
    release_row << true
    holder.join
    worker.join

    assert_empty drain(results)
    error = drain(failures).fetch(0)
    assert_instance_of SecretaryMutation::Error, error
    assert_equal 'expired', error.code
    assert_empty drain(holder_failures)
    assert_equal '行待機期限予定', event.reload.title
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 'expired', proposal.status
    assert_equal @now.utc.iso8601(6), proposal.expired_at.utc.iso8601(6)
  ensure
    release_row << true if defined?(release_row) && defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'confirm rechecks expiry immediately before the domain update' do
    event = Event.create!(created_by: @user, title: '直前期限予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('直前期限予定のタイトルを直前実行禁止に変更')
    admitted_at = @now + 1.minute
    expires_at = Time.iso8601(ready.fetch('execution_expires_at'))
    clock_calls = 0
    boundary_clock = lambda do
      clock_calls += 1
      clock_calls < 4 ? admitted_at : expires_at
    end
    guarded_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: boundary_clock)

    error = assert_raises(SecretaryMutation::Error) do
      guarded_service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end

    assert_equal 'expired', error.code
    assert_equal 4, clock_calls
    assert_equal '直前期限予定', event.reload.title
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 'expired', proposal.status
    assert_equal expires_at.utc.iso8601(6), proposal.expired_at.utc.iso8601(6)
  end

  test 'concurrent user revocation is locked and reauthorized before confirm writes' do
    event = Event.create!(created_by: @user, title: '失効競合予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('失効競合予定のタイトルを失効後禁止に変更')
    changed = Queue.new
    release_change = Queue.new
    holder_failures = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.lock.find(@user.id).update!(status: 'suspended')
          changed << true
          release_change.pop
        end
      rescue StandardError => error
        holder_failures << error
        changed << false
      end
    end
    assert changed.pop
    before_user_lock = Queue.new
    results = Queue.new
    failures = Queue.new
    guarded_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
      before_user_lock: ->(_phase, user_id) { before_user_lock << true if user_id == @user.id })
    worker = mutation_thread(results, failures) do
      guarded_service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end
    before_user_lock.pop
    release_change << true
    holder.join
    worker.join

    assert_empty drain(results)
    error = drain(failures).fetch(0)
    assert_instance_of SecretaryMutation::Error, error
    assert_equal 'forbidden', error.code
    assert_empty drain(holder_failures)
    assert_equal '失効競合予定', event.reload.title
    assert_equal 'ready', SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id')).status
  ensure
    release_change << true if defined?(release_change) && defined?(holder) && holder&.alive?
    holder&.join
    worker&.join
  end

  test 'concurrent real account deletion cannot leave an authorized confirm write' do
    event = Event.create!(created_by: @user, title: '削除競合予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('削除競合予定のタイトルを削除後禁止に変更')
    event_locked = Queue.new
    release_event = Queue.new
    event_holder_failures = Queue.new
    event_holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Event.transaction do
          Event.lock.find(event.id)
          event_locked << true
          release_event.pop
        end
      rescue StandardError => error
        event_holder_failures << error
        event_locked << false
      end
    end
    assert event_locked.pop

    deletion_user_locked = Queue.new
    deletion_results = Queue.new
    holder_failures = Queue.new
    deletion_start = Queue.new
    holder = nil
    sql_subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _started, _finished, _id, payload|
      next unless holder && Thread.current == holder
      next unless payload.fetch(:sql).match?(/SELECT .*"users".*FOR UPDATE/m)

      deletion_user_locked << true
    end
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        deletion_start.pop
        deletion_results << AccountDeletionService.call(@user)
      rescue StandardError => error
        holder_failures << error
      end
    end
    deletion_start << true
    Timeout.timeout(5) { deletion_user_locked.pop }

    confirm_user_lock_reached = Queue.new
    results = Queue.new
    failures = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        competing_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
          before_user_lock: lambda do |phase, _user_id|
            confirm_user_lock_reached << true if phase == 'execute'
          end)
        results << competing_service.call(phase: 'execute', request: mutation_confirm(ready), claims: @claims,
          proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
      rescue StandardError => error
        failures << error
      end
    end
    Timeout.timeout(5) { confirm_user_lock_reached.pop }
    release_event << true
    event_holder.join
    holder.join
    worker.join

    assert_empty drain(results)
    error = drain(failures).fetch(0)
    assert_instance_of SecretaryMutation::Error, error
    assert_equal 'forbidden', error.code
    assert_empty drain(event_holder_failures)
    assert_empty drain(holder_failures)
    assert_equal 1, drain(deletion_results).length
    refute Event.exists?(event.id)
    refute SecretaryMutationProposal.exists?(public_id: ready.fetch('proposal_id'))
  ensure
    ActiveSupport::Notifications.unsubscribe(sql_subscriber) if defined?(sql_subscriber) && sql_subscriber
    release_event << true if defined?(release_event) && defined?(event_holder) && event_holder&.alive?
    event_holder&.join
    holder&.join
    worker&.join
    event&.delete
  end

  test 'status promptly reports in progress while confirm holds the execution lock then recovers receipt' do
    event = Event.create!(created_by: @user, title: '応答確認予定', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    ready = propose('応答確認予定のタイトルを応答確認済みに変更')
    confirmation = mutation_confirm(ready)
    lock_reached = Queue.new
    release = Queue.new
    result = Queue.new
    failure = Queue.new
    confirming = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        paused_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
          after_advisory_lock: lambda do |phase, public_id, event_id|
            next unless phase == 'execute' && public_id == ready.fetch('proposal_id') && event_id == event.id

            lock_reached << true
            release.pop
          end)
        result << paused_service.call(phase: 'execute', request: confirmation, claims: @claims,
          proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
      rescue StandardError => error
        failure << error
      end
    end
    lock_reached.pop

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(SecretaryMutation::Error) do
      service.call(phase: 'status', request: status_request, claims: @claims,
        proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal 'in_progress', error.code
    assert_equal 202, error.status
    assert_operator elapsed, :<, 1.0

    release << true
    confirming.join
    assert_empty drain(failure)
    completed = drain(result).fetch(0)
    assert_equal 'completed', completed.fetch('status')
    recovered = service.call(phase: 'status', request: status_request, claims: @claims,
      proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    assert_equal completed.dig('receipt', 'result_id'), recovered.dig('receipt', 'result_id')
    assert_equal '応答確認済み', event.reload.title
  ensure
    release << true if defined?(release) && defined?(confirming) && confirming&.alive?
    confirming&.join
  end

  test 'status fails safe when the target changes after its unlocked preview' do
    2.times do |index|
      Event.create!(created_by: @user, title: "切替候補 #{index}", start_at: @now + index.days + 1.day,
        end_at: @now + index.days + 1.day + 1.hour, color: '#3b82f6')
    end
    first_request = mutation_propose(operation: 'event.delete', message: '切替候補を削除')
    candidates = service.call(phase: 'propose', request: first_request, claims: @claims,
      proposal_id: nil, operation: 'event.delete')
    selected = candidates.dig('candidates', 'items', 1, 'candidate_ref')
    preview_reached = Queue.new
    release_status = Queue.new
    status_errors = Queue.new
    stale_status = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
      after_preview: lambda do |phase, public_id, event_id|
        next unless phase == 'status' && public_id == candidates.fetch('proposal_id') && event_id.nil?

        preview_reached << true
        release_status.pop
      end)
    status_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        stale_status.call(phase: 'status', request: status_request, claims: @claims,
          proposal_id: candidates.fetch('proposal_id'), operation: 'event.delete')
      rescue StandardError => error
        status_errors << error
      end
    end
    preview_reached.pop

    followup = mutation_propose(operation: 'event.delete', message: 'この予定です',
      previous: candidates, candidate_ref: selected)
    revised = service.call(phase: 'propose', request: followup, claims: @claims,
      proposal_id: candidates.fetch('proposal_id'), operation: 'event.delete')
    assert_equal 'ready', revised.fetch('status')
    release_status << true
    status_thread.join

    error = drain(status_errors).fetch(0)
    assert_instance_of SecretaryMutation::Error, error
    assert_equal 'in_progress', error.code
    assert_equal 202, error.status
    assert_equal revised.dig('target', 'target_ref'),
      SecretaryMutationProposal.find_by!(public_id: revised.fetch('proposal_id')).target_ref
  ensure
    release_status << true if defined?(release_status) && defined?(status_thread) && status_thread&.alive?
    status_thread&.join
  end

  test 'one home session serializes confirms for different targets' do
    first_event = Event.create!(created_by: @user, title: '直列対象一', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    second_event = Event.create!(created_by: @user, title: '直列対象二', start_at: @now + 2.days,
      end_at: @now + 2.days + 1.hour, color: '#3b82f6')
    first = propose('直列対象一のタイトルを直列完了一に変更')
    second = propose('直列対象二のタイトルを直列完了二に変更')
    first_locked = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    second_lock_reached = Queue.new
    results = Queue.new
    failures = Queue.new
    hook = lambda do |phase, public_id, _event_id|
      next unless phase == 'execute'

      if public_id == first.fetch('proposal_id')
        first_locked << true
        release_first.pop
      elsif public_id == second.fetch('proposal_id')
        second_lock_reached << true
      end
    end
    paused_service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock,
      after_advisory_lock: hook)
    first_thread = mutation_thread(results, failures) do
      paused_service.call(phase: 'execute', request: mutation_confirm(first), claims: @claims,
        proposal_id: first.fetch('proposal_id'), operation: 'event.update')
    end
    first_locked.pop
    second_thread = mutation_thread(results, failures) do
      second_started << true
      paused_service.call(phase: 'execute', request: mutation_confirm(second), claims: @claims,
        proposal_id: second.fetch('proposal_id'), operation: 'event.update')
    end
    second_started.pop
    assert_raises(Timeout::Error) { Timeout.timeout(0.25) { second_lock_reached.pop } }

    release_first << true
    first_thread.join
    Timeout.timeout(2) { second_lock_reached.pop }
    second_thread.join
    assert_empty drain(failures)
    assert_equal %w[completed completed], drain(results).map { |item| item.fetch('status') }.sort
    assert_equal '直列完了一', first_event.reload.title
    assert_equal '直列完了二', second_event.reload.title
  ensure
    release_first << true if defined?(release_first) && defined?(first_thread) && first_thread&.alive?
    first_thread&.join
    second_thread&.join
  end

  test 'five stale proposals do not block a new proposal after the closed execution deadline' do
    5.times { |index| propose("不存在対象#{index}を変更") }
    assert_equal 5, open_proposals.count
    @now += 5.minutes

    response = propose('新しい不存在対象を変更')

    assert_equal 'needs_target', response.fetch('status')
    assert_equal 1, open_proposals.where('execution_expires_at > ?', @now).count
  end

  test 'session lock makes the five proposal cap atomic across two PostgreSQL connections' do
    4.times { |index| propose("同時上限対象#{index}を変更") }
    request = -> { mutation_propose(operation: 'event.update', message: "同時上限#{SecureRandom.hex(4)}を変更") }

    results, errors, backend_pids = concurrently(2) do
      service.call(phase: 'propose', request: request.call, claims: @claims,
        proposal_id: nil, operation: 'event.update')
    end

    assert_equal 2, backend_pids.uniq.length
    assert_equal 1, results.length
    assert_equal 'needs_target', results.first.fetch('status')
    assert_equal 1, errors.length
    assert_instance_of SecretaryMutation::Error, errors.first
    assert_equal 'conflict', errors.first.code
    assert_equal 5, open_proposals.where('execution_expires_at > ?', @now).count
  end

  test 'same idempotency key across concurrent distinct proposals executes only one target' do
    first_event = Event.create!(created_by: @user, title: '鍵対象一', start_at: @now + 1.day,
      end_at: @now + 1.day + 1.hour, color: '#3b82f6')
    second_event = Event.create!(created_by: @user, title: '鍵対象二', start_at: @now + 2.days,
      end_at: @now + 2.days + 1.hour, color: '#3b82f6')
    other_claims = @claims.merge('sub' => SecureRandom.uuid)
    proposals = [
      propose_for('鍵対象一のタイトルを鍵完了一に変更', claims: @claims),
      propose_for('鍵対象二のタイトルを鍵完了二に変更', claims: other_claims)
    ]
    claims = [@claims, other_claims]
    idempotency_key = SecureRandom.uuid

    results, errors, backend_pids = concurrently(2) do |index|
      ready = proposals.fetch(index)
      service.call(phase: 'execute', request: mutation_confirm(ready, idempotency_key: idempotency_key),
        claims: claims.fetch(index), proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    end

    assert_equal 2, backend_pids.uniq.length
    assert_equal 1, results.length
    assert_equal 'completed', results.first.fetch('status')
    assert_equal 1, errors.length
    assert_instance_of SecretaryMutation::Error, errors.first
    assert_equal 'idempotency_conflict', errors.first.code
    assert_equal 1, [first_event.reload.title == '鍵完了一', second_event.reload.title == '鍵完了二'].count(true)
    assert_equal 1, SecretaryMutationProposal.where(user: @user, status: 'completed').count
  end

  private

  def service
    SecretaryMutation::Proposals.new(configuration: @configuration, clock: @clock)
  end

  def propose(message)
    propose_for(message, claims: @claims)
  end

  def propose_for(message, claims:)
    request = mutation_propose(operation: 'event.update', message: message)
    service.call(phase: 'propose', request: request, claims: claims,
      proposal_id: nil, operation: 'event.update')
  end

  def status_request
    { 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid }
  end

  def open_proposals
    SecretaryMutationProposal.where(user: @user, home_subject: @home_subject)
      .where.not(status: SecretaryMutationProposal::TERMINAL_STATUSES)
  end

  def mutation_thread(results, failures, &block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        results << block.call
      rescue StandardError => error
        failures << error
      end
    end
  end

  def session_lock_holder
    locked = Queue.new
    release = Queue.new
    failures = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          SecretaryMutation::AdvisoryLock.acquire_session!(user_id: @user.id, home_subject: @home_subject)
          locked << true
          release.pop
        end
      rescue StandardError => error
        failures << error
        locked << false
      end
    end
    raise failures.pop unless locked.pop

    [thread, release, failures]
  end

  def concurrently(count)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    backend_pids = Queue.new
    threads = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          backend_pids << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()')
          ready << true
          release.pop
          results << yield(index)
        rescue StandardError => error
          errors << error
        end
      end
    end
    count.times { ready.pop }
    count.times { release << true }
    threads.each(&:join)
    [drain(results), drain(errors), drain(backend_pids)]
  end

  def drain(queue)
    values = []
    values << queue.pop until queue.empty?
    values
  end
end
