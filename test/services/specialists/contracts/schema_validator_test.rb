# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'tmpdir'

class SpecialistsContractsSchemaValidatorTest < ActiveSupport::TestCase
  Validator = Specialists::Contracts::SchemaValidator
  DRAFT_2020_12 = 'https://json-schema.org/draft/2020-12/schema'
  SECRET_INPUTS = [
    'Bearer raw-token-for-validator-test',
    'identity-subject-for-validator-test',
    'private-user@example.test',
    'Confidential schedule title in Shinjuku'
  ].freeze

  test 'accepts a valid specialist request' do
    assert validator.validate!(valid_request, schema_name: 'specialist_request.schema.json')
  end

  test 'accepts a valid specialist response with a nonempty externally referenced proposal' do
    assert validator.validate!(valid_response, schema_name: 'specialist_response.schema.json')
  end

  test 'accepts a valid specialist error with nonempty locally referenced safe details' do
    assert validator.validate!(valid_error, schema_name: 'specialist_error.schema.json')
  end

  test 'accepts a valid action proposal' do
    assert validator.validate!(valid_action_proposal, schema_name: 'action_proposal.schema.json')
  end

  test 'resolves external file and local fragment references' do
    assert validator.resolve_ref!(
      schema_name: 'specialist_response.schema.json',
      ref: 'action_proposal.schema.json'
    )
    assert validator.resolve_ref!(
      schema_name: 'specialist_error.schema.json',
      ref: '#/$defs/safe_details'
    )
  end

  test 'rejects a missing required property' do
    payload = valid_request
    payload.delete('user_message')

    assert_invalid payload, 'specialist_request.schema.json', '$.user_message'
  end

  test 'rejects a value with the wrong type' do
    payload = valid_request.merge('request_id' => 123)

    assert_invalid payload, 'specialist_request.schema.json', '$.request_id'
  end

  test 'rejects an additional property without exposing its name or value' do
    payload = valid_request.merge('raw_authorization' => SECRET_INPUTS.first)

    error = assert_invalid(payload, 'specialist_request.schema.json', '$')
    refute_includes error.message, 'raw_authorization'
    refute_includes error.message, SECRET_INPUTS.first
  end

  test 'rejects duplicate logical JSON keys without exposing the unvalidated value' do
    secret_value = 'UNVALIDATED-SYMBOL-KEY-SECRET'
    payload = valid_response.merge(version: secret_value)

    error = assert_invalid(payload, 'specialist_response.schema.json', '$')
    refute_includes error.message, secret_value
    refute_includes error.inspect, secret_value
  end

  test 'rejects invalid RFC 3339 date-time forms' do
    invalid_date_times = [
      '2026-05-18T03:00:00',
      '2026-05-18T24:00:00Z',
      '2026-05-18T03:00:00+24:00'
    ]

    invalid_date_times.each do |date_time|
      payload = valid_response.merge('generated_at' => date_time)
      assert_invalid payload, 'specialist_response.schema.json', '$.generated_at'
    end
  end

  test 'rejects a value that does not match exactly one oneOf branch' do
    payload = valid_response.merge('clarification' => 'not-null-or-object')

    assert_invalid payload, 'specialist_response.schema.json', '$.clarification'
  end

  test 'rejects enum and const mismatches' do
    request = valid_request.merge('specialist' => 'unknown_specialist')
    proposal = valid_action_proposal.merge('version' => '2.0')

    assert_invalid request, 'specialist_request.schema.json', '$.specialist'
    assert_invalid proposal, 'action_proposal.schema.json', '$.version'
  end

  test 'enforces string array and number bounds used by the canonical schemas' do
    short_string = valid_action_proposal.merge('label' => '')
    long_string = valid_error
    long_string['error']['message'] = 'x' * 257
    too_many_items = valid_error
    too_many_items['error']['details']['fields'] = Array.new(33) { |index| "field_#{index}" }
    duplicate_items = valid_error
    duplicate_items['error']['details']['fields'] = %w[locale locale]
    below_minimum = valid_error
    below_minimum['error']['details']['retry_after_seconds'] = -1
    above_maximum = valid_response.merge('confidence' => 1.01)

    assert_invalid short_string, 'action_proposal.schema.json', '$.label'
    assert_invalid long_string, 'specialist_error.schema.json', '$.error.message'
    assert_invalid too_many_items, 'specialist_error.schema.json', '$.error.details.fields'
    assert_invalid duplicate_items, 'specialist_error.schema.json', '$.error.details.fields'
    assert_invalid below_minimum, 'specialist_error.schema.json', '$.error.details.retry_after_seconds'
    assert_invalid above_maximum, 'specialist_response.schema.json', '$.confidence'
  end

  test 'rejects an unknown referenced file fail closed' do
    schema = base_schema.merge('$ref' => 'missing.schema.json')

    assert_temporary_schema_rejected(schema)
  end

  test 'rejects an unknown referenced fragment fail closed' do
    schema = base_schema.merge(
      '$ref' => '#/$defs/missing',
      '$defs' => { 'known' => { 'type' => 'object' } }
    )

    assert_temporary_schema_rejected(schema)
  end

  test 'rejects malformed schema JSON fail closed' do
    assert_temporary_schema_rejected('{"$schema":', json: false)
  end

  test 'rejects a schema declaring a different draft fail closed' do
    schema = base_schema.merge('$schema' => 'http://json-schema.org/draft-07/schema#')

    assert_temporary_schema_rejected(schema)
  end

  test 'rejects an unsupported schema keyword fail closed' do
    schema = base_schema.merge('type' => 'string', 'pattern' => '\\Aallowed\\z')

    assert_temporary_schema_rejected(schema)
  end

  test 'rechecks schema preflight after an earlier failure on the same validator' do
    Dir.mktmpdir('schema-validator-cache-test') do |directory|
      schema = base_schema.merge('unsupported_keyword' => true)
      File.binwrite(File.join(directory, 'root.schema.json'), JSON.generate(schema))
      temporary_validator = Validator.new(schema_directory: directory)

      2.times do
        error = assert_raises(Validator::ValidationError) do
          temporary_validator.validate!({}, schema_name: 'root.schema.json')
        end
        assert_equal 'root.schema.json', error.schema_name
        assert_equal '$', error.path
      end
    end
  end

  test 'validation errors retain only a safe schema name and path' do
    secret_value = SECRET_INPUTS.join(' | ')
    payload = valid_request.merge('specialist' => secret_value)

    error = assert_invalid(payload, 'specialist_request.schema.json', '$.specialist')

    assert_equal %i[@path @schema_name], error.instance_variables.sort_by(&:to_s)
    assert_equal 'Schema validation failed for specialist_request.schema.json at $.specialist', error.message
    SECRET_INPUTS.each do |secret|
      refute_includes error.message, secret
      refute_includes error.inspect, secret
    end
  end

  test 'validation errors sanitize unsafe schema names and paths' do
    error = Validator::ValidationError.new(
      schema_name: "../unsafe schema\nname.json",
      path: '$.items[secret-token]'
    )

    assert_equal 'unknown.schema.json', error.schema_name
    assert_equal '$', error.path
    assert_equal 'Schema validation failed for unknown.schema.json at $', error.message
  end

  private

  def validator
    @validator ||= Validator.new
  end

  def assert_invalid(payload, schema_name, expected_path)
    error = assert_raises(Validator::ValidationError) do
      validator.validate!(payload, schema_name: schema_name)
    end
    assert_equal schema_name, error.schema_name
    assert_equal expected_path, error.path
    error
  end

  def assert_temporary_schema_rejected(contents, json: true)
    Dir.mktmpdir('schema-validator-test') do |directory|
      serialized = json ? JSON.generate(contents) : contents
      File.binwrite(File.join(directory, 'root.schema.json'), serialized)
      temporary_validator = Validator.new(schema_directory: directory)

      error = assert_raises(Validator::ValidationError) do
        temporary_validator.validate!({}, schema_name: 'root.schema.json')
      end
      assert_equal 'root.schema.json', error.schema_name
      assert_equal '$', error.path
    end
  end

  def base_schema
    {
      '$schema' => DRAFT_2020_12,
      'type' => 'object'
    }
  end

  def valid_request
    {
      'version' => '2.1',
      'request_id' => 'request-d001r2a',
      'call_id' => 'call-d001r2a',
      'trace_id' => 'trace-d001r2a',
      'specialist' => 'chrono_flow_ai',
      'mode' => 'read',
      'capability' => 'schedule_context',
      'user_message' => '今日と明日の予定を確認して',
      'locale' => 'ja-JP',
      'time_zone' => 'Asia/Tokyo',
      'context_refs' => [{ 'kind' => 'calendar' }],
      'constraints' => { 'range' => 'today_and_tomorrow' }
    }
  end

  def valid_response
    {
      'version' => '2.1',
      'response_id' => 'response-d001r2a',
      'request_id' => 'request-d001r2a',
      'call_id' => 'call-d001r2a',
      'trace_id' => 'trace-d001r2a',
      'specialist' => 'chrono_flow_ai',
      'status' => 'completed',
      'summary' => '予定を確認しました。',
      'facts' => [
        {
          'id' => 'chrono_flow_event_42',
          'fact_type' => 'schedule_snapshot',
          'fields' => { 'all_day' => false },
          'source_updated_at' => '2026-05-18T12:00:00+09:00'
        }
      ],
      'proposals' => [valid_action_proposal],
      'clarification' => {
        'question' => '何時の予定を確認しますか？',
        'missing_fields' => ['time_range']
      },
      'warnings' => ['read_only_context'],
      'confidence' => 0.95,
      'generated_at' => '2026-05-18T12:00:00+09:00',
      'stale_at' => nil
    }
  end

  def valid_error
    {
      'version' => '2.1',
      'error' => {
        'code' => 'invalid_request_schema',
        'message' => 'The request does not match the required schema.',
        'details' => {
          'fields' => %w[user_message locale],
          'required_scope' => 'schedule.read',
          'schema' => 'specialist_request.schema.json',
          'retry_after_seconds' => 60
        }
      },
      'request_id' => 'request-d001r2a',
      'trace_id' => 'trace-d001r2a',
      'retryable' => false
    }
  end

  def valid_action_proposal
    {
      'version' => '2.1',
      'proposal_id' => 'proposal-d001r2a',
      'owner_specialist' => 'chrono_flow_ai',
      'action_type' => 'calendar.event.create',
      'label' => '予定を作成',
      'summary' => '確認後に予定を作成します。',
      'arguments' => { 'starts_at' => '2026-05-19T10:00:00+09:00' },
      'effects_preview' => { 'calendar_events_created' => 1 },
      'requires_confirmation' => true,
      'risk_level' => 'medium',
      'proposal_token' => 'opaque-proposal-token',
      'expires_at' => '2026-05-18T12:15:00+09:00'
    }
  end
end
