# frozen_string_literal: true

require "base64"
require "net/http"
require "openssl"
require "timeout"
require "uri"

module ChronoFlowSpecialist
  class JwksProvider
    MAX_BODY_BYTES = 65_536
    OPEN_TIMEOUT_SECONDS = 2
    READ_TIMEOUT_SECONDS = 3
    WRITE_TIMEOUT_SECONDS = 3
    OVERALL_TIMEOUT_SECONDS = 10

    class Unavailable < StandardError; end

    def initialize(configuration:, http_get: nil)
      @configuration = configuration
      @http_get = http_get || method(:default_http_get)
    end

    def key_for(kid)
      raise Unavailable unless kid.is_a?(String) && kid.match?(/\S/)

      document = @http_get.call(@configuration.jwks_uri)
      keys = document.is_a?(Hash) ? document["keys"] : nil
      raise Unavailable unless keys.is_a?(Array)

      matching = keys.select { |entry| entry.is_a?(Hash) && entry["kid"] == kid }
      return nil if matching.empty?
      raise Unavailable unless matching.one?

      build_rsa_key(matching.first)
    rescue Unavailable
      raise
    rescue StandardError
      raise Unavailable
    end

    private

    def default_http_get(uri_string)
      uri = URI.parse(uri_string)
      raise Unavailable unless uri.is_a?(URI::HTTPS)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION if http.respond_to?(:min_version=)
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      http.write_timeout = WRITE_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json", "Accept-Encoding" => "identity")
      body = +"".b
      response = nil
      Timeout.timeout(OVERALL_TIMEOUT_SECONDS) do
        http.start do |connection|
          connection.request(request) do |candidate|
            response = candidate
            validate_response_headers!(candidate)
            candidate.read_body do |chunk|
              body << String(chunk).b
              raise Unavailable if body.bytesize > MAX_BODY_BYTES
            end
          end
        end
      end
      raise Unavailable unless response

      StrictJson.parse(body)
    rescue StrictJson::ParseError, URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Unavailable
    end

    def validate_response_headers!(response)
      raise Unavailable unless response.is_a?(Net::HTTPSuccess)
      raise Unavailable unless response["Content-Type"].to_s.split(";", 2).first == "application/json"

      encoding = response["Content-Encoding"].to_s
      raise Unavailable unless encoding.empty? || encoding == "identity"

      content_length = response["Content-Length"].to_s
      raise Unavailable if content_length.match?(/\A\d+\z/) && content_length.to_i > MAX_BODY_BYTES
    end

    def build_rsa_key(jwk)
      raise Unavailable unless jwk["kty"] == "RSA"
      raise Unavailable if jwk.key?("use") && jwk["use"] != "sig"
      raise Unavailable if jwk.key?("alg") && jwk["alg"] != "RS256"

      modulus = OpenSSL::BN.new(strict_base64url_decode(jwk.fetch("n")), 2)
      exponent = OpenSSL::BN.new(strict_base64url_decode(jwk.fetch("e")), 2)
      sequence = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(modulus), OpenSSL::ASN1::Integer(exponent)])
      OpenSSL::PKey::RSA.new(sequence.to_der)
    rescue KeyError, OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error
      raise Unavailable
    end

    def strict_base64url_decode(value)
      encoded = String(value)
      raise Unavailable unless encoded.match?(/\A[A-Za-z0-9_-]+\z/)

      decoded = Base64.urlsafe_decode64(encoded + ("=" * ((4 - encoded.length % 4) % 4)))
      raise Unavailable unless Base64.urlsafe_encode64(decoded, padding: false) == encoded

      decoded
    rescue ArgumentError
      raise Unavailable
    end
  end
end
