# frozen_string_literal: true

require "securerandom"
require "time"

module ChronoFlowSpecialist
  class ResponseBuilder
    MAX_RESPONSE_BYTES = 524_288
    SCHEDULE_FIELD_KEYS = %w[all_day end_at location start_at title].freeze
    CONNECTION_FIELD_KEYS = %w[connected operation].freeze

    def initialize(contracts:, fact_id:)
      @response_schema = contracts.validator(:response)
      @error_schema = contracts.validator(:error)
      @fact_id = fact_id
    end

    def success(request:, facts:, now:)
      response = {
        "version" => "2.1",
        "response_id" => SecureRandom.uuid,
        "request_id" => request.fetch("request_id"),
        "call_id" => request.fetch("call_id"),
        "trace_id" => request.fetch("trace_id"),
        "specialist" => "chrono_flow_ai",
        "status" => "completed",
        "summary" => nil,
        "facts" => facts,
        "proposals" => [],
        "clarification" => nil,
        "warnings" => [],
        "confidence" => 1.0,
        "generated_at" => numeric_utc(now),
        "stale_at" => numeric_utc(now + 60)
      }
      validate_success_policy!(request, response)
      raise Errors::Error.new(:invalid_response_schema) unless @response_schema.valid?(response)
      if ActiveSupport::JSON.encode(response).bytesize > MAX_RESPONSE_BYTES
        raise Errors::Error.new(:invalid_response_schema)
      end

      response
    end

    def connection_fact(user:, operation:)
      {
        "id" => @fact_id.for(user, kind: "connection_verification"),
        "fact_type" => "connection_verification",
        "fields" => { "operation" => operation, "connected" => true },
        "source_updated_at" => numeric_utc(user.updated_at)
      }
    end

    def error(code:, request_id:, trace_id:)
      definition = Errors::Error::DEFINITIONS.fetch(code.to_sym)
      body = {
        "version" => "2.1",
        "error" => { "code" => code.to_s, "message" => definition[1] },
        "request_id" => safe_correlation_id(request_id),
        "trace_id" => safe_correlation_id(trace_id),
        "retryable" => definition[2]
      }
      raise Errors::Error.new(:internal_error) unless @error_schema.valid?(body)

      body
    end

    private

    def validate_success_policy!(request, response)
      raise Errors::Error.new(:invalid_response_schema) unless response["proposals"] == []
      raise Errors::Error.new(:invalid_response_schema) unless response["request_id"] == request["request_id"]
      raise Errors::Error.new(:invalid_response_schema) unless response["trace_id"] == request["trace_id"]
      raise Errors::Error.new(:invalid_response_schema) unless response["call_id"] == request["call_id"]

      expected_type = request["capability"] == "schedule_context" ? "schedule_event" : "connection_verification"
      expected_fields = expected_type == "schedule_event" ? SCHEDULE_FIELD_KEYS : CONNECTION_FIELD_KEYS
      facts = response["facts"]
      raise Errors::Error.new(:invalid_response_schema) unless facts.is_a?(Array)
      if expected_type == "connection_verification"
        raise Errors::Error.new(:invalid_response_schema) unless facts.length == 1
      end

      facts.each do |fact|
        valid = fact.is_a?(Hash) && fact["fact_type"] == expected_type &&
                fact["fields"].is_a?(Hash) && fact["fields"].keys.sort == expected_fields &&
                fact["source_updated_at"].is_a?(String)
        raise Errors::Error.new(:invalid_response_schema) unless valid
      end
    end

    def safe_correlation_id(value)
      candidate = value.to_s
      candidate.match?(/\A\S.{0,127}\z/m) ? candidate : SecureRandom.uuid
    end

    def numeric_utc(value)
      value.to_time.getlocal("+00:00").iso8601(0)
    end
  end
end
