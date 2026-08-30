# frozen_string_literal: true

require "redis-client"

module ChronoFlowSpecialist
  class ReplayStore
    TTL_SECONDS = 65
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

    def initialize(configuration:, client_factory: nil)
      @configuration = configuration
      @client_factory = client_factory || method(:build_client)
    end

    def consume_once(digest:, ttl_seconds:)
      return :unavailable unless ttl_seconds == TTL_SECONDS && DIGEST_PATTERN.match?(digest.to_s)

      client = @client_factory.call(@configuration.replay_cache_url)
      result = client.call("SET", digest, "1", "NX", "EX", TTL_SECONDS)
      return :accepted if result == "OK"
      return :replayed if result.nil? || result == false

      :unavailable
    rescue StandardError
      :unavailable
    ensure
      close_client(client) if defined?(client)
    end

    private

    def build_client(url)
      RedisClient.config(url: url, reconnect_attempts: 0).new_client
    end

    def close_client(client)
      client.close if client&.respond_to?(:close)
    rescue StandardError
      nil
    end
  end
end
