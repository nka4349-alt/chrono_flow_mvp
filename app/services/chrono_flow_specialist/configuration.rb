# frozen_string_literal: true

require "uri"

module ChronoFlowSpecialist
  class Configuration
    ISSUER_KEY = "AI_SECRETARY_SPECIALIST_JWT_ISSUER"
    JWKS_URI_KEY = "AI_SECRETARY_SPECIALIST_JWKS_URI"
    REPLAY_URL_KEY = "AI_SECRETARY_SPECIALIST_REPLAY_CACHE_URL"

    attr_reader :issuer, :jwks_uri, :replay_cache_url

    def initialize(env = ENV)
      @issuer = env[ISSUER_KEY]
      @jwks_uri = env[JWKS_URI_KEY]
      @replay_cache_url = env[REPLAY_URL_KEY]
    end

    def validate!
      validate_https_uri!(@issuer)
      validate_https_uri!(@jwks_uri)
      validate_replay_uri!(@replay_cache_url)
      self
    rescue URI::InvalidURIError
      raise Errors::Error.new(:service_unavailable)
    end

    private

    def validate_https_uri!(value)
      uri = URI.parse(String(value))
      valid = uri.is_a?(URI::HTTPS) && uri.host.to_s.length.positive? && !uri.userinfo && !uri.fragment
      raise Errors::Error.new(:service_unavailable) unless valid && uri.to_s == value
    end

    def validate_replay_uri!(value)
      uri = URI.parse(String(value))
      valid = %w[redis rediss].include?(uri.scheme) && uri.host.to_s.length.positive? && !uri.fragment
      raise Errors::Error.new(:service_unavailable) unless valid
    end
  end
end
