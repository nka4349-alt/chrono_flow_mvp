# frozen_string_literal: true

require 'test_helper'
require_relative '../services/secretary_mutation/test_support'

class SecretaryMutationProposalsTest < ActionDispatch::IntegrationTest
  include SecretaryMutationTestSupport

  setup do
    @now = Time.zone.parse('2026-09-21 09:00:00.123456')
    @clock = -> { @now }
    @user = User.create!(name: 'Mutation owner', email: "mutation-#{SecureRandom.hex(5)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "mutation|#{SecureRandom.uuid}")
    @home_subject = SecureRandom.uuid
    @mutation_dependencies = mutation_dependencies(now: @clock)
  end

  test 'event update requires an exact confirmation and returns an authoritative receipt' do
    event = create_event(title: '定例会議')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '定例会議のタイトルを週次会議に変更'))
    assert_response :created
    ready = mutation_body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal ['title'], ready['changed_fields']
    assert_equal '定例会議', ready.dig('before', 'title')
    assert_equal '週次会議', ready.dig('after', 'title')
    assert_match(/\Ast1_[A-Za-z0-9_-]{43}\z/, ready.dig('target', 'target_ref'))
    assert_match(/\Asv1_test-k1_[A-Za-z0-9_-]{43}\z/, ready.dig('target', 'target_version'))

    confirmation = mutation_confirm(ready)
    assert_no_difference('Event.count') { request_mutation('execute', confirmation) }
    assert_response :success
    completed = mutation_body
    assert_equal 'completed', completed['status']
    assert_equal 'event_updated', completed.dig('receipt', 'domain_outcome')
    assert_equal '週次会議', event.reload.title
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 1, proposal.secretary_mutation_audits.where(event_type: 'mutation_completed').count
    assert_equal 1, proposal.secretary_mutation_outbox_entries.where(event_type: 'secretary_mutation.completed').count
    assert_equal @now + 30.days, Time.iso8601(completed['receipt_detail_available_until'])
    assert_equal @now + 400.days, Time.iso8601(completed['status_available_until'])
    assert_equal @now + 600.seconds, Time.iso8601(completed.dig('refresh_scope', 'expires_at'))

    result_id = completed.dig('receipt', 'result_id')
    request_mutation('execute', confirmation.merge('request_id' => SecureRandom.uuid))
    assert_response :success
    assert_equal result_id, mutation_body.dig('receipt', 'result_id')
    assert_equal '週次会議', event.reload.title
  end

  test 'event delete removes approved dependents nullifies references and keeps proposal receipt' do
    event = create_event(title: '削除予定')
    EventParticipant.create!(event: event, user: @user, source: :linked)
    EventReminder.create!(event: event, user: @user, remind_at: event.start_at - 30.minutes,
      minutes_before: 30, status: :pending)
    room = ChatRoom.create!(chatable: event)
    Message.create!(chat_room: room, user: @user, body: 'message')
    conversation = AiConversation.create!(user: @user, scope_type: 'home')
    recommendation = AiRecommendation.create!(ai_conversation: conversation, user: @user,
      kind: 'event_delete', title: 'proposal', source_event: event, created_event: event)
    access_log = AiContextAccessLog.create!(user: @user, event: event, source_type: 'event',
      permission_used: 'owner', ai_context_mode: 'personal_simple', request_id: SecureRandom.uuid)

    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '削除予定を削除'))
    ready = mutation_body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal ['$record'], ready['changed_fields']
    assert_nil ready['after']
    assert_equal 1, ready.dig('planned_related_effects', 'chat_messages_to_delete')
    assert_equal 2, ready.dig('planned_related_effects', 'ai_recommendation_refs_to_nullify')

    assert_difference('Event.count', -1) { request_mutation('execute', mutation_confirm(ready)) }
    assert_response :success
    completed = mutation_body
    assert_equal 'event_deleted', completed.dig('receipt', 'domain_outcome')
    assert_equal 1, completed.dig('receipt', 'related_effects', 'self_participants_deleted')
    assert_nil SecretaryMutationProposal.find_by!(public_id: ready['proposal_id']).target_event_id
    assert_nil recommendation.reload.source_event_id
    assert_nil recommendation.created_event_id
    assert_nil access_log.reload.event_id
    refute EventReminder.exists?(event_id: event.id)
    refute ChatRoom.exists?(room.id)

    request_mutation('status', nil, proposal_id: ready['proposal_id'],
      claims: { 'mutation_operation' => 'event.delete' })
    assert_response :success
    assert_equal completed.dig('receipt', 'result_id'), mutation_body.dig('receipt', 'result_id')
  end

  test 'truncated targets reject direct selection and allow only a fresh uniquely narrowed search' do
    6.times { |index| create_event(title: "候補会議 #{index}", start_at: @now + index.days + 1.day) }
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '候補会議を削除'))
    first = mutation_body
    assert_equal 'needs_target', first['status']
    assert_equal 5, first.dig('candidates', 'items').length
    assert_equal true, first.dig('candidates', 'truncated')
    assert_equal '候補が多いため、予定名や日時で絞り込んでください。', first['question']

    chosen = first.dig('candidates', 'items', 2, 'candidate_ref')
    assert_no_changes(-> { Event.order(:id).pluck(:id, :title, :updated_at) }) do
      request_mutation('propose', mutation_propose(operation: 'event.delete',
        message: 'この予定です', previous: first, candidate_ref: chosen))
    end
    assert_response :success
    still_truncated = mutation_body
    assert_equal 'needs_target', still_truncated['status'], still_truncated.inspect
    assert_nil still_truncated['target']
    assert_equal true, still_truncated.dig('candidates', 'truncated')
    assert_equal '候補が多いため、予定名や日時で絞り込んでください。', still_truncated['question']

    request_mutation('propose', mutation_propose(operation: 'event.delete',
      message: '候補会議 2を削除', previous: still_truncated))
    narrowed = mutation_body
    assert_response :success
    assert_equal 'ready', narrowed['status'], narrowed.inspect
    assert_equal '候補会議 2', narrowed.dig('target', 'display', 'title')
    assert_equal 3, narrowed['revision']
  end

  test 'zero target stays needs target and clarification follow-up revises the same target' do
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '存在しない予定を削除'))
    missing = mutation_body
    assert_equal 'needs_target', missing['status']
    assert_empty missing.dig('candidates', 'items')
    assert_equal false, missing.dig('candidates', 'truncated')
    assert_equal '対象の予定を特定できませんでした。予定名や日時を追加してください。', missing['question']

    create_event(title: '要確認予定')
    request_mutation('propose', mutation_propose(operation: 'event.update', message: '要確認予定を変更'))
    unclear = mutation_body
    assert_equal 'needs_clarification', unclear['status'], unclear.inspect
    assert_nil unclear['reason_code']
    assert_equal [], unclear['changed_fields']
    assert_nil unclear['after']
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: 'タイトルを確認済み予定に変更', previous: unclear))
    revised = mutation_body
    assert_equal 'ready', revised['status'], revised.inspect
    assert_equal 2, revised['revision']
    assert_equal '確認済み予定', revised.dig('after', 'title')
  end

  test 'multiple non-truncated targets use the exact selection question' do
    2.times { |index| create_event(title: "選択予定 #{index}", start_at: @now + index.days + 1.day) }

    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '選択予定を削除'))
    response = mutation_body

    assert_equal 'needs_target', response['status'], response.inspect
    assert_equal false, response.dig('candidates', 'truncated')
    assert_equal 2, response.dig('candidates', 'items').length
    assert_equal '対象の予定を選んでください。', response['question']
  end

  test 'clarification follow-up cannot silently rebind after its selected target disappears' do
    selected_event = create_event(title: '同名予定', start_at: @now + 1.day)
    surviving_event = create_event(title: '同名予定', start_at: @now + 2.days)
    request_mutation('propose', mutation_propose(operation: 'event.update', message: '同名予定を変更'))
    candidates = mutation_body
    assert_equal 'needs_target', candidates['status'], candidates.inspect

    selected_ref = candidates.dig('candidates', 'items', 0, 'candidate_ref')
    request_mutation('propose', mutation_propose(operation: 'event.update', message: 'この予定です',
      previous: candidates, candidate_ref: selected_ref))
    clarification = mutation_body
    assert_equal 'needs_clarification', clarification['status'], clarification.inspect

    selected_event.destroy!
    assert_no_changes(-> { surviving_event.reload.title }) do
      request_mutation('propose', mutation_propose(operation: 'event.update',
        message: 'タイトルを再選択禁止に変更', previous: clarification))
    end
    assert_mutation_error 'target_changed', 409
    assert_equal surviving_event.id, Event.find_by!(title: '同名予定').id
  end

  test 'recognized update equal to current value is rejected as no effect' do
    create_event(title: '同一内容予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '同一内容予定のタイトルを同一内容予定に変更'))

    assert_response :created
    rejected = mutation_body
    assert_equal 'rejected', rejected['status'], rejected.inspect
    assert_equal 'no_effect', rejected['reason_code']
    assert_equal [], rejected['changed_fields']
    assert_nil rejected['after']
    assert_equal({ 'type' => 'none' }, rejected['planned_related_effects'])
  end

  test 'field-specific controls are rejected without globally rejecting multiline descriptions' do
    event = create_event(title: '文字安全予定')
    invalid_messages = [
      "文字安全予定のタイトルを危険\nタイトルに変更",
      "文字安全予定の場所を危険\t場所に変更",
      "文字安全予定のタイトルを危険\0タイトルに変更"
    ]

    invalid_messages.each do |message|
      assert_no_difference('SecretaryMutationProposal.count') do
        assert_no_changes(-> { event.reload.attributes.slice('title', 'description', 'location', 'updated_at') }) do
          request_mutation('propose', mutation_propose(operation: 'event.update', message: message))
        end
      end
      assert_mutation_error 'invalid_request', 400
    end

    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: "文字安全予定の説明を1行目\n2行目に変更"))
    ready = mutation_body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal "1行目\n2行目", ready.dig('after', 'description')

    request_mutation('execute', mutation_confirm(ready))
    assert_response :success
    assert_equal "1行目\n2行目", event.reload.description
  end

  test 'writer revalidates confirmed text immediately before a domain save' do
    event = create_event(title: '書込直前予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '書込直前予定のタイトルを書込直前確認済みに変更'))
    ready = mutation_body
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    proposal.after_snapshot = proposal.after_snapshot.merge('title' => "不正\tタイトル")
    versioner = SecretaryMutation::Versioner.new(
      configuration: @mutation_dependencies.fetch(:configuration).validate!
    )

    assert_raises(SecretaryMutation::Contract::Invalid) do
      Event.transaction do
        SecretaryMutation::EventWriter.new(
          proposal: proposal, event: event, user: @user, versioner: versioner,
          time_zone: proposal.time_zone, expiry_guard: -> { nil }, before_event_lock: nil
        ).call
      end
    end
    assert_equal '書込直前予定', event.reload.title
  end

  test 'DST gap and overlap wall clocks require clarification instead of automatic movement' do
    zone = ActiveSupport::TimeZone['America/New_York']
    cases = [
      ['DST春明示', @now + 1.day, @now + 1.day + 1.hour,
        '「DST春明示」を変更。2026年3月8日 2:30から3:30'],
      ['DST秋明示', @now + 2.days, @now + 2.days + 1.hour,
        '「DST秋明示」を変更。2026年11月1日 1:30から2:30'],
      ['DST春移動', zone.local(2026, 3, 7, 2, 30), zone.local(2026, 3, 7, 3, 30),
        '「DST春移動」の日付を2026年3月8日に変更'],
      ['DST秋移動', zone.local(2026, 10, 31, 1, 30), zone.local(2026, 10, 31, 2, 30),
        '「DST秋移動」の日付を2026年11月1日に変更']
    ]

    cases.each do |title, start_at, end_at, message|
      event = create_event(title: title, start_at: start_at, end_at: end_at)
      request = mutation_propose(operation: 'event.update', message: message)
        .merge('time_zone' => 'America/New_York')
      assert_no_changes(-> { event.reload.attributes.slice('start_at', 'end_at') }) do
        request_mutation('propose', request)
      end
      assert_response :created
      assert_equal 'needs_clarification', mutation_body['status'], mutation_body.inspect
      assert_nil mutation_body['after']
    end
  end

  test 'date-only movement preserves an unambiguous wall clock' do
    zone = ActiveSupport::TimeZone['America/New_York']
    event = create_event(title: '通常日移動', start_at: zone.local(2026, 3, 7, 10, 30),
      end_at: zone.local(2026, 3, 7, 11, 45))
    request = mutation_propose(operation: 'event.update',
      message: '「通常日移動」の日付を2026年3月9日に変更')
      .merge('time_zone' => 'America/New_York')
    request_mutation('propose', request)

    assert_response :created
    ready = mutation_body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal ['schedule'], ready['changed_fields']
    assert_equal '2026-03-09T10:30:00-04:00', ready.dig('after', 'schedule', 'start_at')
    assert_equal '2026-03-09T11:45:00-04:00', ready.dig('after', 'schedule', 'end_at')
    assert_equal event.id, SecretaryMutationProposal.find_by!(public_id: ready['proposal_id']).target_event_id
  end

  test 'explicit-offset ISO schedule remains valid across a DST transition' do
    event = create_event(title: 'ISO時刻予定')
    request = mutation_propose(operation: 'event.update',
      message: '「ISO時刻予定」を変更。2026-03-08T01:30:00-05:00から2026-03-08T03:30:00-04:00')
      .merge('time_zone' => 'America/New_York')
    request_mutation('propose', request)

    ready = mutation_body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal '2026-03-08T01:30:00-05:00', ready.dig('after', 'schedule', 'start_at')
    assert_equal '2026-03-08T03:30:00-04:00', ready.dig('after', 'schedule', 'end_at')
    request_mutation('execute', mutation_confirm(ready))
    assert_response :success
    assert_equal 'completed', mutation_body['status']
    assert_equal ready.dig('after', 'schedule'), SecretaryMutation::EventProjection.snapshot(event.reload,
      time_zone: 'America/New_York').fetch('schedule')
  end

  test 'all-day movement rejects skipped dates and nonexistent local midnights' do
    cases = [
      ['Pacific/Apia', Date.new(2026, 9, 22), Date.new(2011, 12, 30), 'Apia日付境界'],
      ['America/Sao_Paulo', Date.new(2026, 9, 22), Date.new(2018, 11, 4), 'SaoPaulo日付境界']
    ]
    cases.each do |zone_name, original_date, requested_date, title|
      zone = ActiveSupport::TimeZone[zone_name]
      assert_empty zone.tzinfo.periods_for_local(DateTime.new(
        requested_date.year, requested_date.month, requested_date.day, 0, 0, 0
      ))
      event = Event.create!(created_by: @user, title: title, location: '会議室', all_day: true,
        start_at: zone.local(original_date.year, original_date.month, original_date.day),
        end_at: zone.local(original_date.year, original_date.month, original_date.day) + 1.day,
        color: '#3b82f6')
      event.update_column(:all_day, true)
      request = mutation_propose(operation: 'event.update',
        message: "「#{title}」の日付を#{requested_date.year}年#{requested_date.month}月#{requested_date.day}日に変更")
        .merge('time_zone' => zone_name)

      assert_no_changes(-> { event.reload.attributes.slice('start_at', 'end_at', 'all_day') }) do
        request_mutation('propose', request)
      end
      assert_equal 'needs_clarification', mutation_body['status'], mutation_body.inspect
      assert_nil mutation_body['after']
    end
  end

  test 'all-day movement keeps date precision across a unique DST midnight' do
    zone = ActiveSupport::TimeZone['America/New_York']
    event = Event.create!(created_by: @user, title: '終日DST移動', location: '会議室', all_day: true,
      start_at: zone.local(2026, 3, 7), end_at: zone.local(2026, 3, 8), color: '#3b82f6')
    event.update_column(:all_day, true)
    request = mutation_propose(operation: 'event.update',
      message: '「終日DST移動」の日付を2026年3月8日に変更')
      .merge('time_zone' => 'America/New_York')
    request_mutation('propose', request)

    ready = mutation_body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal 'date', ready.dig('after', 'schedule', 'precision')
    assert_equal '2026-03-08', ready.dig('after', 'schedule', 'start_on')
    assert_equal '2026-03-09', ready.dig('after', 'schedule', 'end_on')
    assert_equal event.id, SecretaryMutationProposal.find_by!(public_id: ready['proposal_id']).target_event_id

    request_mutation('execute', mutation_confirm(ready))
    assert_response :success
    assert_equal 'completed', mutation_body['status']
    event.reload
    assert event.all_day?
    persisted_schedule = SecretaryMutation::EventProjection.snapshot(event,
      time_zone: 'America/New_York').fetch('schedule')
    assert_equal ready.dig('after', 'schedule'), persisted_schedule
  end

  test 'pending reminder blocks schedule update but not title update and notifications block delete' do
    event = create_event(title: '通知予定')
    EventReminder.create!(event: event, user: @user, remind_at: event.start_at - 30.minutes, minutes_before: 30)
    schedule_message = '通知予定の日付を9月24日に変更'
    request_mutation('propose', mutation_propose(operation: 'event.update', message: schedule_message))
    assert_equal 'rejected', mutation_body['status']
    assert_equal 'reminder_consistency_requires_gate', mutation_body['reason_code']

    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '通知予定のタイトルを通知予定改に変更'))
    assert_equal 'ready', mutation_body['status'], mutation_body.inspect

    Notification.create!(user: @user, kind: :event_reminder, payload: { event_id: event.id })
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '通知予定を削除'))
    assert_equal 'rejected', mutation_body['status']
    assert_equal 'ineligible_notification_history', mutation_body['reason_code']
  end

  test 'relationship phantom after ready conflicts with zero domain writes' do
    event = create_event(title: '関係予定')
    room = ChatRoom.create!(chatable: event)
    old_message = Message.create!(chat_room: room, user: @user, body: 'old')
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '関係予定を削除'))
    ready = mutation_body
    old_message.destroy!
    Message.create!(chat_room: room, user: @user, body: 'new')

    assert_no_difference('Event.count') { request_mutation('execute', mutation_confirm(ready)) }
    assert_response :success
    assert_equal 'conflicted', mutation_body['status']
    assert_equal 'relationships_changed', mutation_body['reason_code']
    assert Event.exists?(event.id)
  end

  test 'eligibility revoked after ready stops under the relationship lock with zero writes' do
    event = create_event(title: '権限予定')
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '権限予定を削除'))
    ready = mutation_body
    other = User.create!(name: 'Other participant', email: "participant-#{SecureRandom.hex(4)}@example.test",
      password: 'Password-123!')
    EventParticipant.create!(event: event, user: other)
    assert_no_difference('Event.count') { request_mutation('execute', mutation_confirm(ready)) }
    assert_response :success
    assert_equal 'conflicted', mutation_body['status']
    assert_equal 'relationships_changed', mutation_body['reason_code']
    assert Event.exists?(event.id)
  end

  test 'legacy over-contract text is excluded from search and conflicts safely after ready' do
    legacy = create_event(title: '表現不能予定')
    legacy.update_column(:description, '説' * 4_001)
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '表現不能予定を削除'))
    missing = mutation_body
    assert_response :created
    assert_equal 'needs_target', missing['status'], missing.inspect
    assert_empty missing.dig('candidates', 'items')

    event = create_event(title: '確認後表現不能予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '確認後表現不能予定のタイトルを安全な変更に変更'))
    ready = mutation_body
    event.update_column(:location, '場' * 201)
    assert_no_changes(-> { event.reload.title }) do
      request_mutation('execute', mutation_confirm(ready))
    end
    assert_response :success
    assert_equal 'conflicted', mutation_body['status']
    assert_equal 'target_changed', mutation_body['reason_code']

    malformed_title = create_event(title: '制御文字予定')
    malformed_title.update_column(:title, "制御\t文字予定")
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '制御文字予定を削除'))
    safe_response = mutation_body
    assert_response :created
    assert_equal 'needs_target', safe_response['status'], safe_response.inspect
    assert_empty safe_response.dig('candidates', 'items')
    assert_equal '対象の予定を特定できませんでした。予定名や日時を追加してください。', safe_response['question']

    control_after_ready = create_event(title: '確認後制御予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '確認後制御予定のタイトルを安全な予定に変更'))
    control_ready = mutation_body
    control_after_ready.update_column(:location, "危険\t場所")
    assert_no_changes(-> { control_after_ready.reload.title }) do
      request_mutation('execute', mutation_confirm(control_ready))
    end
    assert_response :success
    assert_equal 'conflicted', mutation_body['status']
    assert_equal 'target_changed', mutation_body['reason_code']
  end

  test 'zero-duration legacy events are excluded and fail closed after ready' do
    legacy = create_event(title: '空区間予定')
    legacy.update_column(:end_at, legacy.start_at)
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '空区間予定を削除'))
    missing = mutation_body
    assert_response :created
    assert_equal 'needs_target', missing['status'], missing.inspect
    assert_empty missing.dig('candidates', 'items')

    event = create_event(title: '確認後空区間予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '確認後空区間予定のタイトルを安全変更に変更'))
    ready = mutation_body
    event.update_column(:end_at, event.start_at)
    assert_no_changes(-> { event.reload.title }) do
      request_mutation('execute', mutation_confirm(ready))
    end
    assert_response :success
    assert_equal 'conflicted', mutation_body['status']
    assert_equal 'target_changed', mutation_body['reason_code']
  end

  test 'ready proposal survives HMAC rotation while a retired kid fails closed' do
    old_key = 'old-flow-hmac-key-that-is-at-least-32-bytes'
    new_key = 'new-flow-hmac-key-that-is-at-least-32-bytes'
    old_configuration = mutation_configuration(keys: { 'old-k1' => old_key }, active_kid: 'old-k1').validate!
    rotated_configuration = mutation_configuration(
      keys: { 'old-k1' => old_key, 'new-k2' => new_key }, active_kid: 'new-k2'
    ).validate!
    retired_configuration = mutation_configuration(keys: { 'new-k2' => new_key }, active_kid: 'new-k2').validate!

    @mutation_dependencies[:configuration] = old_configuration
    event = create_event(title: '鍵移行予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '鍵移行予定のタイトルを鍵移行完了に変更'))
    ready = mutation_body
    assert_match(/\Asv1_old-k1_/, ready.dig('target', 'target_version'))
    @mutation_dependencies[:configuration] = rotated_configuration
    request_mutation('execute', mutation_confirm(ready))
    assert_response :success
    assert_equal 'completed', mutation_body['status'], mutation_body.inspect
    assert_match(/\Asv1_new-k2_/, mutation_body.dig('receipt', 'target_version_after'))
    assert_equal '鍵移行完了', event.reload.title

    @mutation_dependencies[:configuration] = old_configuration
    retired_event = create_event(title: '失効鍵予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '失効鍵予定のタイトルを変更禁止に変更'))
    retired_ready = mutation_body
    @mutation_dependencies[:configuration] = retired_configuration
    assert_no_changes(-> { retired_event.reload.title }) do
      request_mutation('execute', mutation_confirm(retired_ready))
    end
    assert_mutation_error 'unavailable', 503
  end

  test 'cancel expiry idempotency conflict and completed receipt recovery are closed' do
    create_event(title: '取消予定')
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '取消予定を削除'))
    ready = mutation_body
    request_mutation('cancel', mutation_cancel(ready))
    assert_equal 'cancelled', mutation_body['status']
    assert_no_difference('Event.count') { request_mutation('execute', mutation_confirm(ready)) }
    assert_mutation_error 'proposal_changed', 409

    event = create_event(title: '完了予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '完了予定のタイトルを完了予定改に変更'))
    ready = mutation_body
    confirmation = mutation_confirm(ready)
    request_mutation('execute', confirmation)
    assert_equal 'completed', mutation_body['status']
    @now += 6.minutes
    request_mutation('execute', confirmation.merge('request_id' => SecureRandom.uuid))
    assert_equal 'completed', mutation_body['status']
    request_mutation('execute', confirmation.merge('request_id' => SecureRandom.uuid,
      'idempotency_key' => SecureRandom.uuid))
    assert_mutation_error 'idempotency_conflict', 409
    assert_equal '完了予定改', event.reload.title
  end

  test 'lost confirm response is recovered only by authoritative status after execution expiry' do
    event = create_event(title: '応答喪失予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '応答喪失予定のタイトルを保存済み予定に変更'))
    ready = mutation_body
    confirmation = mutation_confirm(ready)
    request_mutation('execute', confirmation)
    committed_result_id = mutation_body.dig('receipt', 'result_id')
    assert_equal '保存済み予定', event.reload.title

    @now += 6.minutes
    request_mutation('status', nil, proposal_id: ready['proposal_id'],
      claims: { 'mutation_operation' => 'event.update' })
    assert_response :success
    assert_equal 'completed', mutation_body['status']
    assert_equal committed_result_id, mutation_body.dig('receipt', 'result_id')
    assert_equal '保存済み予定', event.reload.title
  end

  test 'confirm revise and cancel stop at the exact execution expiry instant' do
    readies = %w[確認 増補 取消].to_h do |label|
      create_event(title: "境界#{label}予定")
      request_mutation('propose', mutation_propose(operation: 'event.update',
        message: "境界#{label}予定のタイトルを境界#{label}変更に変更"))
      [label, mutation_body]
    end
    @now = Time.iso8601(readies.fetch('確認').fetch('execution_expires_at'))

    assert_no_difference('Event.where("title LIKE ?", "境界%変更").count') do
      request_mutation('execute', mutation_confirm(readies.fetch('確認')))
    end
    assert_mutation_error 'expired', 410

    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: 'タイトルを再変更に変更', previous: readies.fetch('増補')))
    assert_mutation_error 'expired', 410

    request_mutation('cancel', mutation_cancel(readies.fetch('取消')))
    assert_mutation_error 'expired', 410
    statuses = readies.values.map do |ready|
      SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id')).status
    end
    assert_equal %w[expired expired expired], statuses
  end

  test 'status is not found at the exact availability deadline' do
    create_event(title: '状態保持境界予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '状態保持境界予定のタイトルを状態保持境界変更に変更'))
    ready = mutation_body
    @now = Time.iso8601(ready.fetch('status_available_until'))

    request_mutation('status', nil, proposal_id: ready.fetch('proposal_id'),
      claims: { 'mutation_operation' => 'event.update' })
    assert_mutation_error 'not_found', 404
  end

  test 'full receipt ages into a closed tombstone with exact fractional retention arithmetic' do
    create_event(title: '保持予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '保持予定のタイトルを保持済み予定に変更'))
    ready = mutation_body
    request_mutation('execute', mutation_confirm(ready))
    completed = mutation_body
    completed_at = completed.dig('receipt', 'completed_at')
    assert_equal '123456', completed_at[/\.(\d{6})Z\z/, 1]
    @now = Time.iso8601(completed.fetch('receipt_detail_available_until'))

    request_mutation('status', nil, proposal_id: ready['proposal_id'],
      claims: { 'mutation_operation' => 'event.update' })
    assert_response :success
    tombstone = mutation_body
    assert_equal 'completed_tombstone', tombstone['status']
    assert_nil tombstone['execution_expires_at']
    assert_nil tombstone['target']
    assert_equal 'tombstone', tombstone.dig('receipt', 'kind')
    assert_equal 30.days, Time.iso8601(tombstone['receipt_detail_available_until']) - Time.iso8601(completed_at)
    assert_equal 400.days, Time.iso8601(tombstone['status_available_until']) - Time.iso8601(completed_at)
    assert_equal '123456', tombstone['status_available_until'][/\.(\d{6})Z\z/, 1]
    SecretaryMutation::Contract.validate_success_response!(tombstone)
    persisted = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 'completed_tombstone', persisted.status
    assert_empty persisted.messages
    assert_empty persisted.candidate_mappings
    assert_nil persisted.target_ref
    assert_nil persisted.target_event_id
    assert_nil persisted.before_snapshot
    assert_nil persisted.after_snapshot
    assert_nil persisted.content_digest
    assert_nil persisted.refresh_scope
    assert_equal 'tombstone', persisted.receipt.fetch('kind')
  end

  test 'same-key recovery at the receipt deadline persists the minimal tombstone' do
    create_event(title: '同一鍵保持予定')
    request_mutation('propose', mutation_propose(operation: 'event.update',
      message: '同一鍵保持予定のタイトルを同一鍵保持済みに変更'))
    ready = mutation_body
    confirmation = mutation_confirm(ready)
    request_mutation('execute', confirmation)
    result_id = mutation_body.dig('receipt', 'result_id')
    @now = Time.iso8601(mutation_body.fetch('receipt_detail_available_until'))

    request_mutation('execute', confirmation.merge('request_id' => SecureRandom.uuid))

    assert_response :success
    assert_equal 'completed_tombstone', mutation_body.fetch('status')
    assert_equal result_id, mutation_body.dig('receipt', 'result_id')
    persisted = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    assert_equal 'completed_tombstone', persisted.status
    assert_empty persisted.messages
    assert_nil persisted.target_ref
    assert_nil persisted.before_snapshot
    assert_nil persisted.after_snapshot
    assert_nil persisted.refresh_scope
    assert_equal 'tombstone', persisted.receipt.fetch('kind')
  end

  test 'strict boundary rejects malformed media auth tamper and replay without writes' do
    event = create_event(title: '境界予定')
    payload = mutation_propose(operation: 'event.delete', message: '境界予定を削除')
    request_mutation('propose', payload, headers_override: { 'Accept' => 'text/html' })
    assert_mutation_error 'unsupported', 406
    request_mutation('propose', payload, headers_override: { 'Content-Type' => 'application/json; charset=utf-8' })
    assert_mutation_error 'unsupported', 415
    request_mutation('propose', payload, raw_body: '{"operation":"event.delete","operation":"event.update"}')
    assert_mutation_error 'invalid_request', 400
    request_mutation('propose', payload, claims: { 'body_sha256' => '0' * 64 })
    assert_mutation_error 'unauthenticated', 401

    raw = JSON.generate(payload)
    path = MUTATION_ROUTE
    token = mutation_token(operation: 'event.delete', phase: 'propose', path: path,
      raw: raw, request_id: payload['request_id'], trace_id: payload['trace_id'], overrides: {})
    request_mutation('propose', payload, token: token)
    assert_response :created
    assert_no_difference(['Event.count', 'SecretaryMutationProposal.count']) do
      request_mutation('propose', payload, token: token)
    end
    assert_mutation_error 'unauthenticated', 401
    assert Event.exists?(event.id)
  end

  test 'candidate refs and confirm path body jwt revision target and digest stay mutually bound' do
    2.times { |index| create_event(title: "束縛予定 #{index}", start_at: @now + index.days + 1.day) }
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '束縛予定を削除'))
    candidates = mutation_body
    assert_equal 'needs_target', candidates['status']
    selected = candidates.dig('candidates', 'items', 0, 'candidate_ref')

    tampered = mutation_propose(operation: 'event.delete', message: 'これです', previous: candidates,
      candidate_ref: "sc1_#{'A' * 43}")
    assert_no_difference('Event.count') { request_mutation('propose', tampered) }
    assert_mutation_error 'target_changed', 409

    valid = mutation_propose(operation: 'event.delete', message: 'これです', previous: candidates,
      candidate_ref: selected)
    request_mutation('propose', valid)
    ready = mutation_body
    assert_equal 'ready', ready['status']
    confirmation = mutation_confirm(ready)

    assert_no_difference('Event.count') do
      request_mutation('execute', confirmation.merge('target_ref' => "st1_#{'B' * 43}"))
    end
    assert_mutation_error 'proposal_changed', 409
    assert_no_difference('Event.count') do
      request_mutation('execute', confirmation.merge('revision' => ready['revision'] + 1))
    end
    assert_mutation_error 'proposal_changed', 409
    assert_no_difference('Event.count') do
      request_mutation('execute', confirmation,
        claims: { 'mutation_operation' => 'event.update',
          'scope' => 'secretary:chrono_flow:event.update:execute' })
    end
    assert_mutation_error 'unauthenticated', 401

    wrong_path_id = SecureRandom.uuid
    assert_no_difference('Event.count') do
      request_mutation('execute', confirmation, proposal_id: wrong_path_id)
    end
    assert_mutation_error 'invalid_request', 400
  end

  test 'expired candidate mapping cannot be selected or rebound to a fresh execution window' do
    2.times { |index| create_event(title: "期限候補 #{index}", start_at: @now + index.days + 1.day) }
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '期限候補を削除'))
    first = mutation_body
    candidate_ref = first.dig('candidates', 'items', 0, 'candidate_ref')
    @now += 6.minutes
    followup = mutation_propose(operation: 'event.delete', message: 'これです', previous: first,
      candidate_ref: candidate_ref)
    assert_no_difference('Event.count') { request_mutation('propose', followup) }
    assert_mutation_error 'expired', 410
    proposal = SecretaryMutationProposal.find_by!(public_id: first['proposal_id'])
    assert_equal 'expired', proposal.status
    assert_equal first['execution_expires_at'], proposal.execution_expires_at.utc.iso8601
  end

  test 'default off fails before JWKS replay or proposal writes' do
    @mutation_dependencies[:enabled] = false
    request_mutation('propose', mutation_propose(operation: 'event.delete', message: '任意を削除'))
    assert_mutation_error 'unavailable', 503
    assert_empty @mutation_dependencies.fetch(:jwks_provider).requested_kids
    assert_empty @mutation_dependencies.fetch(:replay_store).calls
    assert_empty SecretaryMutationProposal.where(user: @user)
  end

  private

  def create_event(title:, start_at: @now + 1.day, end_at: nil)
    Event.create!(created_by: @user, title: title, description: nil, location: '会議室',
      start_at: start_at, end_at: end_at || start_at + 1.hour, all_day: false, color: '#3b82f6')
  end
end
