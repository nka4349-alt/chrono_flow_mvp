# frozen_string_literal: true

require 'test_helper'
require_relative 'test_support'

class SecretaryMutationVersionerTest < ActiveSupport::TestCase
  include SecretaryMutationTestSupport

  test 'security context digest is domain and provider bound to the current identity' do
    user = User.create!(name: 'Digest owner', email: "digest-#{SecureRandom.hex(5)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "digest|#{SecureRandom.uuid}")
    home_subject = SecureRandom.uuid
    value = {
      'provider' => 'chrono_flow', 'user_id' => user.id, 'home_subject' => home_subject,
      'identity_issuer' => user.identity_issuer, 'identity_subject' => user.identity_subject,
      'user_status' => user.status, 'user_version' => user.updated_at.utc.iso8601(6)
    }
    expected_input = SecretaryMutation::Contract.canonical_json(
      'domain' => 'chrono_flow.mutation.security-context.v1', 'value' => value
    )
    versioner = SecretaryMutation::Versioner.new(configuration: mutation_configuration.validate!)
    actual = versioner.security_context_digest(user: user, home_subject: home_subject)

    assert_equal OpenSSL::HMAC.hexdigest('SHA256', MUTATION_HMAC_KEY, expected_input), actual
    wrong_domain = SecretaryMutation::Contract.canonical_json(
      'domain' => 'chrono_flow.mutation.security-context.v2', 'value' => value
    )
    wrong_provider = SecretaryMutation::Contract.canonical_json(
      'domain' => 'chrono_flow.mutation.security-context.v1',
      'value' => value.merge('provider' => 'chrono_task')
    )
    refute_equal OpenSSL::HMAC.hexdigest('SHA256', MUTATION_HMAC_KEY, wrong_domain), actual
    refute_equal OpenSSL::HMAC.hexdigest('SHA256', MUTATION_HMAC_KEY, wrong_provider), actual
  ensure
    user&.destroy!
  end
end
