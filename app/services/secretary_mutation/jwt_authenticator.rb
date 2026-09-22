# frozen_string_literal: true

module SecretaryMutation
  class JwtAuthenticator < ChronoFlowSpecialist::JwtAuthenticator
    AUDIENCE = 'chrono-flow-secretary-mutations'
    OPERATIONS = %w[event.update event.delete].freeze
    PHASES = %w[propose execute cancel status].freeze
    CLAIM_KEYS = %w[iss aud sub iat exp jti scope identity_issuer identity_subject
      mutation_operation mutation_phase http_method http_path body_sha256 request_id trace_id].freeze
    HEADER_KEYS = %w[alg typ kid].freeze
    CANONICAL_UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    def initialize(expected_operation:, phase:, method:, path:, raw_body:, request_id:, trace_id:, **options)
      super(**options)
      @expected_operation = expected_operation
      @phase = phase
      @method = method
      @path = path
      @raw_body = raw_body
      @request_id = request_id
      @trace_id = trace_id
    end

    private

    def validate_header!(header)
      invalid! unless header.is_a?(Hash) && header.keys.sort == HEADER_KEYS.sort
      invalid! unless header['alg'] == 'RS256' && header['typ'] == 'at+jwt'
      invalid! unless header['kid'].is_a?(String) && header['kid'].match?(/\A[A-Za-z0-9_-]{1,128}\z/)
    end

    def validate_claims!(claims, now_value)
      invalid! unless claims.is_a?(Hash) && claims.keys.sort == CLAIM_KEYS.sort
      invalid! if claims.key?('workspace_id')
      invalid! unless claims['iss'] == @configuration.issuer && claims['aud'] == AUDIENCE
      invalid! unless CANONICAL_UUID.match?(claims['sub'].to_s)
      invalid! unless CANONICAL_UUID.match?(claims['jti'].to_s)
      invalid! unless nonblank_exact_string?(claims['identity_issuer']) && nonblank_exact_string?(claims['identity_subject'])
      invalid! unless claims['iat'].is_a?(Integer) && claims['exp'].is_a?(Integer)

      now = now_value.to_i
      invalid! unless now < claims['exp'] + CLOCK_SKEW_SECONDS
      invalid! unless claims['iat'] <= now + CLOCK_SKEW_SECONDS
      invalid! unless claims['exp'] > claims['iat'] && claims['exp'] - claims['iat'] <= MAX_TTL_SECONDS
      invalid! unless OPERATIONS.include?(claims['mutation_operation'])
      invalid! unless @expected_operation.nil? || claims['mutation_operation'] == @expected_operation
      invalid! unless PHASES.include?(claims['mutation_phase']) && claims['mutation_phase'] == @phase
      invalid! unless claims['scope'] == "secretary:chrono_flow:#{claims['mutation_operation']}:#{@phase}"
      invalid! unless claims['http_method'] == @method && claims['http_path'] == @path
      invalid! unless claims['body_sha256'] == Digest::SHA256.hexdigest(@raw_body)
      invalid! unless claims['request_id'] == @request_id && claims['trace_id'] == @trace_id
    end

    def invalid!
      raise Error.new(:unauthenticated), cause: nil
    end
  end
end
