# frozen_string_literal: true

module Api
  module Specialists
    class ChronoFlowController < BaseController
      REQUEST_SCHEMA = 'specialist_request.schema.json'
      RESPONSE_SCHEMA = 'specialist_response.schema.json'
      ENDPOINT_POLICY = {
        'specialist' => 'chrono_flow_ai',
        'mode' => 'read',
        'capability' => 'schedule_context'
      }.freeze

      class InvalidRequestSchemaError < StandardError; end
      class InvalidResponseSchemaError < StandardError; end

      class UnsupportedCapabilityError < StandardError
        attr_reader :fields

        def initialize(fields)
          @fields = fields.freeze
          super('Specialist endpoint policy does not match')
        end
      end

      rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_malformed_json

      def context
        @specialist_request_payload = JSON.parse(request.raw_post)
        validate_request_schema!(@specialist_request_payload)
        validate_endpoint_policy!(@specialist_request_payload)

        specialist_response = ::Specialists::ChronoFlow::ReadScheduleContext.call(
          user: current_user,
          payload: @specialist_request_payload
        )
        validate_response_schema!(specialist_response)

        response.set_header('Cache-Control', 'no-store')
        render json: specialist_response, status: 200
      rescue JSON::ParserError
        render_specialist_error('malformed_json', request_payload: nil)
      rescue InvalidRequestSchemaError
        render_specialist_error(
          'invalid_request_schema',
          details: { schema: REQUEST_SCHEMA }
        )
      rescue UnsupportedCapabilityError => e
        render_specialist_error('unsupported_capability', details: { fields: e.fields })
      rescue InvalidResponseSchemaError
        render_specialist_error(
          'invalid_response_schema',
          details: { schema: RESPONSE_SCHEMA }
        )
      rescue ::Specialists::ChronoFlow::ReadScheduleContext::ValidationError => e
        render_read_context_validation_error(e)
      rescue StandardError
        render_specialist_error('internal_error')
      end

      private

      def require_login!
        return if current_user.present?

        render_specialist_error('invalid_token', request_payload: parsed_payload_for_correlation)
      end

      def validate_request_schema!(payload)
        ::Specialists::Contracts::SchemaValidator.validate!(payload, schema_name: REQUEST_SCHEMA)
      rescue ::Specialists::Contracts::SchemaValidator::ValidationError
        raise InvalidRequestSchemaError, 'Request schema validation failed'
      end

      def validate_response_schema!(payload)
        ::Specialists::Contracts::SchemaValidator.validate!(payload, schema_name: RESPONSE_SCHEMA)
      rescue ::Specialists::Contracts::SchemaValidator::ValidationError
        raise InvalidResponseSchemaError, 'Response schema validation failed'
      end

      def validate_endpoint_policy!(payload)
        mismatched_fields = ENDPOINT_POLICY.filter_map do |field, expected|
          field unless payload[field] == expected
        end
        raise UnsupportedCapabilityError, mismatched_fields if mismatched_fields.any?
      end

      def render_read_context_validation_error(error)
        code = error.field.to_s == 'capability' ? 'unsupported_capability' : 'invalid_request_schema'
        render_specialist_error(code, details: { fields: [error.field] })
      end

      def render_malformed_json
        render_specialist_error('malformed_json', request_payload: nil)
      end

      def render_specialist_error(code, request_payload: @specialist_request_payload, details: {})
        result = ::Specialists::Contracts::ErrorResponse.call(
          code: code,
          request_payload: request_payload,
          headers: request.headers,
          details: details
        )
        result.headers.each { |name, value| response.set_header(name, value) }
        render json: result.body, status: result.status
      end

      def parsed_payload_for_correlation
        payload = JSON.parse(request.raw_post)
        payload if payload.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
