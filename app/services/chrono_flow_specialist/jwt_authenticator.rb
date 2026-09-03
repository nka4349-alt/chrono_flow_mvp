# frozen_string_literal: true

require "base64"
require "digest"
require "openssl"

module ChronoFlowSpecialist
  class JwtAuthenticator
    AUDIENCE = "chrono-flow-specialist"
    SCOPE = "specialist:chrono_flow:read"
    MAX_TTL_SECONDS = 60
    CLOCK_SKEW_SECONDS = 5
    FORBIDDEN_HEADERS = %w[jku x5u jwk x5c crit].freeze
    REQUIRED_CLAIMS = %w[iss aud sub scope iat exp jti identity_issuer identity_subject].freeze
    UUID_PATTERN = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

    Authentication = Struct.new(:claims, :replay_digest, keyword_init: true) do
      def identity_issuer = claims.fetch("identity_issuer")
      def identity_subject = claims.fetch("identity_subject")
    end

    def initialize(configuration:, jwks_provider:, clock: -> { Time.now })
      @configuration = configuration
      @jwks_provider = jwks_provider
      @clock = clock
    end

    def authenticate(compact_token)
      header_segment, payload_segment, signature_segment = split_token(compact_token)
      header = decode_json_segment(header_segment)
      claims = decode_json_segment(payload_segment)
      validate_header!(header)
      key = @jwks_provider.key_for(header.fetch("kid"))
      raise Errors::Error.new(:invalid_token) unless key

      signing_input = "#{header_segment}.#{payload_segment}"
      signature = strict_base64url_decode(signature_segment)
      raise Errors::Error.new(:invalid_token) unless key.verify(OpenSSL::Digest::SHA256.new, signature, signing_input)

      validate_claims!(claims, @clock.call)
      digest = Digest::SHA256.hexdigest([claims.fetch("iss"), claims.fetch("aud"), claims.fetch("jti")].join("\0"))
      Authentication.new(claims: claims.freeze, replay_digest: digest)
    rescue Errors::Error
      raise
    rescue JwksProvider::Unavailable
      raise Errors::Error.new(:service_unavailable)
    rescue KeyError, ArgumentError, TypeError, OpenSSL::PKey::PKeyError
      raise Errors::Error.new(:invalid_token)
    end

    private

    def split_token(token)
      parts = String(token).split(".", -1)
      valid = parts.length == 3 && parts.all? { |part| part.match?(/\A[A-Za-z0-9_-]+\z/) }
      raise Errors::Error.new(:invalid_token) unless valid

      parts
    end

    def decode_json_segment(segment)
      value = StrictJson.parse(strict_base64url_decode(segment))
      raise Errors::Error.new(:invalid_token) unless value.is_a?(Hash)

      value
    rescue StrictJson::ParseError
      raise Errors::Error.new(:invalid_token)
    end

    def validate_header!(header)
      raise Errors::Error.new(:invalid_token) unless header["alg"] == "RS256"
      raise Errors::Error.new(:invalid_token) unless header["typ"] == "at+jwt"
      raise Errors::Error.new(:invalid_token) unless header["kid"].is_a?(String) && header["kid"].match?(/\S/)
      raise Errors::Error.new(:invalid_token) if FORBIDDEN_HEADERS.any? { |name| header.key?(name) }
    end

    def validate_claims!(claims, now_value)
      raise Errors::Error.new(:invalid_token) unless REQUIRED_CLAIMS.all? { |name| claims.key?(name) }
      raise Errors::Error.new(:invalid_token) if claims.key?("workspace_id")
      raise Errors::Error.new(:invalid_token) unless claims["iss"] == @configuration.issuer
      raise Errors::Error.new(:invalid_token) unless claims["aud"].is_a?(String) && claims["aud"] == AUDIENCE
      raise Errors::Error.new(:invalid_token) unless claims["scope"].is_a?(String)
      raise Errors::Error.new(:insufficient_scope) unless claims["scope"] == SCOPE
      raise Errors::Error.new(:invalid_token) unless claims["sub"].is_a?(String) && UUID_PATTERN.match?(claims["sub"])
      raise Errors::Error.new(:invalid_token) unless claims["jti"].is_a?(String) && claims["jti"].match?(/\S/)
      raise Errors::Error.new(:invalid_token) unless nonblank_exact_string?(claims["identity_issuer"])
      raise Errors::Error.new(:invalid_token) unless nonblank_exact_string?(claims["identity_subject"])
      raise Errors::Error.new(:invalid_token) unless claims["iat"].is_a?(Integer) && claims["exp"].is_a?(Integer)

      now = now_value.to_i
      raise Errors::Error.new(:expired_token) if now >= claims["exp"] + CLOCK_SKEW_SECONDS
      raise Errors::Error.new(:invalid_token) if claims["iat"] > now + CLOCK_SKEW_SECONDS
      raise Errors::Error.new(:invalid_token) unless claims["exp"] > claims["iat"]
      raise Errors::Error.new(:invalid_token) if claims["exp"] - claims["iat"] > MAX_TTL_SECONDS
      raise Errors::Error.new(:invalid_token) if claims["exp"] - now > MAX_TTL_SECONDS
    end

    def nonblank_exact_string?(value)
      value.is_a?(String) && value.match?(/\S/)
    end

    def strict_base64url_decode(segment)
      decoded = Base64.urlsafe_decode64(segment + ("=" * ((4 - segment.length % 4) % 4)))
      raise Errors::Error.new(:invalid_token) unless Base64.urlsafe_encode64(decoded, padding: false) == segment

      decoded
    rescue ArgumentError
      raise Errors::Error.new(:invalid_token)
    end
  end
end
