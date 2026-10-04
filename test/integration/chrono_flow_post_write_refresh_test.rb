# frozen_string_literal: true

require 'test_helper'
require_relative '../services/secretary_mutation/test_support'

class ChronoFlowPostWriteRefreshTest < ActionDispatch::IntegrationTest
  include SecretaryMutationTestSupport

  READ_ROUTE = '/api/v1/specialists/chrono_flow'

  setup do
    @now = Time.zone.parse('2026-10-04 09:00:00.123456')
    @clock = -> { @now }
    @user = User.create!(name: 'Refresh owner', email: "refresh-#{SecureRandom.hex(5)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "refresh|#{SecureRandom.uuid}")
    @home_subject = SecureRandom.uuid
    @mutation_dependencies = mutation_dependencies(now: @clock)
    @read_dependencies = ChronoFlowSpecialist::Dependencies.build(
      configuration: test_configuration, clock: @clock,
      jwks_provider: FakeJwksProvider.new(keys: { TEST_KID => test_rsa_key.public_key }),
      replay_store: FakeReplayStore.new,
      refresh_scope_validator: ChronoFlowSpecialist::RefreshScopeValidator.new(configuration: mutation_configuration),
      fact_secret: 'refresh-fact-secret-at-least-thirty-two-bytes'
    )
  end

  test 'update receipt authorizes canonical read and repeat reads never repeat a write' do
    event = create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    assert_equal 'event_updated', completed.dig('receipt', 'domain_outcome')

    2.times do
      assert_no_difference(['Event.count', 'SecretaryMutationAudit.count', 'SecretaryMutationOutboxEntry.count']) do
        statements = capture_sql { post_refresh(completed.fetch('refresh_scope')) }
        assert_no_domain_writes(statements)
      end
      assert_response :success
      assert_equal 'completed', read_body['status']
      assert_equal ['変更済予定'], event_facts.map { |fact| fact.dig('fields', 'title') }
      assert_equal 'target_day', event_facts.sole.dig('fields', 'day_relation')
      assert_equal 1, summary['today_count']
      assert_equal false, summary['partial']
      assert_equal '2026-10-04', summary['target_date']
      assert_equal 'Asia/Tokyo', summary['time_zone']
    end
    assert_equal '変更済予定', event.reload.title
    assert_equal 1, SecretaryMutationAudit.where(event_type: 'mutation_completed').count
    assert_equal 1, SecretaryMutationOutboxEntry.where(event_type: 'secretary_mutation.completed').count
  end

  test 'delete read returns authoritative empty events and no false positive target' do
    event = create_event('削除予定')
    completed = complete_mutation('event.delete', '削除予定を削除')
    refute Event.exists?(event.id)
    statements = capture_sql { post_refresh(completed.fetch('refresh_scope')) }
    assert_response :success
    assert_empty event_facts
    assert_equal 0, summary['total_count']
    assert_equal 0, summary['today_count']
    assert_equal 0, summary['returned_count']
    assert_equal false, summary['partial']
    assert_no_domain_writes(statements)
  end

  test 'scope is bound to current identity home subject user version and time zone' do
    create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    scope = completed.fetch('refresh_scope')
    post_refresh(scope, claims: { 'sub' => SecureRandom.uuid })
    assert_refresh_rejected
    post_refresh(scope, zone: 'America/New_York')
    assert_refresh_rejected
    other = User.create!(name: 'Other owner', email: "other-#{SecureRandom.hex(5)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER, identity_subject: 'refresh|other')
    post_refresh(scope, claims: { 'identity_subject' => other.identity_subject })
    assert_refresh_rejected
    @user.update!(name: 'Updated profile', updated_at: @user.updated_at + 1.second)
    post_refresh(scope)
    assert_refresh_rejected
    @user.update!(status: 'suspended')
    post_refresh(scope)
    assert_response :forbidden
    assert_equal 'inactive_user', read_body.dig('error', 'code')
  end

  test 'expired altered unknown and malformed refresh scopes do not authorize reads' do
    create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    scope = completed.fetch('refresh_scope')
    post_refresh(scope.merge('security_context_digest' => '0' * 64))
    assert_refresh_rejected
    post_refresh(scope.merge('scope_ref' => "rs1_#{'A' * 43}"))
    assert_refresh_rejected
    post_refresh(scope.merge('unknown' => true))
    assert_response :unprocessable_entity
    post_refresh(scope.merge('expires_at' => 'not-a-time'))
    assert_response :unprocessable_entity
    post_refresh(nil)
    assert_response :unprocessable_entity
    @now += 601.seconds
    post_refresh(scope)
    assert_refresh_rejected
  end

  test 'signed supplementary request bindings cannot be changed or omitted' do
    create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    %w[capability http_method http_path body_sha256 request_id trace_id].each do |field|
      statements = capture_sql { post_refresh(completed.fetch('refresh_scope'), claims: { field => nil }) }
      assert_refresh_rejected
      refute statements.any? { |sql| sql.match?(/\bFROM\s+"events"/i) }
    end
    post_refresh(completed.fetch('refresh_scope'), claims: { 'http_method' => 'GET' })
    assert_refresh_rejected
    post_refresh(completed.fetch('refresh_scope'), claims: { 'body_sha256' => '0' * 64 })
    assert_refresh_rejected
  end

  test 'partial window explicitly reports canonical counts and bounded returned facts' do
    create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    24.times { |index| create_event("追加予定 #{index}") }
    post_refresh(completed.fetch('refresh_scope'))
    assert_response :success
    assert_equal 'partial', read_body['status']
    assert_equal ['schedule_context_truncated'], read_body['warnings']
    assert_equal 24, event_facts.length
    assert_equal 25, summary['total_count']
    assert_equal 25, summary['today_count']
    assert_equal 24, summary['returned_count']
    assert_equal true, summary['partial']
  end

  test 'provider classifies target day and outside day without shifting all day dates' do
    create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    create_event('明日予定', start_at: @now + 1.day)
    create_event('終日予定', start_at: @now.beginning_of_day, all_day: true, duration: 1.day)
    post_refresh(completed.fetch('refresh_scope'))
    assert_response :success
    assert_equal 3, summary['total_count']
    assert_equal 2, summary['today_count']
    all_day = event_facts.find { |fact| fact.dig('fields', 'title') == '終日予定' }
    assert_equal '2026-10-04', all_day.dig('fields', 'start_at')
    assert_equal '2026-10-05', all_day.dig('fields', 'end_at')
    assert_equal 'target_day', all_day.dig('fields', 'day_relation')
    outside = event_facts.find { |fact| fact.dig('fields', 'title') == '明日予定' }
    assert_equal 'outside_target_day', outside.dig('fields', 'day_relation')
  end

  test 'legacy omission is a partial warning not a silently authoritative zero' do
    create_event('更新予定')
    completed = complete_mutation('event.update', '更新予定のタイトルを変更済予定に変更')
    malformed = create_event('仮タイトル')
    malformed.update_columns(title: "\r\n\t")
    post_refresh(completed.fetch('refresh_scope'))
    assert_response :success
    assert_equal 'partial', read_body['status']
    assert_equal ['schedule_context_event_omitted'], read_body['warnings']
    assert_equal 2, summary['today_count']
    assert_equal 1, summary['returned_count']
    assert_equal true, summary['partial']
    assert_equal "\r\n\t", malformed.reload.title
  end

  private

  def create_event(title, start_at: @now + 1.hour, all_day: false, duration: 1.hour)
    Event.create!(created_by: @user, title: title, start_at: start_at, end_at: start_at + duration,
      all_day: all_day, color: '#3b82f6')
  end

  def complete_mutation(operation, message)
    request_mutation('propose', mutation_propose(operation: operation, message: message))
    assert_response :created
    ready = mutation_body
    assert_equal 'ready', ready['status']
    request_mutation('execute', mutation_confirm(ready))
    assert_response :success
    assert_equal 'completed', mutation_body['status']
    mutation_body
  end

  def post_refresh(scope, claims: {}, zone: 'Asia/Tokyo')
    payload = request_payload(constraints: { 'refresh_scope' => scope }, time_zone: zone)
    raw = JSON.generate(payload)
    bound = {
      'sub' => @home_subject, 'identity_issuer' => @user.identity_issuer,
      'identity_subject' => @user.identity_subject, 'capability' => 'schedule_context',
      'http_method' => 'POST', 'http_path' => READ_ROUTE, 'body_sha256' => Digest::SHA256.hexdigest(raw),
      'request_id' => payload['request_id'], 'trace_id' => payload['trace_id']
    }.merge(claims)
    token = build_token(now: @now.to_i, claim_overrides: bound)
    ChronoFlowSpecialist::Dependencies.with_test(@read_dependencies) do
      post READ_ROUTE, params: raw, headers: request_headers(payload: payload, token: token)
    end
  end

  def read_body
    JSON.parse(response.body)
  end

  def event_facts
    read_body.fetch('facts').select { |fact| fact['fact_type'] == 'schedule_event' }
  end

  def summary
    read_body.fetch('facts').find { |fact| fact['fact_type'] == 'schedule_summary' }.fetch('fields')
  end

  def assert_refresh_rejected
    assert_response :forbidden
    assert_equal 'insufficient_scope', read_body.dig('error', 'code')
  end

  def capture_sql
    statements = []
    subscriber = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { yield }
    statements
  end

  def assert_no_domain_writes(statements)
    refute statements.any? { |sql| sql.match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i) }
  end
end
