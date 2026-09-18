# frozen_string_literal: true

module SecretaryCreation
  class ReplayStore < ChronoFlowSpecialist::ReplayStore
    # Full accepted lifetime includes future-issued and expiration skew. Keep the
    # existing read profile's 65-second behavior unchanged.
    def consume_once(digest:, ttl_seconds:)
      return :unavailable unless ttl_seconds == 71 && DIGEST_PATTERN.match?(digest.to_s)
      client = @client_factory.call(@configuration.replay_cache_url)
      result = client.call('SET', digest, '1', 'NX', 'EX', 71)
      return :accepted if result == 'OK'
      return :replayed if result.nil? || result == false
      :unavailable
    rescue StandardError
      :unavailable
    ensure
      close_client(client) if defined?(client)
    end
  end
end
