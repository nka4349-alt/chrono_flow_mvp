# frozen_string_literal: true

require 'base64'
require 'json'

module SecretaryMutation
  class Configuration
    HMAC_KEYS = 'SECRETARY_MUTATION_HMAC_KEYS'
    ACTIVE_HMAC_KID = 'SECRETARY_MUTATION_ACTIVE_HMAC_KID'

    attr_reader :specialist_configuration, :hmac_keys, :active_hmac_kid

    def initialize(env = ENV)
      @specialist_configuration = ChronoFlowSpecialist::Configuration.new(env)
      @hmac_keys = decode_hmac_keys(env[HMAC_KEYS]).freeze
      @active_hmac_kid = env[ACTIVE_HMAC_KID]
    end

    def validate!
      specialist_configuration.validate!
      valid_keys = hmac_keys.present? && hmac_keys.all? do |kid, key|
        /\A[A-Za-z0-9_-]{1,16}\z/.match?(kid) && key.is_a?(String) && key.bytesize >= 32
      end
      raise Error.new(:unavailable) unless valid_keys && hmac_keys.key?(active_hmac_kid)

      self
    end

    private

    def decode_hmac_keys(raw)
      value = JSON.parse(raw.to_s, create_additions: false)
      return {} unless value.instance_of?(Hash)

      value.to_h do |kid, encoded|
        return {} unless kid.instance_of?(String) && encoded.instance_of?(String)

        [kid, Base64.strict_decode64(encoded)]
      end
    rescue JSON::ParserError, ArgumentError
      {}
    end
  end
end
