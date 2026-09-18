# frozen_string_literal: true

require 'test_helper'

class SecretaryCreationParserTransactionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'candidate interpretation runs outside a database transaction' do
    user = User.create!(name: 'Outside transaction', email: "outside-#{SecureRandom.uuid}@example.test", password: 'Password-123!',
      identity_issuer: 'https://identity.example.test/', identity_subject: SecureRandom.uuid)
    parsed_outside = false
    parser = lambda do |**|
      parsed_outside = !ActiveRecord::Base.connection.transaction_open?
      { status: 'needs_clarification', question: '終了時刻を教えてください。', details: nil }
    end
    result = SecretaryCreation::Proposals.new(parser: parser).call(
      operation: 'propose', request: { 'proposal_id' => nil, 'expected_revision' => nil, 'message' => '今日18時に来客を追加',
        'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid },
      claims: { 'identity_issuer' => user.identity_issuer, 'identity_subject' => user.identity_subject, 'sub' => SecureRandom.uuid }
    )
    assert parsed_outside, 'AI parsing must not hold a database transaction or user lock'
    assert_equal 'needs_clarification', result['status']
  ensure
    SecretaryCreationProposal.where(user_id: user.id).delete_all if user&.persisted?
    user&.destroy!
  end
end
