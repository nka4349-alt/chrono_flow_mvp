# frozen_string_literal: true

require "test_helper"
require_relative "test_support"

class ChronoFlowSpecialistJwtAuthenticatorTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  setup do
    @jwks = FakeJwksProvider.new(keys: { TEST_KID => test_rsa_key.public_key })
    @authenticator = ChronoFlowSpecialist::JwtAuthenticator.new(
      configuration: test_configuration,
      jwks_provider: @jwks,
      clock: -> { test_now }
    )
  end

  test "verifies exact claims and computes NUL-separated replay digest" do
    token = build_token(claim_overrides: { "jti" => "one-attempt" })
    authentication = @authenticator.authenticate(token)
    expected = Digest::SHA256.hexdigest("#{TEST_ISSUER}\0chrono-flow-specialist\0one-attempt")

    assert_equal expected, authentication.replay_digest
    assert_equal TEST_IDENTITY_ISSUER, authentication.identity_issuer
    assert_equal "provider|user-1", authentication.identity_subject
    assert_equal [TEST_KID], @jwks.requested_kids
  end

  test "requires scalar exact audience and scope and prohibits workspace binding" do
    audience = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "aud" => ["chrono-flow-specialist"] }))
    end
    scope = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "scope" => "specialist:chrono_flow:read extra" }))
    end
    workspace = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "workspace_id" => "not-allowed" }))
    end

    assert_equal "invalid_token", audience.code
    assert_equal "insufficient_scope", scope.code
    assert_equal "invalid_token", workspace.code
  end

  test "enforces integer numeric dates maximum TTL skew and expiry" do
    ttl = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "exp" => test_now.to_i + 61 }))
    end
    future = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "iat" => test_now.to_i + 6, "exp" => test_now.to_i + 60 }))
    end
    expired = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "iat" => test_now.to_i - 66, "exp" => test_now.to_i - 6 }))
    end

    assert_equal "invalid_token", ttl.code
    assert_equal "invalid_token", future.code
    assert_equal "expired_token", expired.code
  end

  test "accepted token lifetime is fully covered by the fixed replay TTL" do
    token = build_token(
      now: test_now.to_i,
      claim_overrides: { "iat" => test_now.to_i, "exp" => test_now.to_i + 60 }
    )
    before_replay_expiry = ChronoFlowSpecialist::JwtAuthenticator.new(
      configuration: test_configuration,
      jwks_provider: @jwks,
      clock: -> { test_now + 64.seconds }
    )
    at_replay_expiry = ChronoFlowSpecialist::JwtAuthenticator.new(
      configuration: test_configuration,
      jwks_provider: @jwks,
      clock: -> { test_now + 65.seconds }
    )

    assert before_replay_expiry.authenticate(token)
    error = assert_raises(ChronoFlowSpecialist::Errors::Error) { at_replay_expiry.authenticate(token) }
    assert_equal "expired_token", error.code

    future_full_ttl = build_token(
      now: test_now.to_i,
      claim_overrides: { "iat" => test_now.to_i + 5, "exp" => test_now.to_i + 65 }
    )
    future_error = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(future_full_ttl)
    end
    assert_equal "invalid_token", future_error.code
  end

  test "expiry clock is sampled after JWKS signature verification" do
    current = test_now
    delayed_time = test_now + 65.seconds
    public_key = test_rsa_key.public_key
    delayed_jwks = Object.new
    delayed_jwks.define_singleton_method(:key_for) do |_kid|
      current = delayed_time
      public_key
    end
    authenticator = ChronoFlowSpecialist::JwtAuthenticator.new(
      configuration: test_configuration,
      jwks_provider: delayed_jwks,
      clock: -> { current }
    )
    token = build_token(
      now: test_now.to_i,
      claim_overrides: { "iat" => test_now.to_i, "exp" => test_now.to_i + 60 }
    )

    error = assert_raises(ChronoFlowSpecialist::Errors::Error) { authenticator.authenticate(token) }
    assert_equal "expired_token", error.code
  end

  test "rejects every forbidden JOSE header invalid UUID sub and wrong signature" do
    ChronoFlowSpecialist::JwtAuthenticator::FORBIDDEN_HEADERS.each do |name|
      forbidden = assert_raises(ChronoFlowSpecialist::Errors::Error) do
        @authenticator.authenticate(build_token(header_overrides: { name => "untrusted" }))
      end
      assert_equal "invalid_token", forbidden.code
    end
    subject = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(claim_overrides: { "sub" => "local-user-id" }))
    end
    signature = assert_raises(ChronoFlowSpecialist::Errors::Error) do
      @authenticator.authenticate(build_token(key: OpenSSL::PKey::RSA.generate(2048)))
    end

    assert_equal %w[invalid_token invalid_token], [subject.code, signature.code]
  end

  test "requires exact RS256 typ kid issuer jti identity and integer dates" do
    invalid_tokens = [
      build_token(header_overrides: { "alg" => "HS256" }),
      build_token(header_overrides: { "typ" => "JWT" }),
      build_token(header_overrides: { "kid" => "" }),
      build_token(claim_overrides: { "iss" => "https://wrong-issuer.example.test" }),
      build_token(claim_overrides: { "jti" => "" }),
      build_token(claim_overrides: { "identity_issuer" => " " }),
      build_token(claim_overrides: { "identity_subject" => "\t" }),
      build_token(claim_overrides: { "iat" => test_now.to_i.to_s }),
      build_token(claim_overrides: { "exp" => (test_now.to_i + 60).to_s })
    ]

    invalid_tokens.each do |token|
      error = assert_raises(ChronoFlowSpecialist::Errors::Error) { @authenticator.authenticate(token) }
      assert_equal "invalid_token", error.code
    end
  end

  test "maps JWKS unavailability to service unavailable" do
    unavailable = Object.new
    unavailable.define_singleton_method(:key_for) { |_kid| raise ChronoFlowSpecialist::JwksProvider::Unavailable }
    authenticator = ChronoFlowSpecialist::JwtAuthenticator.new(
      configuration: test_configuration, jwks_provider: unavailable, clock: -> { test_now }
    )

    error = assert_raises(ChronoFlowSpecialist::Errors::Error) { authenticator.authenticate(build_token) }
    assert_equal "service_unavailable", error.code
  end
end
