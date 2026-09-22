# frozen_string_literal: true

module SecretaryMutation
  class ReplayStore < ChronoFlowSpecialist::ReplayStore
    def consume_once(digest:, ttl_seconds:)
      return :unavailable unless ttl_seconds == 65 && DIGEST_PATTERN.match?(digest.to_s)

      super
    end
  end
end
