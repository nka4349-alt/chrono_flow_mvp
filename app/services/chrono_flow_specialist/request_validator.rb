# frozen_string_literal: true

require "date"
require "tzinfo"

module ChronoFlowSpecialist
  class RequestValidator
    MAX_REQUEST_BYTES = 65_536
    REQUIRED_HEADER_NAMES = %w[Authorization Content-Type Accept X-Request-Id X-Trace-Id].freeze
    CAPABILITIES = %w[schedule_context connection_verification].freeze
    OPERATIONS = %w[resolve_user verify_connection].freeze

    def initialize(contracts:, clock: -> { Time.now })
      @request_schema = contracts.validator(:request)
      @clock = clock
    end

    def validate(raw_body:, headers:, now: @clock.call)
      validate_media!(headers)
      validate_authorization!(headers)
      validate_required_correlation_headers!(headers)
      raise Errors::Error.new(:invalid_request_schema) if raw_body.to_s.bytesize > MAX_REQUEST_BYTES

      request = StrictJson.parse(raw_body)
      raise Errors::Error.new(:invalid_request_schema) unless request.is_a?(Hash)
      raise Errors::Error.new(:invalid_request_schema) unless @request_schema.valid?(request)

      validate_common_policy!(request, headers)
      validate_capability_policy!(request, now)
      request
    rescue StrictJson::ParseError
      raise Errors::Error.new(:malformed_json)
    end

    private

    def validate_media!(headers)
      content_type = header(headers, "Content-Type").to_s.split(";", 2).first
      accept = header(headers, "Accept").to_s
      encoding = header(headers, "Accept-Encoding")
      valid_encoding = encoding.nil? || encoding.to_s.empty? || encoding == "identity"
      valid = content_type == "application/json" && accept == "application/json" && valid_encoding
      raise Errors::Error.new(:unsupported_media_type) unless valid
    end

    def validate_authorization!(headers)
      value = header(headers, "Authorization")
      valid = value.is_a?(String) && value.match?(/\ABearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/)
      raise Errors::Error.new(:invalid_token) unless valid
    end

    def validate_required_correlation_headers!(headers)
      required = %w[X-Request-Id X-Trace-Id]
      raise Errors::Error.new(:invalid_request_schema) unless required.all? { |name| nonblank?(header(headers, name)) }
    end

    def validate_common_policy!(request, headers)
      raise Errors::Error.new(:invalid_request_schema) unless request["specialist"] == "chrono_flow_ai"
      raise Errors::Error.new(:invalid_request_schema) unless request["mode"] == "read"
      raise Errors::Error.new(:invalid_request_schema) unless request["context_refs"] == []
      raise Errors::Error.new(:invalid_request_schema) unless exact_iana_zone?(request["time_zone"])
      raise Errors::Error.new(:invalid_request_schema) unless header(headers, "X-Request-Id") == request["request_id"]
      raise Errors::Error.new(:invalid_request_schema) unless header(headers, "X-Trace-Id") == request["trace_id"]
    end

    def validate_capability_policy!(request, now)
      capability = request["capability"]
      raise Errors::Error.new(:unsupported_capability) unless CAPABILITIES.include?(capability)

      constraints = request["constraints"]
      case capability
      when "schedule_context"
        validate_schedule_constraints!(constraints, request["time_zone"], now)
      when "connection_verification"
        valid = constraints.is_a?(Hash) && constraints.keys == ["operation"] && OPERATIONS.include?(constraints["operation"])
        raise Errors::Error.new(:invalid_request_schema) unless valid
      end
    end

    def validate_schedule_constraints!(constraints, zone_name, now)
      return if constraints == {}

      valid_shape = constraints.is_a?(Hash) && constraints.keys == ["date_window"] &&
                    constraints["date_window"].is_a?(Hash) &&
                    constraints["date_window"].keys.sort == %w[end start]
      raise Errors::Error.new(:invalid_request_schema) unless valid_shape

      zone = Time.find_zone!(zone_name)
      start_date = now.in_time_zone(zone).to_date
      expected = { "start" => start_date.iso8601, "end" => (start_date + 14).iso8601 }
      raise Errors::Error.new(:invalid_request_schema) unless constraints["date_window"] == expected
    end

    def exact_iana_zone?(value)
      return false unless value.is_a?(String)

      TZInfo::Timezone.get(value)
      true
    rescue TZInfo::InvalidTimezoneIdentifier
      false
    end

    def nonblank?(value)
      value.is_a?(String) && value.match?(/\S/)
    end

    def header(headers, name)
      headers[name] || headers[name.downcase] || headers[name.upcase.tr("-", "_")] || headers["HTTP_#{name.upcase.tr('-', '_')}"]
    end
  end
end
