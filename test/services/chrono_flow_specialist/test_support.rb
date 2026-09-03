# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "securerandom"
require "set"

module ChronoFlowSpecialistTestSupport
  TEST_KID = "test-kid"
  TEST_ISSUER = "https://issuer.example.test"
  TEST_IDENTITY_ISSUER = "https://identity.example.test/"

  class FakeJwksProvider
    attr_reader :requested_kids

    def initialize(keys:)
      @keys = keys
      @requested_kids = []
    end

    def key_for(kid)
      @requested_kids << kid
      @keys[kid]
    end
  end

  class FakeReplayStore
    attr_reader :calls

    def initialize(result: nil)
      @forced_result = result
      @digests = Set.new
      @calls = []
    end

    def consume_once(digest:, ttl_seconds:)
      @calls << { digest: digest, ttl_seconds: ttl_seconds }
      return @forced_result if @forced_result
      return :replayed if @digests.include?(digest)

      @digests << digest
      :accepted
    end
  end

  def test_rsa_key
    @test_rsa_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def test_configuration
    ChronoFlowSpecialist::Configuration.new(
      "AI_SECRETARY_SPECIALIST_JWT_ISSUER" => TEST_ISSUER,
      "AI_SECRETARY_SPECIALIST_JWKS_URI" => "https://jwks.example.test/.well-known/jwks.json",
      "AI_SECRETARY_SPECIALIST_REPLAY_CACHE_URL" => "rediss://redis.example.test/0"
    )
  end

  def test_now
    Time.zone.parse("2026-08-30 12:00:00")
  end

  def test_jwk(kid: TEST_KID, key: test_rsa_key)
    {
      "kty" => "RSA",
      "use" => "sig",
      "alg" => "RS256",
      "kid" => kid,
      "n" => Base64.urlsafe_encode64(key.n.to_s(2), padding: false),
      "e" => Base64.urlsafe_encode64(key.e.to_s(2), padding: false)
    }
  end

  def valid_claims(now: test_now.to_i, overrides: {})
    {
      "iss" => TEST_ISSUER,
      "aud" => "chrono-flow-specialist",
      "sub" => "123e4567-e89b-12d3-a456-426614174000",
      "scope" => "specialist:chrono_flow:read",
      "iat" => now,
      "exp" => now + 60,
      "jti" => "jti-#{SecureRandom.hex(8)}",
      "identity_issuer" => TEST_IDENTITY_ISSUER,
      "identity_subject" => "provider|user-1"
    }.merge(overrides)
  end

  def build_token(claim_overrides: {}, header_overrides: {}, key: test_rsa_key, now: test_now.to_i)
    header = { "alg" => "RS256", "typ" => "at+jwt", "kid" => TEST_KID }.merge(header_overrides)
    claims = valid_claims(now: now, overrides: claim_overrides)
    encoded_header = encode_segment(header)
    encoded_claims = encode_segment(claims)
    signing_input = "#{encoded_header}.#{encoded_claims}"
    signature = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
    "#{signing_input}.#{Base64.urlsafe_encode64(signature, padding: false)}"
  end

  def request_payload(capability: "schedule_context", constraints: {}, time_zone: "Asia/Tokyo", overrides: {})
    {
      "version" => "2.1",
      "request_id" => "request-1",
      "call_id" => "call-1",
      "trace_id" => "trace-1",
      "specialist" => "chrono_flow_ai",
      "mode" => "read",
      "capability" => capability,
      "user_message" => "show my schedule",
      "locale" => "ja-JP",
      "time_zone" => time_zone,
      "context_refs" => [],
      "constraints" => constraints
    }.merge(overrides)
  end

  def request_headers(payload:, token:, overrides: {})
    {
      "Authorization" => "Bearer #{token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json",
      "Accept-Encoding" => "identity",
      "X-Request-Id" => payload.fetch("request_id"),
      "X-Trace-Id" => payload.fetch("trace_id")
    }.merge(overrides)
  end

  def handler_dependencies(configuration: test_configuration, jwks_provider: nil, replay_store: nil,
                           clock: nil)
    clock ||= -> { test_now }
    jwks_provider ||= FakeJwksProvider.new(keys: { TEST_KID => test_rsa_key.public_key })
    replay_store ||= FakeReplayStore.new
    ChronoFlowSpecialist::Dependencies.build(
      configuration: configuration,
      jwks_provider: jwks_provider,
      replay_store: replay_store,
      clock: clock,
      fact_secret: "test-fact-id-secret-which-is-at-least-thirty-two-bytes"
    )
  end

  private

  def encode_segment(value)
    Base64.urlsafe_encode64(JSON.generate(value), padding: false)
  end
end
