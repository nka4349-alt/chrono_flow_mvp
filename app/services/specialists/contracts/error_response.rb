# frozen_string_literal: true

require 'securerandom'

module Specialists
  module Contracts
    class ErrorResponse
      ERROR_SCHEMA = 'specialist_error.schema.json'
      SAFE_CORRELATION_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/
      SAFE_DETAIL_FIELDS = %w[
        version request_id call_id trace_id specialist mode capability locale
        time_zone context_refs constraints
      ].freeze
      SAFE_REQUIRED_SCOPES = %w[
        specialist:chrono_flow:read
        specialist:chrono_task:read
      ].freeze
      SAFE_SCHEMAS = %w[
        specialist_request.schema.json
        specialist_response.schema.json
        specialist_error.schema.json
      ].freeze

      HTTP_STATUS = {
        'malformed_json' => 400,
        'invalid_token' => 401,
        'expired_token' => 401,
        'replayed_token' => 401,
        'insufficient_scope' => 403,
        'inactive_user' => 403,
        'inactive_membership' => 403,
        'unsupported_media_type' => 415,
        'invalid_request_schema' => 422,
        'unsupported_capability' => 422,
        'invalid_response_schema' => 500,
        'internal_error' => 500,
        'service_unavailable' => 503
      }.freeze

      MESSAGES = {
        'malformed_json' => 'Request body is not valid JSON.',
        'invalid_token' => 'Authentication is required.',
        'expired_token' => 'Authentication has expired.',
        'replayed_token' => 'Authentication could not be accepted.',
        'insufficient_scope' => 'Permission is insufficient.',
        'inactive_user' => 'The user account is inactive.',
        'inactive_membership' => 'The membership is inactive.',
        'unsupported_media_type' => 'The request media type is not supported.',
        'invalid_request_schema' => 'Request does not match the required schema.',
        'unsupported_capability' => 'The requested capability is not supported.',
        'invalid_response_schema' => 'Specialist response validation failed.',
        'internal_error' => 'An internal error occurred.',
        'service_unavailable' => 'The service is temporarily unavailable.'
      }.freeze

      Result = Struct.new(:body, :status, :headers, keyword_init: true)

      def self.call(...)
        new(...).call
      end

      def initialize(code:, request_payload: nil, headers: {}, details: {})
        @code = code.to_s
        @request_payload = request_payload
        @headers = headers
        @details = details
      end

      def call
        status = HTTP_STATUS.fetch(code)
        body = build_body
        SchemaValidator.validate!(body, schema_name: ERROR_SCHEMA)

        response_headers = { 'Cache-Control' => 'no-store' }
        response_headers['WWW-Authenticate'] = 'Bearer' if status == 401
        Result.new(body: body, status: status, headers: response_headers.freeze)
      end

      private

      attr_reader :code, :request_payload, :headers, :details

      def build_body
        {
          'version' => '2.1',
          'error' => {
            'code' => code,
            'message' => MESSAGES.fetch(code),
            'details' => safe_details
          },
          'request_id' => correlation_id('request_id', 'X-Request-Id', 'request'),
          'trace_id' => correlation_id('trace_id', 'X-Trace-Id', 'trace'),
          'retryable' => code == 'service_unavailable'
        }
      end

      def correlation_id(body_key, header_key, generated_prefix)
        safe_correlation_id(payload_value(body_key)) ||
          safe_correlation_id(header_value(header_key)) ||
          "#{generated_prefix}_#{SecureRandom.uuid}"
      end

      def payload_value(key)
        return unless request_payload.is_a?(Hash)

        request_payload.key?(key) ? request_payload[key] : request_payload[key.to_sym]
      end

      def header_value(key)
        return unless headers.respond_to?(:[])

        headers[key] || headers["HTTP_#{key.upcase.tr('-', '_')}"]
      end

      def safe_correlation_id(value)
        return unless value.is_a?(String) && value.match?(SAFE_CORRELATION_PATTERN)

        value
      end

      def safe_details
        input = details.is_a?(Hash) ? details : {}
        output = {}

        fields = detail_value(input, 'fields')
        if fields.is_a?(Array)
          safe_fields = fields.select { |field| SAFE_DETAIL_FIELDS.include?(field.to_s) }.map(&:to_s).uniq.first(32)
          output['fields'] = safe_fields if safe_fields.any?
        end

        required_scope = detail_value(input, 'required_scope')
        output['required_scope'] = required_scope if SAFE_REQUIRED_SCOPES.include?(required_scope)

        schema = detail_value(input, 'schema')
        output['schema'] = schema if SAFE_SCHEMAS.include?(schema)

        retry_after_seconds = detail_value(input, 'retry_after_seconds')
        if retry_after_seconds.is_a?(Integer) && retry_after_seconds.between?(0, 3600)
          output['retry_after_seconds'] = retry_after_seconds
        end

        output
      end

      def detail_value(input, key)
        input.key?(key) ? input[key] : input[key.to_sym]
      end
    end
  end
end
