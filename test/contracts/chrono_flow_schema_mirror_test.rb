# frozen_string_literal: true

require 'test_helper'
require 'digest'
require 'json'
require 'open3'

class ChronoFlowSchemaMirrorTest < ActiveSupport::TestCase
  CANONICAL_REPOSITORY = ENV.fetch('AI_SECRETARY_HOME_REPOSITORY', '/home/kan/projects/ai_secretary_home')
  CANONICAL_COMMIT = 'c3ff4e3033f2d499696896fa0624069484cd4387'
  DRAFT_2020_12_URI = 'https://json-schema.org/draft/2020-12/schema'
  MIRROR_DIRECTORY = Rails.root.join('contracts/ai_secretary_home/v2.1')
  OPERATION_POLICY_PATH = Rails.root.join('contracts/ai_secretary_home/r3/chrono_flow_operation_policy.json')
  OPERATION_POLICY_CANONICAL_SHA256 = 'b753af0d01af0cb46730763daebbe02f6ef4c8f179a560f68574ccb47c20409d'
  EXPECTED_STATUS_CODE_MATRIX = {
    '400' => ['malformed_json'],
    '401' => %w[invalid_token expired_token replayed_token],
    '403' => %w[insufficient_scope inactive_user],
    '415' => ['unsupported_media_type'],
    '422' => %w[invalid_request_schema unsupported_capability],
    '500' => %w[invalid_response_schema internal_error],
    '503' => ['service_unavailable']
  }.freeze
  CANONICAL_JSON_SHA256 = {
    'specialist_request.schema.json' => '3a71db36ed228b9104162801b2717515b63108094e6dc940be736304c259a130',
    'specialist_response.schema.json' => 'b38e02a915a433f4868dda8e12b0011db9ed54b54904fe18861bab75f47df517',
    'specialist_error.schema.json' => '3c06d7e096e4962df583c99cf46ff84f9aa382453a5c864824fb81780b870cce',
    'action_proposal.schema.json' => '95adfdc50524d2a28bc035b55f00b8372cec25b75efafd49f156e85de3e07acb'
  }.freeze
  SOURCE_PATHS = CANONICAL_JSON_SHA256.keys.to_h do |name|
    [name, "contracts/#{name}"]
  end.freeze

  test 'mirror directory contains exactly four canonical schemas' do
    assert_equal CANONICAL_JSON_SHA256.keys.sort, MIRROR_DIRECTORY.children.map { |path| path.basename.to_s }.sort
  end

  test 'mirrors exact bytes from the sealed AI secretary commit' do
    SOURCE_PATHS.each do |name, source_path|
      source_bytes, error, status = Open3.capture3(
        'git', '-C', CANONICAL_REPOSITORY, 'show', "#{CANONICAL_COMMIT}:#{source_path}"
      )

      assert status.success?, "Cannot read #{source_path} at #{CANONICAL_COMMIT}: #{error}"
      assert_equal source_bytes.b, MIRROR_DIRECTORY.join(name).binread.b, "Byte mismatch for #{name}"
    end
  end

  test 'mirrors parse as Draft 2020-12 objects with sealed canonical JSON digests' do
    CANONICAL_JSON_SHA256.each do |name, expected_digest|
      schema = JSON.parse(MIRROR_DIRECTORY.join(name).binread)

      assert_instance_of Hash, schema
      assert_equal DRAFT_2020_12_URI, schema.fetch('$schema')
      assert_equal expected_digest, Digest::SHA256.hexdigest(canonical_json(schema))
    end
  end

  test 'operation policy seals route headers request shapes and validation precedence' do
    policy = operation_policy
    endpoint = policy.fetch('endpoint')
    request_policy = policy.fetch('request')

    assert_equal 'r3.1', policy.fetch('policy_version')
    assert_equal '/api/v1/specialists/chrono_flow', endpoint.fetch('route')
    assert_equal 'POST', endpoint.fetch('method')
    assert_equal 'NO_ROUTE_404', endpoint.fetch('non_post_behavior')
    assert_equal 65_536, request_policy.fetch('maximum_bytes')
    assert_equal({ 'status' => 422, 'code' => 'invalid_request_schema' }, request_policy.fetch('oversize_error'))
    assert_equal %w[Authorization Content-Type Accept X-Request-Id X-Trace-Id], request_policy.fetch('required_headers')
    assert_equal false, request_policy.dig('header_rules', 'Accept-Encoding', 'required')
    assert_equal 'identity', request_policy.dig('header_rules', 'Accept-Encoding', 'value_if_present')
    assert_equal [], request_policy.dig('context_refs', 'exact_value')
    assert_equal [
      '1_MEDIA_AND_REQUIRED_HEADER_VALIDATION',
      '2_BOUNDED_STRICT_JSON_PARSE_FULL_SCHEMA_OPERATION_POLICY_AND_CORRELATION_BINDING',
      '3_JWT_SIGNATURE_CLAIMS_AUDIENCE_AND_SCOPE_VALIDATION',
      '4_ATOMIC_REPLAY_CONSUMPTION',
      '5_EXACT_ACTIVE_LOCAL_USER_RESOLUTION',
      '6_CAPABILITY_DOMAIN_READ',
      '7_RESPONSE_CONTRACT_VALIDATION'
    ], policy.fetch('execution_precedence')
  end

  test 'operation policy closes both capability constraints and response fact fields' do
    policy = operation_policy
    capabilities = policy.dig('request', 'capabilities')
    schedule_shapes = capabilities.dig('schedule_context', 'constraints', 'allowed_shapes')
    connection = capabilities.dig('connection_verification', 'constraints')

    assert_equal 2, schedule_shapes.length
    assert_equal false, schedule_shapes.first.fetch('additionalProperties')
    assert_equal ['date_window'], schedule_shapes.last.fetch('required')
    assert_equal %w[end start], schedule_shapes.last.dig('properties', 'date_window', 'required').sort
    assert_equal false, schedule_shapes.last.dig('properties', 'date_window', 'additionalProperties')
    assert_equal ['operation'], connection.fetch('required')
    assert_equal %w[resolve_user verify_connection], connection.dig('properties', 'operation', 'enum')
    assert_equal false, connection.fetch('additionalProperties')

    assert_equal 'schedule_event', policy.dig('domain', 'schedule_context', 'fact', 'fact_type')
    assert_equal %w[all_day end_at location start_at title],
                 policy.dig('domain', 'schedule_context', 'fact', 'fields', 'required').sort
    assert_equal false, policy.dig('domain', 'schedule_context', 'fact', 'fields', 'additionalProperties')
    assert_equal 'connection_verification', policy.dig('domain', 'connection_verification', 'fact', 'fact_type')
    assert_equal %w[connected operation],
                 policy.dig('domain', 'connection_verification', 'fact', 'fields', 'required').sort
    assert_equal 524_288, policy.dig('response', 'maximum_bytes')
    assert_equal({ 'status' => 500, 'code' => 'invalid_response_schema' },
                 policy.dig('response', 'oversize_error'))
    assert_equal 60, policy.dig('response', 'stale_at', 'offset_seconds_from_generated_at')
  end

  test 'operation policy seals identity replay privacy and error boundaries' do
    policy = operation_policy

    assert_equal 'string', policy.dig('authentication', 'claims', 'aud', 'type')
    assert_equal 'chrono-flow-specialist', policy.dig('authentication', 'claims', 'aud', 'value')
    assert_equal 'string', policy.dig('authentication', 'claims', 'scope', 'type')
    assert_equal 'specialist:chrono_flow:read', policy.dig('authentication', 'claims', 'scope', 'value')
    assert_equal 'iss + NUL + aud + NUL + jti', policy.dig('replay_protection', 'digest', 'input')
    assert_equal ['NX', 'EX', 65], policy.dig('replay_protection', 'operation', 'options')
    assert_equal 1, policy.dig('replay_protection', 'operation', 'attempts')
    assert_equal false, policy.dig('replay_protection', 'operation', 'automatic_retry')
    assert_equal 0, policy.dig('domain', 'write_count')
    assert_equal 0, policy.dig('domain', 'read_before_replay_acceptance')
    assert_includes policy.dig('domain', 'schedule_context', 'excluded'), 'ANY_EVENT_WITH_EVENT_GROUP'
    assert_equal 'YYYY-MM-DD_FROM_APPLICATION_TIME_ZONE_WITHOUT_REQUEST_ZONE_SHIFT',
                 policy.dig('domain', 'schedule_context', 'time_zone', 'all_day_wire_values')
    assert_equal 'no-store', policy.dig('response', 'cache_control')
    assert_equal 'Bearer', policy.dig('errors', 'www_authenticate_on_401')
  end

  test 'operation policy is an exact closed object with the exact status code matrix' do
    policy = operation_policy

    assert_equal OPERATION_POLICY_CANONICAL_SHA256, Digest::SHA256.hexdigest(canonical_json(policy))
    assert_equal EXPECTED_STATUS_CODE_MATRIX, policy.dig('errors', 'status_code_matrix')
  end

  private

  def operation_policy
    @operation_policy ||= JSON.parse(OPERATION_POLICY_PATH.binread)
  end

  def canonical_json(value)
    JSON.generate(sort_object_keys(value))
  end

  def sort_object_keys(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, sort_object_keys(value.fetch(key))] }
    when Array
      value.map { |item| sort_object_keys(item) }
    else
      value
    end
  end
end
