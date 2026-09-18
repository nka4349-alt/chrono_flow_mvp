# frozen_string_literal: true

module SecretaryCreation
  # Shares signature/JWKS/strict JSON primitives, but never the read token profile.
  class JwtAuthenticator < ChronoFlowSpecialist::JwtAuthenticator
    def initialize(operation:, method:, path:, raw_body:, **options)
      super(**options)
      @operation, @method, @path, @raw_body = operation, method, path, raw_body
    end

    private

    def validate_claims!(claims, now_value)
      invalid! unless REQUIRED_CLAIMS.all? { |name| claims.key?(name) }
      invalid! if claims.key?('workspace_id')
      invalid! unless claims['iss'] == @configuration.issuer
      invalid! unless claims['aud'] == 'chrono-flow-secretary-actions'
      invalid! unless claims['scope'] == "secretary:chrono_flow:#{@operation}"
      invalid! unless claims['sub'].is_a?(String) && UUID_PATTERN.match?(claims['sub'])
      invalid! unless claims['jti'].is_a?(String) && claims['jti'].match?(/\S/)
      invalid! unless nonblank_exact_string?(claims['identity_issuer']) && nonblank_exact_string?(claims['identity_subject'])
      invalid! unless claims['iat'].is_a?(Integer) && claims['exp'].is_a?(Integer)
      now = now_value.to_i
      invalid! unless now < claims['exp'] + CLOCK_SKEW_SECONDS && claims['iat'] <= now + CLOCK_SKEW_SECONDS
      invalid! unless claims['exp'] > claims['iat'] && claims['exp'] - claims['iat'] <= MAX_TTL_SECONDS
      invalid! unless claims['creation_method'] == @method && claims['creation_path'] == @path
      invalid! unless claims['creation_body_sha256'] == Digest::SHA256.hexdigest(@raw_body)
    end

    def invalid!
      raise ChronoFlowSpecialist::Errors::Error.new(:invalid_token)
    end
  end
end
