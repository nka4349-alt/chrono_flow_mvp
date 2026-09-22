# frozen_string_literal: true

require 'test_helper'

class SecretaryMutationProposalTest < ActiveSupport::TestCase
  test 'inspect filters private identity target plan and receipt payloads' do
    secrets = {
      home_subject: 'private-home-subject',
      identity_issuer: 'https://private-issuer.example.test/',
      identity_subject: 'private-identity-subject',
      messages: ['private raw message'],
      question: 'private clarification question',
      candidate_mappings: [{ 'event_id' => 98_765, 'candidate_ref' => 'private-candidate-ref' }],
      target_ref: 'private-target-ref',
      target_event_id: 98_765,
      target_version: 'private-target-version',
      relationship_fingerprint: 'private-relationship-fingerprint',
      target_display: { 'title' => 'private target title' },
      before_snapshot: { 'title' => 'private before title' },
      after_snapshot: { 'title' => 'private after title' },
      planned_related_effects: { 'notification_jobs_to_cancel' => 3 },
      content_digest: 'private-content-digest',
      idempotency_key_digest: 'private-idempotency-digest',
      receipt: { 'result_id' => 'private-result-id' },
      refresh_scope: { 'security_context_digest' => 'private-security-context' }
    }

    inspection = SecretaryMutationProposal.new(secrets).inspect

    private_values = [
      'private-home-subject', 'https://private-issuer.example.test/', 'private-identity-subject',
      'private raw message', 'private clarification question', 'private-candidate-ref',
      'private-target-ref', 'private-target-version', 'private-relationship-fingerprint',
      'private target title', 'private before title', 'private after title',
      'private-content-digest', 'private-idempotency-digest', 'private-result-id',
      'private-security-context', '98765'
    ]
    private_values.each do |value|
      refute_includes inspection, value
    end
    assert_operator inspection.scan('[FILTERED]').length, :>=, 15
  end
end
