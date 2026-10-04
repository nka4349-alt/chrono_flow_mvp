# frozen_string_literal: true

require "securerandom"
require "time"

module ChronoFlowSpecialist
  class ResponseBuilder
    MAX_RESPONSE_BYTES = 524_288
    SCHEDULE_FIELD_KEYS = %w[all_day end_at location start_at title].freeze
    CONNECTION_FIELD_KEYS = %w[connected operation].freeze
    REFRESH_EVENT_FIELD_KEYS = (SCHEDULE_FIELD_KEYS + ['day_relation']).sort.freeze
    SUMMARY_FIELD_KEYS = %w[partial returned_count target_date time_zone today_count total_count].freeze
    REFRESH_WARNINGS = %w[schedule_context_event_omitted schedule_context_truncated].freeze

    def initialize(contracts:, fact_id:)
      @response_schema = contracts.validator(:response)
      @error_schema = contracts.validator(:error)
      @fact_id = fact_id
    end

    def success(request:, facts:, now:)
      warnings = facts.respond_to?(:warnings) ? facts.warnings : []
      response = {
        "version" => "2.1",
        "response_id" => SecureRandom.uuid,
        "request_id" => request.fetch("request_id"),
        "call_id" => request.fetch("call_id"),
        "trace_id" => request.fetch("trace_id"),
        "specialist" => "chrono_flow_ai",
        "status" => warnings.empty? ? 'completed' : 'partial',
        "summary" => nil,
        "facts" => facts,
        "proposals" => [],
        "clarification" => nil,
        "warnings" => warnings,
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
      refresh = request.dig('constraints', 'refresh_scope').present?
      facts = response["facts"]
      raise Errors::Error.new(:invalid_response_schema) unless facts.is_a?(Array) && facts.all? { |fact| fact.is_a?(Hash) }
      if expected_type == "connection_verification"
        raise Errors::Error.new(:invalid_response_schema) unless facts.length == 1
      end
      if refresh
        summaries = facts.select { |fact| fact['fact_type'] == 'schedule_summary' }
        raise Errors::Error.new(:invalid_response_schema) unless summaries.one?
        validate_refresh_cardinality!(response, summaries.first)
      end

      facts.each do |fact|
        if refresh && fact['fact_type'] == 'schedule_summary'
          validate_summary!(fact, request)
          next
        end
        expected_fields = REFRESH_EVENT_FIELD_KEYS if refresh
        valid = fact.is_a?(Hash) && fact["fact_type"] == expected_type &&
                fact["fields"].is_a?(Hash) && fact["fields"].keys.sort == expected_fields &&
                fact["source_updated_at"].is_a?(String)
        raise Errors::Error.new(:invalid_response_schema) unless valid
        if refresh && !%w[target_day outside_target_day].include?(fact.dig('fields', 'day_relation'))
          raise Errors::Error.new(:invalid_response_schema)
        end
      end
    end

    def validate_summary!(fact, request)
      fields = fact['fields']
      valid = fields.is_a?(Hash) && fields.keys.sort == SUMMARY_FIELD_KEYS &&
        fields['time_zone'] == request['time_zone'] &&
        fields['target_date'].is_a?(String) && fields['target_date'].match?(/\A\d{4}-\d{2}-\d{2}\z/) &&
        %w[total_count today_count returned_count].all? { |key| fields[key].is_a?(Integer) && fields[key] >= 0 } &&
        [true, false].include?(fields['partial']) &&
        fields['today_count'] <= fields['total_count'] && fields['returned_count'] <= ScheduleReader::MAX_EVENTS &&
        fact['source_updated_at'].is_a?(String)
      raise Errors::Error.new(:invalid_response_schema) unless valid
    end

    def validate_refresh_cardinality!(response, summary)
      fields = summary['fields']
      raise Errors::Error.new(:invalid_response_schema) unless fields.is_a?(Hash)
      events = response['facts'].select { |fact| fact['fact_type'] == 'schedule_event' }
      warnings = response['warnings']
      valid = warnings.is_a?(Array) && warnings.uniq == warnings && (warnings - REFRESH_WARNINGS).empty? &&
        fields['partial'] == warnings.any? &&
        response['status'] == (warnings.any? ? 'partial' : 'completed') &&
        events.length <= ScheduleReader::MAX_EVENTS &&
        response['facts'].map { |fact| fact['id'] }.uniq.length == response['facts'].length &&
        fields['returned_count'] == events.length &&
        fields['total_count'].is_a?(Integer) && fields['total_count'] >= events.length &&
        fields['today_count'].is_a?(Integer) &&
        fields['today_count'] >= events.count { |fact| fact.dig('fields', 'day_relation') == 'target_day' }
      raise Errors::Error.new(:invalid_response_schema) unless valid
      truncated = fields['total_count'] > ScheduleReader::MAX_EVENTS
      omitted = events.length < [fields['total_count'], ScheduleReader::MAX_EVENTS].min
      valid = warnings.include?('schedule_context_truncated') == truncated &&
        warnings.include?('schedule_context_event_omitted') == omitted
      if warnings.empty?
        valid &&= fields['total_count'] == events.length &&
          fields['today_count'] == events.count { |fact| fact.dig('fields', 'day_relation') == 'target_day' }
      end
      raise Errors::Error.new(:invalid_response_schema) unless valid
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
