# frozen_string_literal: true

require "base64"
require "openssl"

module ChronoFlowSpecialist
  class FactId
    def initialize(secret:, namespace: "chrono_flow")
      raise ArgumentError, "fact id secret is required" unless secret.to_s.bytesize >= 32

      @secret = secret
      @namespace = namespace
    end

    def for(record, kind:)
      material = [@namespace, kind.to_s, record.class.name, record.id.to_s].join("\0")
      digest = OpenSSL::HMAC.digest("SHA256", @secret, material)
      "cf_#{Base64.urlsafe_encode64(digest, padding: false)}"
    end
  end
end
