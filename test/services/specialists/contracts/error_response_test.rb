# frozen_string_literal: true

require 'test_helper'
require 'json'

class SpecialistsContractsErrorResponseTest < ActiveSupport::TestCase
  ERROR_CASES = {
    'malformed_json' => [400, 'Request body is not valid JSON.'],
    'invalid_token' => [401, 'Authentication is required.'],
    'invalid_request_schema' => [422, 'Request does not match the required schema.'],
    'unsupported_capability' => [422, 'The requested capability is not supported.'],
    'invalid_response_schema' => [500, 'Specialist response validation failed.'],
    'internal_error' => [500, 'An internal error occurred.']
  }.freeze

  CORRELATION_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/

  test 'maps direct boundary errors to fixed schema-valid non-retryable envelopes' do
    ERROR_CASES.each do |code, (expected_status, expected_message)|
      result = build_error(code: code)

      assert_equal expected_status, result.status, code
      assert_equal '2.1', result.body.fetch('version'), code
      assert_equal code, result.body.dig('error', 'code'), code
      assert_equal expected_message, result.body.dig('error', 'message'), code
      assert_equal({}, result.body.dig('error', 'details'), code)
      assert_equal false, result.body.fetch('retryable'), code
      assert_equal 'no-store', result.headers.fetch('Cache-Control'), code

      if expected_status == 401
        assert_equal 'Bearer', result.headers.fetch('WWW-Authenticate'), code
      else
        refute result.headers.key?('WWW-Authenticate'), code
      end

      assert Specialists::Contracts::SchemaValidator.validate!(
        result.body,
        schema_name: 'specialist_error.schema.json'
      ), code
    end
  end

  test 'self-validates the exact envelope before returning it' do
    invalid_response_class = Class.new(Specialists::Contracts::ErrorResponse) do
      private

      def build_body
        super.merge('unexpected' => 'not allowed by the error schema')
      end
    end

    assert_raises(Specialists::Contracts::SchemaValidator::ValidationError) do
      invalid_response_class.call(
        code: 'internal_error',
        request_payload: { request_id: 'request_test_1', trace_id: 'trace_test_1' }
      )
    end
  end

  test 'prefers safe body correlation ids over safe header values' do
    request_id = 'r' * 128
    result = build_error(
      request_payload: { request_id: request_id, 'trace_id' => 'body_trace-1' },
      headers: {
        'X-Request-Id' => 'header_request-1',
        'X-Trace-Id' => 'header_trace-1'
      }
    )

    assert_equal request_id, result.body.fetch('request_id')
    assert_equal 'body_trace-1', result.body.fetch('trace_id')
  end

  test 'uses safe headers when body correlation ids fail the allowlist or length limit' do
    result = build_error(
      request_payload: {
        'request_id' => 'request id contains spaces',
        'trace_id' => 't' * 129
      },
      headers: {
        'X-Request-Id' => 'header_request-1',
        'HTTP_X_TRACE_ID' => 'header_trace_1'
      }
    )

    assert_equal 'header_request-1', result.body.fetch('request_id')
    assert_equal 'header_trace_1', result.body.fetch('trace_id')
  end

  test 'generates safe correlation ids when body and header values are unavailable or unsafe' do
    result = build_error(
      request_payload: { request_id: '-unsafe', trace_id: 42 },
      headers: {
        'X-Request-Id' => 'Bearer raw.token.value',
        'X-Trace-Id' => 'trace@example.test'
      }
    )

    assert result.body.fetch('request_id').start_with?('request_')
    assert result.body.fetch('trace_id').start_with?('trace_')

    %w[request_id trace_id].each do |key|
      correlation_id = result.body.fetch(key)
      assert_match CORRELATION_ID_PATTERN, correlation_id
      assert_operator correlation_id.length, :<=, 128
    end
  end

  test 'emits only allowlisted details with schema-safe values' do
    safe_fields = %w[
      version request_id call_id trace_id specialist mode capability locale
      time_zone context_refs constraints
    ]
    required_scope = 'specialist:chrono_flow:read'
    result = build_error(
      code: 'invalid_request_schema',
      details: {
        fields: safe_fields + ['email', 'user_message', 'version', 123],
        required_scope: required_scope,
        schema: 'specialist_request.schema.json',
        retry_after_seconds: 3600,
        authorization: 'Bearer detail-token',
        exception: 'private exception message'
      }
    )

    assert_equal(
      {
        'fields' => safe_fields,
        'required_scope' => required_scope,
        'schema' => 'specialist_request.schema.json',
        'retry_after_seconds' => 3600
      },
      result.body.dig('error', 'details')
    )
    assert_operator result.body.dig('error', 'details', 'required_scope').length, :<=, 128
    assert Specialists::Contracts::SchemaValidator.validate!(
      result.body,
      schema_name: 'specialist_error.schema.json'
    )
  end

  test 'drops detail values outside their allowlists and bounds' do
    invalid_details = [
      { fields: 'version' },
      { fields: %w[email user_message authorization] },
      { required_scope: 'Scope With Spaces' },
      { required_scope: 's' * 129 },
      { schema: 'action_proposal.schema.json' },
      { retry_after_seconds: -1 },
      { retry_after_seconds: 3601 },
      { retry_after_seconds: '60' }
    ]

    invalid_details.each do |details|
      result = build_error(code: 'invalid_request_schema', details: details)

      assert_equal({}, result.body.dig('error', 'details'), details.inspect)
    end
  end

  test 'does not expose sensitive request header or diagnostic material' do
    sensitive_markers = {
      raw_token: 'Bearer eyJhbGciOiJSUzI1NiJ9.raw-token.signature',
      identity_subject: 'IDENTITY_SUBJECT_PRIVATE_219',
      identity_issuer: 'IDENTITY_ISSUER_PRIVATE_219',
      email: 'private-person-219@example.test',
      user_id: 'USER_ID_PRIVATE_219',
      user_message: 'USER_MESSAGE_PRIVATE_219',
      title: 'SCHEDULE_TITLE_PRIVATE_219',
      location: 'LOCATION_PRIVATE_219',
      facts: 'FACTS_BODY_PRIVATE_219',
      exception: 'EXCEPTION_MESSAGE_PRIVATE_219',
      stack_trace: 'STACK_TRACE_PRIVATE_219',
      sql: 'SQL_PRIVATE_219',
      provider_body: 'PROVIDER_RESPONSE_BODY_PRIVATE_219'
    }
    result = build_error(
      code: 'internal_error',
      request_payload: {
        request_id: 'safe_request_219',
        trace_id: 'safe_trace_219',
        sub: sensitive_markers.fetch(:identity_subject),
        identity_issuer: sensitive_markers.fetch(:identity_issuer),
        identity_subject: sensitive_markers.fetch(:identity_subject),
        email: sensitive_markers.fetch(:email),
        user_id: sensitive_markers.fetch(:user_id),
        user_message: sensitive_markers.fetch(:user_message),
        title: sensitive_markers.fetch(:title),
        location: sensitive_markers.fetch(:location),
        facts: sensitive_markers.fetch(:facts)
      },
      headers: {
        'Authorization' => sensitive_markers.fetch(:raw_token),
        'X-Identity-Subject' => sensitive_markers.fetch(:identity_subject),
        'X-User-Email' => sensitive_markers.fetch(:email)
      },
      details: {
        exception_message: sensitive_markers.fetch(:exception),
        stack_trace: sensitive_markers.fetch(:stack_trace),
        sql: sensitive_markers.fetch(:sql),
        provider_response_body: sensitive_markers.fetch(:provider_body)
      }
    )

    serialized_body = JSON.generate(result.body)
    sensitive_markers.each_value do |marker|
      refute_includes serialized_body, marker
    end
    assert_equal 'An internal error occurred.', result.body.dig('error', 'message')
    assert_equal({}, result.body.dig('error', 'details'))
  end

  private

  def build_error(code: 'malformed_json', request_payload: nil, headers: {}, details: {})
    Specialists::Contracts::ErrorResponse.call(
      code: code,
      request_payload: request_payload || {
        request_id: 'request_test_1',
        trace_id: 'trace_test_1'
      },
      headers: headers,
      details: details
    )
  end
end
