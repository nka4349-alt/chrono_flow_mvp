# frozen_string_literal: true

require 'test_helper'
require_relative '../services/chrono_flow_specialist/test_support'

class SecretaryCreationProposalsTest < ActionDispatch::IntegrationTest
  include ChronoFlowSpecialistTestSupport
  ROUTE = '/api/v1/secretary/creation_proposals'

  setup do
    @now = Time.zone.parse('2026-09-20 09:00:00')
    @user = User.create!(name: 'Owner', email: "creation-#{SecureRandom.hex(4)}@example.test", password: 'Password-123!',
      identity_issuer: TEST_IDENTITY_ISSUER, identity_subject: "creation|#{SecureRandom.uuid}")
    @subject = SecureRandom.uuid
    @dependencies = { enabled: true, configuration: test_configuration,
      jwks_provider: FakeJwksProvider.new(keys: { TEST_KID => test_rsa_key.public_key }),
      replay_store: FakeReplayStore.new, clock: -> { @now }, parser: SecretaryCreation::EventParser }
  end

  test 'missing end asks then real parser accepts short answer and confirmation saves one personal event' do
    assert_no_difference ['Event.count', 'EventParticipant.count', 'AiConversation.count', 'AiRecommendation.count'] do
      request_creation('propose', propose('今日18時に来客を予定に入れて'))
    end
    assert_response :created
    first = body
    assert_equal 'needs_clarification', first['status']
    assert_includes first['question'], '終了'
    assert_no_difference 'Event.count' do
      request_creation('propose', propose('19時まで', previous: first))
    end
    assert_response :success
    ready = body
    assert_equal 'ready', ready['status'], ready.inspect
    assert_equal 2, ready['revision']
    assert_equal '来客', ready.dig('details', 'title')
    assert_equal '2026-09-20T18:00:00+09:00', ready.dig('details', 'start_at')
    assert_equal '2026-09-20T19:00:00+09:00', ready.dig('details', 'end_at')
    confirm = confirmation(ready)
    assert_difference ['Event.count', 'EventParticipant.count'], 1 do
      request_creation('create', confirm)
    end
    assert_response :success
    receipt = body
    assert_equal 'completed', receipt['status']
    assert_equal ready['details'], receipt['details']
    event = Event.order(:id).last
    assert_equal @user.id, event.created_by_id
    assert_equal [@user.id], event.event_participants.pluck(:user_id)
    assert_equal 'copied', event.event_participants.first.source
    assert_empty event.event_groups
    assert_no_difference 'Event.count' do
      request_creation('create', confirm.merge('request_id' => SecureRandom.uuid))
    end
    assert_response :success
    assert_equal receipt['result_id'], body['result_id']
    @now += 2.days
    request_creation('create', confirm.merge('request_id' => SecureRandom.uuid))
    assert_response :success
    assert_equal receipt['result_id'], body['result_id']
  end

  test 'full restatement increments revision and stale confirm cannot execute' do
    ready = ready_proposal
    stale = confirmation(ready)
    request_creation('propose', propose('明日20時から21時まで夕食を予定に追加', previous: ready))
    assert_response :success
    assert_equal 'ready', body['status'], body.inspect
    assert_equal 2, body['revision']
    refute_equal ready['content_digest'], body['content_digest']
    assert_no_difference('Event.count') { request_creation('create', stale) }
    assert_error 'proposal_changed', 409
  end

  test 'cancel and expiration are permanent and status returns terminal state' do
    ready = ready_proposal
    request_creation('cancel', cancel_request(ready))
    assert_equal 'cancelled', body['status']
    assert_no_difference('Event.count') { request_creation('create', confirmation(ready)) }
    assert_error 'proposal_changed', 409
    request_creation('propose', propose('明日20時から21時まで夕食を追加', previous: ready))
    assert_error 'proposal_changed', 409
    other = ready_proposal
    @now += 16.minutes
    request_creation('status', nil, proposal_id: other['proposal_id'])
    assert_response :success
    assert_equal 'expired', body['status']
    assert_no_difference('Event.count') { request_creation('create', confirmation(other)) }
    assert_error 'expired', 410
  end

  test 'new conflict prevents stale candidate from being saved at any substituted time' do
    ready = ready_proposal
    details = ready['details']
    Event.create!(created_by: @user, title: 'Just added', start_at: details['start_at'], end_at: details['end_at'])
    assert_no_difference('Event.count') { request_creation('create', confirmation(ready)) }
    assert_error 'proposal_changed', 409
    assert_equal 'ready', SecretaryCreationProposal.find_by!(public_id: ready['proposal_id']).status
  end

  test 'initial overlap asks another time without writing an event' do
    Event.create!(created_by: @user, title: 'Busy', start_at: @now.tomorrow.change(hour: 18), end_at: @now.tomorrow.change(hour: 19))
    assert_no_difference('Event.count') { request_creation('propose', propose('明日18時から19時まで来客を追加')) }
    assert_response :created
    assert_equal 'needs_clarification', body['status']
    assert_nil body['details']
  end

  test 'completed proposal cannot use another key be revised or cancelled' do
    ready = ready_proposal
    request_creation('create', confirmation(ready))
    assert_equal 'completed', body['status']
    assert_no_difference('Event.count') { request_creation('create', confirmation(ready)) }
    assert_error 'already_completed', 409
    request_creation('cancel', cancel_request(ready))
    assert_error 'already_completed', 409
    request_creation('propose', propose('明日20時から21時まで夕食を追加', previous: ready))
    assert_error 'already_completed', 409
  end

  test 'idempotency key cannot be used for another proposal and database enforces uniqueness' do
    first = ready_proposal
    first_confirm = confirmation(first)
    request_creation('create', first_confirm)
    assert_response :success
    request_creation('propose', propose('明日20時から21時まで夕食を追加'))
    second = body
    assert_equal 'ready', second['status']
    assert_no_difference 'Event.count' do
      request_creation('create', confirmation(second).merge('idempotency_key' => first_confirm['idempotency_key']))
    end
    assert_error 'idempotency_conflict', 409
    indexes = ActiveRecord::Base.connection.indexes('secretary_creation_proposals')
    assert indexes.any? { |index| index.unique && index.columns == %w[user_id idempotency_key] }
  end

  test 'actor identity home subject and active status are checked again on confirm and status' do
    ready = ready_proposal
    confirm = confirmation(ready)
    assert_no_difference 'Event.count' do
      request_creation('create', confirm, claims: { 'sub' => SecureRandom.uuid })
    end
    assert_error 'not_found', 404
    request_creation('status', nil, proposal_id: ready['proposal_id'], claims: { 'sub' => SecureRandom.uuid })
    assert_error 'not_found', 404
    @user.update!(status: 'suspended')
    assert_no_difference('Event.count') { request_creation('create', confirm) }
    assert_error 'forbidden', 403
    @user.update!(status: 'active', identity_subject: 'changed')
    request_creation('create', confirm, claims: { 'identity_subject' => 'changed' })
    assert_error 'not_found', 404
  end

  test 'read tokens wrong scope workspace claims and request tampering are rejected' do
    payload = propose('明日18時から19時まで来客を追加')
    cases = [
      { 'aud' => 'chrono-flow-specialist', 'scope' => 'specialist:chrono_flow:read' },
      { 'scope' => 'secretary:chrono_flow:create' }, { 'workspace_id' => SecureRandom.uuid },
      { 'creation_method' => 'GET' }, { 'creation_path' => '/somewhere' }, { 'creation_body_sha256' => '0' * 64 }
    ]
    cases.each do |claims|
      assert_no_difference(['Event.count', 'SecretaryCreationProposal.count']) { request_creation('propose', payload, claims: claims) }
      assert_error 'unauthenticated', 401
    end
  end

  test 'confirm accepts no editable title or execution arguments and checks digest' do
    ready = ready_proposal
    assert_no_difference 'Event.count' do
      request_creation('create', confirmation(ready).merge('title' => 'tampered'))
    end
    assert_error 'invalid_request', 400
    assert_no_difference 'Event.count' do
      request_creation('create', confirmation(ready).merge('content_digest' => '0' * 64))
    end
    assert_error 'proposal_changed', 409
  end

  test 'default disabled gate refuses before parser or JWKS are used' do
    @dependencies[:enabled] = false
    request_creation('propose', propose('明日18時から19時まで来客を追加'))
    assert_error 'unavailable', 503
    assert_empty @dependencies[:jwks_provider].requested_kids
    assert_empty @dependencies[:replay_store].calls
    assert_nil SecretaryCreationProposal.find_by(user: @user)
  end

  test 'replayed JWT is rejected while fresh JWT with same confirmation key is supported' do
    payload = propose('明日18時から19時まで来客を追加')
    token = signed_token('propose', ROUTE, JSON.generate(payload), {})
    request_creation('propose', payload, token: token)
    assert_response :created
    assert_no_difference(['Event.count', 'SecretaryCreationProposal.count']) { request_creation('propose', payload, token: token) }
    assert_error 'unauthenticated', 401
  end

  test 'future issued token within clock skew stays replay protected for its whole accepted lifetime' do
    payload = propose('明日18時から19時まで来客を追加')
    token = signed_token('propose', ROUTE, JSON.generate(payload), { 'iat' => @now.to_i + 5, 'exp' => @now.to_i + 65 })
    request_creation('propose', payload, token: token)
    assert_response :created
    assert_equal 71, @dependencies[:replay_store].calls.last.fetch(:ttl_seconds)
    @now += 66.seconds
    assert_no_difference 'SecretaryCreationProposal.count' do
      request_creation('propose', payload, token: token)
    end
    assert_error 'unauthenticated', 401
  end

  test 'account deletion still removes its ready proposals and completed receipts' do
    ready = ready_proposal
    request_creation('create', confirmation(ready))
    assert_equal 'completed', body['status']
    request_creation('propose', propose('明日20時から21時まで夕食を追加'))
    assert_equal 'ready', body['status']
    user_id = @user.id
    assert_equal 2, SecretaryCreationProposal.where(user_id: user_id).count
    AccountDeletionService.call(@user)
    refute User.exists?(user_id)
    assert_empty SecretaryCreationProposal.where(user_id: user_id)
    assert_empty Event.where(created_by_id: user_id)
  end

  test 'domain and receipt rollback together if participant save fails' do
    ready = ready_proposal
    # Exercise the normal writer rollback through invalid model validation.
    EventParticipant.validate :creation_test_reject, on: :create
    EventParticipant.define_method(:creation_test_reject) { errors.add(:base, 'test rejection') }
    assert_no_difference(['Event.count', 'EventParticipant.count']) { request_creation('create', confirmation(ready)) }
    assert_error 'unavailable', 503
    draft = SecretaryCreationProposal.find_by!(public_id: ready['proposal_id'])
    assert_equal 'ready', draft.status
    assert_nil draft.result_id
  ensure
    EventParticipant.skip_callback(:validate, :before, :creation_test_reject, raise: false)
    EventParticipant.remove_method(:creation_test_reject) if EventParticipant.method_defined?(:creation_test_reject)
  end

  test 'revision and identity are rechecked after candidate interpretation' do
    ready = ready_proposal
    @dependencies[:parser] = lambda do |**|
      SecretaryCreationProposal.find_by!(public_id: ready['proposal_id']).update!(revision: 2,
        status: 'needs_clarification', question: '別の変更', details: nil, content_digest: nil)
      { status: 'ready', question: nil, details: ready['details'] }
    end
    request_creation('propose', propose('明日20時から21時まで夕食を追加', previous: ready))
    assert_error 'proposal_changed', 409
    @dependencies[:parser] = lambda do |**|
      @user.update!(status: 'suspended')
      { status: 'needs_clarification', question: '終了時刻は？', details: nil }
    end
    assert_no_difference 'SecretaryCreationProposal.count' do
      request_creation('propose', propose('今日18時に来客を追加'))
    end
    assert_error 'forbidden', 403
  end

  test 'malformed duplicate and unexpected input is rejected without exposing raw parameters to instrumentation' do
    payload = propose('明日18時から19時まで来客を追加')
    raw_inputs = ['{"message":', '{"message":"first","message":"second"}',
      JSON.generate(payload.merge('identity_subject' => 'sensitive-body-marker'))]
    observed = []
    callback = -> (*args) { observed << args.last.fetch(:params) }
    ActiveSupport::Notifications.subscribed(callback, 'start_processing.action_controller') do
      raw_inputs.each do |raw|
        assert_no_difference ['Event.count', 'SecretaryCreationProposal.count'] do
          request_creation('propose', payload, raw_body: raw)
        end
        assert_error 'invalid_request', 400
      end
    end
    assert_equal [{}, {}, {}], observed
  end

  test 'invalid correlation IDs and media types still produce a canonical safe error' do
    payload = propose('明日18時から19時まで来客を追加')
    request_creation('propose', payload, headers_override: { 'X-Request-Id' => '00000000-0000-0000-0000-000000000000' })
    assert_error 'invalid_request', 400
    assert_nil body['request_id']
    request_creation('propose', payload, headers_override: { 'Content-Type' => 'text/plain' })
    assert_error 'invalid_request', 400
  end

  private

  def ready_proposal
    request_creation('propose', propose('明日18時から19時まで来客を予定に追加'))
    assert_response :created
    assert_equal 'ready', body['status'], body.inspect
    body
  end

  def propose(message, previous: nil)
    { 'version' => '1.0', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'message' => message, 'locale' => 'ja-JP', 'time_zone' => 'Asia/Tokyo',
      'proposal_id' => previous&.fetch('proposal_id'), 'expected_revision' => previous&.fetch('revision') }
  end

  def confirmation(ready)
    cancel_request(ready).merge('content_digest' => ready['content_digest'], 'idempotency_key' => SecureRandom.uuid)
  end

  def cancel_request(ready)
    { 'version' => '1.0', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'proposal_id' => ready['proposal_id'], 'revision' => ready['revision'] }
  end

  def request_creation(operation, payload, proposal_id: nil, claims: {}, token: nil, raw_body: nil, headers_override: {})
    id = proposal_id || payload&.[]('proposal_id')
    suffix = { 'create' => '/confirm', 'cancel' => '/cancel', 'status' => '' }[operation]
    path = operation == 'propose' ? ROUTE : "#{ROUTE}/#{id}#{suffix}"
    raw = raw_body || (payload ? JSON.generate(payload) : '')
    headers = { 'Accept' => 'application/json', 'Content-Type' => 'application/json',
      'X-Request-Id' => payload&.[]('request_id') || SecureRandom.uuid, 'X-Trace-Id' => payload&.[]('trace_id') || SecureRandom.uuid,
      'Authorization' => "Bearer #{token || signed_token(operation, path, raw,claims)}" }.merge(headers_override)
    SecretaryCreation::Dependencies.with_test(@dependencies) do
      operation == 'status' ? get(path, headers: headers) : post(path, params: raw, headers: headers)
    end
  end

  def signed_token(operation, path, raw, overrides)
    build_token(now: @now.to_i, claim_overrides: {
      'aud' => 'chrono-flow-secretary-actions', 'scope' => "secretary:chrono_flow:#{operation}",
      'sub' => @subject, 'identity_issuer' => @user.identity_issuer, 'identity_subject' => @user.identity_subject,
      'creation_method' => operation == 'status' ? 'GET' : 'POST', 'creation_path' => path,
      'creation_body_sha256' => Digest::SHA256.hexdigest(raw)
    }.merge(overrides))
  end

  def body = JSON.parse(response.body)

  def assert_error(code, status)
    assert_response status
    assert_equal code, body.dig('error', 'code'), body.inspect
    SecretaryCreation::Contract.validate_error!(body)
  end
end
