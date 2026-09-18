# frozen_string_literal: true

require "date"
require "time"
require "json"
require "digest"

module SecretaryCreation
  # Shared verbatim by the three applications. Deliberately independent of Rails.
  module Contract
    class Invalid < ArgumentError
      def initialize
        super("creation contract is invalid")
      end
    end

    VERSION = "1.0"
    PROVIDERS = %w[chrono_flow chrono_task].freeze
    STATUSES = %w[needs_clarification ready rejected completed cancelled expired].freeze
    ERROR_CODES = %w[invalid_request unauthenticated forbidden not_found proposal_changed
      already_completed idempotency_conflict expired unsupported unavailable outcome_unknown].freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    SHA256 = /\A[0-9a-f]{64}\z/
    REQUEST_KEYS = {
      "propose" => %w[version request_id trace_id message locale time_zone proposal_id expected_revision],
      "confirm" => %w[version request_id trace_id proposal_id revision content_digest idempotency_key],
      "cancel" => %w[version request_id trace_id proposal_id revision]
    }.freeze
    RESPONSE_KEYS = %w[version request_id trace_id provider proposal_id revision status expires_at
      content_digest question details result_id completed_at].freeze
    EVENT_KEYS = %w[kind title description location start_at end_at all_day time_zone].freeze
    TASK_KEYS = %w[kind title description due_date due_time time_zone].freeze

    module_function

    def validate_request!(operation, payload)
      operation = operation.to_s
      keys = REQUEST_KEYS[operation]
      invalid! unless keys
      exact!(payload, keys)
      common!(payload)
      case operation
      when "propose"
        text!(payload["message"], maximum: 4_000, nonblank: true)
        invalid! unless payload["locale"] == "ja-JP" && payload["time_zone"] == "Asia/Tokyo"
        if payload["proposal_id"].nil?
          invalid! unless payload["expected_revision"].nil?
        else
          uuid!(payload["proposal_id"])
          revision!(payload["expected_revision"])
        end
      when "confirm", "cancel"
        uuid!(payload["proposal_id"])
        revision!(payload["revision"])
        if operation == "confirm"
          hash!(payload["content_digest"])
          uuid!(payload["idempotency_key"])
        end
      end
      payload
    end

    def validate_details!(details, provider: nil)
      invalid! unless details.instance_of?(Hash)
      kind = details["kind"]
      invalid! unless %w[event task].include?(kind)
      invalid! if provider && !PROVIDERS.include?(provider)
      invalid! if provider == "chrono_flow" && kind != "event"
      invalid! if provider == "chrono_task" && kind != "task"
      exact!(details, kind == "event" ? EVENT_KEYS : TASK_KEYS)
      text!(details["title"], maximum: 200, nonblank: true)
      text!(details["description"], maximum: 4_000)
      invalid! unless details["time_zone"] == "Asia/Tokyo"
      if kind == "event"
        text!(details["location"], maximum: 500)
        start_at = timestamp!(details["start_at"])
        end_at = timestamp!(details["end_at"])
        invalid! unless end_at > start_at
        invalid! unless [ true, false ].include?(details["all_day"])
        if details["all_day"]
          invalid! unless [ start_at, end_at ].all? do |time|
            local = time.getlocal("+09:00")
            local.hour.zero? && local.min.zero? && local.sec.zero? && local.subsec.zero?
          end
        end
      else
        date!(details["due_date"]) unless details["due_date"].nil?
        unless details["due_time"].nil?
          invalid! unless details["due_date"] && details["due_time"].instance_of?(String)
          invalid! unless /\A(?:[01]\d|2[0-3]):[0-5]\d\z/.match?(details["due_time"])
        end
      end
      details
    end

    def validate_response!(payload)
      exact!(payload, RESPONSE_KEYS)
      common!(payload)
      invalid! unless PROVIDERS.include?(payload["provider"])
      uuid!(payload["proposal_id"])
      revision!(payload["revision"])
      timestamp!(payload["expires_at"])
      invalid! unless STATUSES.include?(payload["status"])
      text!(payload["question"], maximum: 1_000, nonblank: true) unless payload["question"].nil?

      if payload["details"].nil?
        invalid! unless payload["content_digest"].nil?
      else
        validate_details!(payload["details"], provider: payload["provider"])
        hash!(payload["content_digest"])
        expected = digest(**%w[provider proposal_id revision expires_at details].to_h { |key| [ key.to_sym, payload[key] ] })
        invalid! unless payload["content_digest"] == expected
      end

      case payload["status"]
      when "ready", "completed"
        invalid! unless payload["details"] && payload["content_digest"] && payload["question"].nil?
      when "needs_clarification", "rejected"
        invalid! unless payload["question"] && payload["details"].nil? && payload["content_digest"].nil?
      end
      if payload["status"] == "completed"
        uuid!(payload["result_id"])
        timestamp!(payload["completed_at"])
      else
        invalid! unless payload["result_id"].nil? && payload["completed_at"].nil?
      end
      payload
    end

    def validate_error!(payload)
      exact!(payload, %w[version request_id trace_id error])
      invalid! unless payload["version"] == VERSION
      %w[request_id trace_id].each { |key| uuid!(payload[key]) unless payload[key].nil? }
      error = payload["error"]
      exact!(error, %w[code message retryable])
      invalid! unless ERROR_CODES.include?(error["code"])
      text!(error["message"], maximum: 1_000, nonblank: true)
      invalid! unless [ true, false ].include?(error["retryable"])
      payload
    end

    def digest(provider:, proposal_id:, revision:, expires_at:, details:)
      invalid! unless PROVIDERS.include?(provider)
      uuid!(proposal_id)
      revision!(revision)
      timestamp!(expires_at)
      validate_details!(details, provider: provider)
      Digest::SHA256.hexdigest(canonical_json({
        "provider" => provider, "proposal_id" => proposal_id,
        "revision" => revision, "expires_at" => expires_at, "details" => details
      }))
    end

    def canonical_json(value)
      JSON.generate(canonical_value(value, 0))
    rescue JSON::GeneratorError, EncodingError
      invalid!
    end

    def canonical_value(value, depth)
      invalid! if depth > 16
      case value
      when Hash
        invalid! unless value.instance_of?(Hash)
        value.keys.each { |key| text!(key, maximum: 200) }
        value.keys.sort.to_h { |key| [ key, canonical_value(value[key], depth + 1) ] }
      when Array
        invalid! unless value.instance_of?(Array)
        value.map { |item| canonical_value(item, depth + 1) }
      when String
        text!(value, maximum: 65_536)
        value
      when Integer, TrueClass, FalseClass, NilClass
        value
      else
        invalid!
      end
    end

    def common!(payload)
      invalid! unless payload["version"] == VERSION
      uuid!(payload["request_id"])
      uuid!(payload["trace_id"])
    end

    def exact!(value, keys)
      invalid! unless value.instance_of?(Hash) && value.keys.sort == keys.sort
    rescue ArgumentError
      invalid!
    end

    def text!(value, maximum:, nonblank: false)
      invalid! unless value.instance_of?(String) && [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding) && value.valid_encoding?
      invalid! if value.length > maximum || value.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
      invalid! if nonblank && !value.match?(/[^\p{Space}]/u)
      value
    end

    def uuid!(value)
      text!(value, maximum: 36, nonblank: true)
      invalid! unless UUID.match?(value)
      value
    end

    def hash!(value)
      text!(value, maximum: 64, nonblank: true)
      invalid! unless SHA256.match?(value)
      value
    end

    def revision!(value)
      invalid! unless value.instance_of?(Integer) && value.between?(1, 2_147_483_647)
      value
    end

    def date!(value)
      text!(value, maximum: 10)
      invalid! unless /\A\d{4}-\d{2}-\d{2}\z/.match?(value)
      Date.iso8601(value)
    rescue Date::Error
      invalid!
    end

    def timestamp!(value)
      text!(value, maximum: 40)
      match = /\A(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):([0-5]\d):([0-5]\d)(?:\.\d{1,6})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)\z/.match(value)
      invalid! unless match
      date!(match[1])
      Time.iso8601(value)
    rescue ArgumentError
      invalid!
    end

    def invalid!
      raise Invalid.new, cause: nil
    end
  end
end
