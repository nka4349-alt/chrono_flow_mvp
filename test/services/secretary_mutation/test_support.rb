# frozen_string_literal: true

require_relative '../chrono_flow_specialist/test_support'
require 'base64'

module SecretaryMutationTestSupport
  include ChronoFlowSpecialistTestSupport

  MUTATION_HMAC_KEY = 'flow-mutation-test-hmac-key-32-bytes-minimum'.freeze
  MUTATION_HMAC_KID = 'test-k1'
  MUTATION_ROUTE = '/api/v1/secretary/mutation_proposals'

  def mutation_configuration(keys: { MUTATION_HMAC_KID => MUTATION_HMAC_KEY }, active_kid: MUTATION_HMAC_KID)
    SecretaryMutation::Configuration.new(
      'AI_SECRETARY_SPECIALIST_JWT_ISSUER' => TEST_ISSUER,
      'AI_SECRETARY_SPECIALIST_JWKS_URI' => 'https://jwks.example.test/.well-known/jwks.json',
      'AI_SECRETARY_SPECIALIST_REPLAY_CACHE_URL' => 'rediss://redis.example.test/0',
      'SECRETARY_MUTATION_HMAC_KEYS' => JSON.generate(
        keys.transform_values { |key| Base64.strict_encode64(key) }
      ),
      'SECRETARY_MUTATION_ACTIVE_HMAC_KID' => active_kid
    )
  end

  def mutation_dependencies(now:)
    {
      enabled: true, configuration: mutation_configuration,
      jwks_provider: FakeJwksProvider.new(keys: { TEST_KID => test_rsa_key.public_key }),
      replay_store: FakeReplayStore.new, clock: -> { now.call }
    }
  end

  def mutation_propose(operation:, message:, previous: nil, candidate_ref: nil)
    {
      'version' => 'draft-0.1', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'operation' => operation, 'message' => message, 'locale' => 'ja-JP', 'time_zone' => 'Asia/Tokyo',
      'proposal_id' => previous&.fetch('proposal_id'), 'expected_revision' => previous&.fetch('revision'),
      'candidate_ref' => candidate_ref
    }
  end

  def mutation_confirm(ready, idempotency_key: SecureRandom.uuid)
    {
      'version' => 'draft-0.1', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'proposal_id' => ready.fetch('proposal_id'), 'revision' => ready.fetch('revision'),
      'operation' => ready.fetch('operation'), 'target_ref' => ready.dig('target', 'target_ref'),
      'target_version' => ready.dig('target', 'target_version'),
      'content_digest' => ready.fetch('content_digest'), 'idempotency_key' => idempotency_key
    }
  end

  def mutation_cancel(proposal)
    {
      'version' => 'draft-0.1', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'proposal_id' => proposal.fetch('proposal_id'), 'revision' => proposal.fetch('revision'),
      'operation' => proposal.fetch('operation')
    }
  end

  def request_mutation(phase, payload = nil, proposal_id: nil, claims: {}, raw_body: nil,
                       token: nil, headers_override: {}, dependencies: @mutation_dependencies)
    id = proposal_id || payload&.[]('proposal_id')
    suffix = { 'execute' => '/confirm', 'cancel' => '/cancel', 'status' => '' }[phase]
    path = phase == 'propose' ? MUTATION_ROUTE : "#{MUTATION_ROUTE}/#{id}#{suffix}"
    raw = raw_body || (payload ? JSON.generate(payload) : '')
    request_id = payload&.[]('request_id') || SecureRandom.uuid
    trace_id = payload&.[]('trace_id') || SecureRandom.uuid
    operation = payload&.[]('operation') || claims['mutation_operation'] || @last_operation || 'event.update'
    headers = {
      'Accept' => 'application/json', 'Content-Type' => 'application/json',
      'X-Request-Id' => request_id, 'X-Trace-Id' => trace_id,
      'Authorization' => "Bearer #{token || mutation_token(operation: operation, phase: phase,
        path: path, raw: raw, request_id: request_id, trace_id: trace_id, overrides: claims)}"
    }.merge(headers_override)
    SecretaryMutation::Dependencies.with_test(dependencies) do
      phase == 'status' ? get(path, headers: headers) : post(path, params: raw, headers: headers)
    end
    @last_operation = operation
  end

  def mutation_token(operation:, phase:, path:, raw:, request_id:, trace_id:, overrides: {})
    now = @now.to_i
    build_token(now: now, claim_overrides: {
      'aud' => 'chrono-flow-secretary-mutations',
      'sub' => @home_subject,
      'scope' => "secretary:chrono_flow:#{operation}:#{phase}",
      'iat' => now, 'exp' => now + 60, 'jti' => SecureRandom.uuid,
      'identity_issuer' => @user.identity_issuer, 'identity_subject' => @user.identity_subject,
      'mutation_operation' => operation, 'mutation_phase' => phase,
      'http_method' => phase == 'status' ? 'GET' : 'POST', 'http_path' => path,
      'body_sha256' => Digest::SHA256.hexdigest(raw),
      'request_id' => request_id, 'trace_id' => trace_id
    }.merge(overrides))
  end

  def mutation_body
    JSON.parse(response.body)
  end

  def assert_mutation_error(code, status)
    assert_response status
    assert_equal code, mutation_body.dig('error', 'code'), mutation_body.inspect
    SecretaryMutation::Contract.validate_error_response!(mutation_body)
  end
end
