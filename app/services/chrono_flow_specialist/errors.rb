# frozen_string_literal: true

module ChronoFlowSpecialist
  module Errors
    class Error < StandardError
      DEFINITIONS = {
        malformed_json: [400, "Malformed JSON", false],
        invalid_token: [401, "Invalid access token", false],
        expired_token: [401, "Expired access token", false],
        replayed_token: [401, "Replayed access token", false],
        insufficient_scope: [403, "Insufficient scope", false],
        inactive_user: [403, "Inactive user", false],
        unsupported_media_type: [415, "Unsupported media type", false],
        invalid_request_schema: [422, "Invalid request", false],
        unsupported_capability: [422, "Unsupported capability", false],
        invalid_response_schema: [500, "Invalid response", false],
        internal_error: [500, "Internal error", false],
        service_unavailable: [503, "Service unavailable", true]
      }.freeze

      attr_reader :code, :status, :retryable

      def initialize(code)
        definition = DEFINITIONS.fetch(code.to_sym)
        @code = code.to_s
        @status, safe_message, @retryable = definition
        super(safe_message)
      end
    end

    Result = Struct.new(:status, :body, :headers, keyword_init: true)
  end
end
