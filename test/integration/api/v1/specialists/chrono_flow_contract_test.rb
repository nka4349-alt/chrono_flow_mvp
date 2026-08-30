# frozen_string_literal: true

require 'test_helper'
require 'time'
require_relative '../../../../services/chrono_flow_specialist/test_support'

class ApiV1SpecialistsChronoFlowContractTest < ActionDispatch::IntegrationTest
  include ChronoFlowSpecialistTestSupport

  ROUTE = '/api/v1/specialists/chrono_flow'
  PASSWORD = 'Password-123!'

  setup do
    @now = Time.zone.parse('2026-08-30 12:00:00')
    @claims = valid_claims(now: @now.to_i)
    @user = create_user(
      email: 'chrono-flow-specialist@example.test',
      identity_issuer: @claims.fetch('identity_issuer'),
      identity_subject: @claims.fetch('identity_subject')
    )
    @replay_store = FakeReplayStore.new
    @jwks_provider = FakeJwksProvider.new(keys: { 'test-kid' => test_rsa_key.public_key })
    @dependencies = handler_dependencies(
      jwks_provider: @jwks_provider,
      replay_store: @replay_store,
      clock: -> { @now }
    )
  end

  test 'canonical POST returns only personal schedule facts in the closed response contract' do
    owned = create_event(
      owner: @user,
      title: 'Owned event',
      start_at: @now.tomorrow.change(hour: 9),
      end_at: @now.tomorrow.change(hour: 10),
      description: 'must not leave provider'
    )
    other_user = create_user(email: 'participant-owner@example.test')
    participating = create_event(
      owner: other_user,
      title: 'Participating event',
      start_at: @now.tomorrow.change(hour: 11),
      end_at: @now.tomorrow.change(hour: 12)
    )
    EventParticipant.create!(event: participating, user: @user)

    group_event = create_event(
      owner: @user,
      title: 'Group event must be excluded',
      start_at: @now.tomorrow.change(hour: 13),
      end_at: @now.tomorrow.change(hour: 14)
    )
    group = Group.create!(name: 'Private group', owner_id: @user.id)
    EventGroup.create!(event: group_event, group: group)

    statements = capture_sql { post_contract }

    assert_response :success
    body = parsed_body
    assert_equal '2.1', body.fetch('version')
    assert_equal 'chrono_flow_ai', body.fetch('specialist')
    assert_equal 'completed', body.fetch('status')
    assert_equal [], body.fetch('proposals')
    assert_equal [], body.fetch('warnings')
    assert_equal request_payload.fetch('request_id'), body.fetch('request_id')
    assert_equal request_payload.fetch('call_id'), body.fetch('call_id')
    assert_equal request_payload.fetch('trace_id'), body.fetch('trace_id')
    assert_equal 60, Time.iso8601(body.fetch('stale_at')).to_i - Time.iso8601(body.fetch('generated_at')).to_i
    assert_equal 'no-store', response.headers['Cache-Control']

    facts = body.fetch('facts')
    assert_equal ['Owned event', 'Participating event'], facts.map { |fact| fact.dig('fields', 'title') }
    facts.each do |fact|
      assert_equal 'schedule_event', fact.fetch('fact_type')
      assert_equal %w[all_day end_at location start_at title], fact.fetch('fields').keys.sort
      assert fact.key?('source_updated_at')
      refute_equal owned.id.to_s, fact.fetch('id')
      refute_equal participating.id.to_s, fact.fetch('id')
      refute_includes fact.to_json, 'must not leave provider'
      refute_includes fact.to_json, other_user.email
      refute_includes fact.to_json, group.name
    end
    assert_no_domain_writes(statements)
  end

  test 'schedule_context enforces maximum 24 and deterministic opaque fact order' do
    shared_start = @now.tomorrow.change(hour: 9)
    25.times do |index|
      create_event(
        owner: @user,
        title: "Event #{index}",
        start_at: shared_start,
        end_at: shared_start + 30.minutes
      )
    end

    post_contract

    assert_response :success
    facts = parsed_body.fetch('facts')
    assert_equal 24, facts.length
    assert_equal facts.map { |fact| fact.fetch('id') }.sort, facts.map { |fact| fact.fetch('id') }
    refute facts.any? { |fact| fact.fetch('id').match?(/\A\d+\z/) }
  end

  test 'schedule_context accepts only the exact computed date window when supplied' do
    local_start = @now.in_time_zone('Asia/Tokyo').to_date
    payload = request_payload(
      constraints: {
        'date_window' => {
          'start' => local_start.iso8601,
          'end' => (local_start + 14).iso8601
        }
      }
    )

    post_contract(payload: payload)
    assert_response :success

    payload['constraints']['date_window']['end'] = (local_start + 13).iso8601
    post_contract(payload: payload, token: fresh_token(jti: 'wrong-date-window'))
    assert_contract_error status: 422, code: 'invalid_request_schema'
  end

  test 'all-day dates are emitted without request-zone shifting' do
    all_day_start = Time.zone.local(2026, 8, 31)
    create_event(
      owner: @user,
      title: 'All day event',
      start_at: all_day_start,
      end_at: all_day_start + 1.day,
      all_day: true
    )
    payload = request_payload(time_zone: 'America/New_York')

    post_contract(payload: payload)

    assert_response :success
    fields = parsed_body.fetch('facts').sole.fetch('fields')
    assert_equal '2026-08-31', fields.fetch('start_at')
    assert_equal '2026-09-01', fields.fetch('end_at')
    assert_equal true, fields.fetch('all_day')
  end

  test 'both connection verification operations return one closed fact and no event data' do
    create_event(
      owner: @user,
      title: 'Must not be read for verification',
      start_at: @now.tomorrow.change(hour: 9),
      end_at: @now.tomorrow.change(hour: 10)
    )
    %w[resolve_user verify_connection].each do |operation|
      payload = request_payload(
        capability: 'connection_verification',
        constraints: { 'operation' => operation }
      )

      statements = capture_sql do
        post_contract(payload: payload, token: fresh_token(jti: "connection-#{operation}"))
      end

      assert_response :success
      body = parsed_body
      assert_equal [], body.fetch('proposals')
      fact = body.fetch('facts').sole
      assert_equal 'connection_verification', fact.fetch('fact_type')
      assert_equal({ 'operation' => operation, 'connected' => true }, fact.fetch('fields'))
      assert fact.key?('source_updated_at')
      refute_includes fact.to_json, 'Must not be read for verification'
      assert_no_domain_writes(statements)
      refute statements.any? { |sql| sql.match?(/\bFROM\s+"events"/i) }, statements.inspect
    end
  end

  test 'connection verification rejects unknown operation keys and values' do
    unknown_key = request_payload(
      capability: 'connection_verification',
      constraints: { 'operation' => 'resolve_user', 'user_id' => @user.id }
    )
    post_contract(payload: unknown_key)
    assert_contract_error status: 422, code: 'invalid_request_schema'

    unknown_operation = request_payload(
      capability: 'connection_verification',
      constraints: { 'operation' => 'discover_everyone' }
    )
    post_contract(payload: unknown_operation, token: fresh_token(jti: 'unknown-operation'))
    assert_contract_error status: 422, code: 'invalid_request_schema'
  end

  test 'media validation has precedence and Accept-Encoding is optional identity-only' do
    post_contract(header_overrides: { 'Content-Type' => 'text/plain' })
    assert_contract_error status: 415, code: 'unsupported_media_type'

    post_contract(
      token: fresh_token(jti: 'wrong-accept'),
      header_overrides: { 'Accept' => 'text/html' }
    )
    assert_contract_error status: 415, code: 'unsupported_media_type'

    post_contract(
      token: fresh_token(jti: 'wrong-encoding'),
      header_overrides: { 'Accept-Encoding' => 'gzip' }
    )
    assert_contract_error status: 415, code: 'unsupported_media_type'

    post_contract(
      token: fresh_token(jti: 'no-encoding'),
      delete_headers: ['Accept-Encoding']
    )
    assert_response :success
  end

  test 'strict JSON rejects malformed duplicate and unknown keys before domain reads' do
    post_contract(raw_body: '{')
    assert_contract_error status: 400, code: 'malformed_json'

    duplicate = JSON.generate(request_payload).sub(
      '"constraints":{}',
      '"constraints":{},"constraints":{}'
    )
    post_contract(raw_body: duplicate, token: fresh_token(jti: 'duplicate-json'))
    assert_contract_error status: 400, code: 'malformed_json'

    unknown = request_payload.merge('user_id' => @user.id)
    post_contract(payload: unknown, token: fresh_token(jti: 'unknown-top-level'))
    assert_contract_error status: 422, code: 'invalid_request_schema'

    nonempty_context = request_payload.merge('context_refs' => [{ 'kind' => 'home_context', 'id' => 'context-1' }])
    post_contract(payload: nonempty_context, token: fresh_token(jti: 'nonempty-context'))
    assert_contract_error status: 422, code: 'invalid_request_schema'
  end

  test 'request byte limit and header body correlation are fail closed' do
    oversized = JSON.generate(request_payload.merge('user_message' => 'x' * 66_000))
    post_contract(raw_body: oversized)
    assert_contract_error status: 422, code: 'invalid_request_schema'

    post_contract(
      token: fresh_token(jti: 'correlation-mismatch'),
      header_overrides: { 'X-Request-Id' => 'different-request-id' }
    )
    assert_contract_error status: 422, code: 'invalid_request_schema'
  end

  test 'Bearer JWT is the only authority and 401 responses carry canonical headers' do
    post_contract(delete_headers: ['Authorization'], header_overrides: { 'Cookie' => '_session=not-authority' })
    assert_contract_error status: 401, code: 'invalid_token'
    assert_equal 'Bearer', response.headers['WWW-Authenticate']

    expired = fresh_token(
      jti: 'expired-token',
      claim_overrides: { 'iat' => @now.to_i - 60, 'exp' => @now.to_i - 10 }
    )
    post_contract(token: expired)
    assert_contract_error status: 401, code: 'expired_token'
    assert_equal 'Bearer', response.headers['WWW-Authenticate']
  end

  test 'scope user state and replay failures use exact generic mappings' do
    wrong_scope = fresh_token(
      jti: 'wrong-scope',
      claim_overrides: { 'scope' => 'specialist:other:read' }
    )
    post_contract(token: wrong_scope)
    assert_contract_error status: 403, code: 'insufficient_scope'

    @user.update!(status: 'suspended')
    post_contract(token: fresh_token(jti: 'suspended-user'))
    assert_contract_error status: 403, code: 'inactive_user'

    @user.update!(status: 'active')
    replayed = fresh_token(jti: 'one-use-only')
    post_contract(token: replayed)
    assert_response :success
    replay_statements = capture_sql { post_contract(token: replayed) }
    assert_contract_error status: 401, code: 'replayed_token'
    assert_empty replay_statements.grep(/\bFROM\s+"(?:users|events)"/i)
    assert_no_domain_writes(replay_statements)
  end

  test 'local user resolution uses only exact signed identity and never JWT sub or unsigned headers' do
    unrelated_public_uuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    accepted = fresh_token(
      jti: 'different-public-sub',
      claim_overrides: { 'sub' => unrelated_public_uuid }
    )
    post_contract(token: accepted, header_overrides: { 'X-User-Id' => '999999' })
    assert_response :success

    missing_subject = 'provider|missing-user'
    missing = fresh_token(
      jti: 'missing-local-identity',
      claim_overrides: { 'identity_subject' => missing_subject }
    )
    post_contract(token: missing, header_overrides: { 'X-User-Id' => @user.id.to_s })
    assert_contract_error status: 403, code: 'inactive_user'
    refute_includes response.body, missing_subject

    case_mismatch = fresh_token(
      jti: 'case-mismatched-identity',
      claim_overrides: { 'identity_subject' => @claims.fetch('identity_subject').upcase }
    )
    post_contract(token: case_mismatch)
    assert_contract_error status: 403, code: 'inactive_user'
  end

  test 'missing security configuration fails before JWKS replay or domain access' do
    @dependencies = handler_dependencies(
      configuration: ChronoFlowSpecialist::Configuration.new({}),
      jwks_provider: @jwks_provider,
      replay_store: @replay_store,
      clock: -> { @now }
    )

    statements = capture_sql { post_contract }

    assert_contract_error status: 503, code: 'service_unavailable'
    assert_empty @jwks_provider.requested_kids
    assert_empty @replay_store.calls
    assert_empty statements.grep(/\bFROM\s+"(?:users|events)"/i)
    assert_no_domain_writes(statements)
  end

  test 'oversized success projection fails closed with a small canonical error' do
    create_event(
      owner: @user,
      title: 'x' * ChronoFlowSpecialist::ResponseBuilder::MAX_RESPONSE_BYTES,
      start_at: @now.tomorrow.change(hour: 9),
      end_at: @now.tomorrow.change(hour: 10)
    )

    post_contract

    assert_contract_error status: 500, code: 'invalid_response_schema'
    assert_operator response.body.bytesize, :<, 1_024
  end

  test 'Rails JSON escape expansion cannot exceed the exact wire response limit' do
    escape_heavy_title = '<' * 100_000
    assert_operator ActiveSupport::JSON.encode('title' => escape_heavy_title).bytesize,
                    :>,
                    ChronoFlowSpecialist::ResponseBuilder::MAX_RESPONSE_BYTES
    create_event(
      owner: @user,
      title: escape_heavy_title,
      start_at: @now.tomorrow.change(hour: 9),
      end_at: @now.tomorrow.change(hour: 10)
    )

    post_contract

    assert_contract_error status: 500, code: 'invalid_response_schema'
    assert_operator response.body.bytesize, :<, 1_024
  end

  test 'replay cache unavailability fails closed without exposing diagnostics' do
    @replay_store = FakeReplayStore.new(result: :unavailable)
    @dependencies = handler_dependencies(
      jwks_provider: @jwks_provider,
      replay_store: @replay_store,
      clock: -> { @now }
    )

    statements = capture_sql { post_contract }

    assert_contract_error status: 503, code: 'service_unavailable'
    refute_includes response.body, 'redis'
    refute_includes response.body, @claims.fetch('identity_subject')
    assert_empty statements.grep(/\bFROM\s+"(?:users|events)"/i)
    assert_no_domain_writes(statements)
  end

  test 'canonical endpoint is POST-only and has no legacy redirect' do
    with_dependencies do
      get ROUTE, headers: { 'Accept' => 'application/json' }
    end

    assert_response :not_found
  end

  private

  def post_contract(
    payload: request_payload,
    token: fresh_token,
    raw_body: nil,
    header_overrides: {},
    delete_headers: []
  )
    headers = request_headers(payload: payload, token: token, overrides: header_overrides)
    delete_headers.each { |name| headers.delete(name) }

    with_dependencies do
      post ROUTE, params: raw_body || JSON.generate(payload), headers: headers
    end
  end

  def with_dependencies(&block)
    ChronoFlowSpecialist::Dependencies.with_test(@dependencies, &block)
  end

  def fresh_token(jti: 'integration-jti', claim_overrides: {})
    build_token(
      now: @now.to_i,
      claim_overrides: { 'jti' => jti }.merge(claim_overrides)
    )
  end

  def assert_contract_error(status:, code:)
    assert_response status
    body = parsed_body
    assert_equal '2.1', body.fetch('version')
    assert_equal code, body.dig('error', 'code')
    assert_kind_of String, body.dig('error', 'message')
    assert_equal 'no-store', response.headers['Cache-Control']
    refute_includes response.body, @claims.fetch('identity_subject')
  end

  def capture_sql
    statements = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      statements << payload.fetch(:sql) unless payload[:name] == 'SCHEMA'
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    statements
  end

  def assert_no_domain_writes(statements)
    writes = statements.select { |sql| sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i) }
    assert_empty writes, writes.inspect
  end

  def parsed_body
    JSON.parse(response.body)
  end

  def create_user(email:, identity_issuer: nil, identity_subject: nil, status: 'active')
    User.create!(
      name: 'Specialist Test User',
      email: email,
      password: PASSWORD,
      password_confirmation: PASSWORD,
      identity_issuer: identity_issuer,
      identity_subject: identity_subject,
      status: status
    )
  end

  def create_event(owner:, title:, start_at:, end_at:, all_day: false, description: nil)
    Event.create!(
      created_by: owner,
      title: title,
      start_at: start_at,
      end_at: end_at,
      all_day: all_day,
      description: description,
      location: 'Test location',
      color: '#3b82f6'
    )
  end
end
