# frozen_string_literal: true

require "test_helper"
require "net/http"
require_relative "test_support"

class ChronoFlowSpecialistJwksProviderTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  class FakeHttpsSuccess < Net::HTTPOK
    def initialize(chunks:, content_encoding: nil, content_length: nil)
      super("1.1", "200", "OK")
      @chunks = chunks
      @fake_headers = {
        "Content-Type" => "application/json",
        "Content-Encoding" => content_encoding,
        "Content-Length" => content_length
      }
    end

    def [](name)
      @fake_headers[name]
    end

    def read_body
      @chunks.each { |chunk| yield chunk }
    end
  end

  class FakeHttp
    attr_accessor :use_ssl, :verify_mode, :min_version, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :request_value, :request_count

    def initialize(response)
      @response = response
      @request_count = 0
    end

    def start
      yield self
    end

    def request(value)
      @request_value = value
      @request_count += 1
      yield @response if block_given?
      @response
    end
  end

  test "selects exactly one RS256 signing key by kid" do
    provider = ChronoFlowSpecialist::JwksProvider.new(
      configuration: test_configuration,
      http_get: ->(_uri) { { "keys" => [test_jwk] } }
    )
    key = provider.key_for(TEST_KID)
    message = "signed"
    signature = test_rsa_key.sign(OpenSSL::Digest::SHA256.new, message)

    assert key.verify(OpenSSL::Digest::SHA256.new, signature, message)
    assert_nil provider.key_for("unknown")
  end

  test "duplicate kid or malformed key is unavailable" do
    duplicate = ChronoFlowSpecialist::JwksProvider.new(
      configuration: test_configuration,
      http_get: ->(_uri) { { "keys" => [test_jwk, test_jwk] } }
    )
    malformed = ChronoFlowSpecialist::JwksProvider.new(
      configuration: test_configuration,
      http_get: ->(_uri) { { "keys" => [test_jwk.merge("kty" => "EC")] } }
    )

    assert_raises(ChronoFlowSpecialist::JwksProvider::Unavailable) { duplicate.key_for(TEST_KID) }
    assert_raises(ChronoFlowSpecialist::JwksProvider::Unavailable) { malformed.key_for(TEST_KID) }
  end

  test "rejects non-identity JWKS content encoding before parsing keys" do
    response = FakeHttpsSuccess.new(
      chunks: [JSON.generate("keys" => [test_jwk])],
      content_encoding: "gzip"
    )
    http = FakeHttp.new(response)
    provider = ChronoFlowSpecialist::JwksProvider.new(configuration: test_configuration)

    with_replaced_singleton_method(Net::HTTP, :new, ->(*_arguments) { http }) do
      assert_raises(ChronoFlowSpecialist::JwksProvider::Unavailable) { provider.key_for(TEST_KID) }
    end

    assert_equal "identity", http.request_value["Accept-Encoding"]
    assert_equal 1, http.request_count
  end

  test "default transport is bounded to one streamed HTTPS attempt" do
    document = JSON.generate("keys" => [test_jwk])
    response = FakeHttpsSuccess.new(chunks: [document.byteslice(0, 17), document.byteslice(17..)])
    http = FakeHttp.new(response)
    provider = ChronoFlowSpecialist::JwksProvider.new(configuration: test_configuration)

    key = with_replaced_singleton_method(Net::HTTP, :new, ->(*_arguments) { http }) do
      provider.key_for(TEST_KID)
    end

    assert_instance_of OpenSSL::PKey::RSA, key
    assert_equal 1, http.request_count
    assert_equal 0, http.max_retries
    assert_equal 2, http.open_timeout
    assert_equal 3, http.read_timeout
    assert_equal 3, http.write_timeout
    assert_equal "application/json", http.request_value["Accept"]
    assert_equal "identity", http.request_value["Accept-Encoding"]
    assert_equal 10, ChronoFlowSpecialist::JwksProvider::OVERALL_TIMEOUT_SECONDS
  end

  test "streaming aborts as soon as JWKS body exceeds the bound" do
    response = FakeHttpsSuccess.new(chunks: ["x" * 65_000, "y" * 537])
    http = FakeHttp.new(response)
    provider = ChronoFlowSpecialist::JwksProvider.new(configuration: test_configuration)

    with_replaced_singleton_method(Net::HTTP, :new, ->(*_arguments) { http }) do
      assert_raises(ChronoFlowSpecialist::JwksProvider::Unavailable) { provider.key_for(TEST_KID) }
    end

    assert_equal 1, http.request_count
  end


  private

  def with_replaced_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, &replacement)
    yield
  ensure
    target.define_singleton_method(name, &original)
  end
end
