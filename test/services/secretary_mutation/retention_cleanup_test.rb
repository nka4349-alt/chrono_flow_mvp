# frozen_string_literal: true

require 'test_helper'

class SecretaryMutationRetentionCleanupTest < ActiveSupport::TestCase
  setup do
    @completed_at = Time.zone.parse('2026-09-21 09:00:00.123456')
    @user = User.create!(name: 'Retention owner', email: "retention-#{SecureRandom.hex(5)}@example.test",
      password: 'Password-123!', identity_issuer: 'https://identity.example.test/',
      identity_subject: "retention|#{SecureRandom.uuid}")
    @proposal = SecretaryMutationProposal.create!(
      user: @user, public_id: SecureRandom.uuid, home_subject: SecureRandom.uuid,
      identity_issuer: @user.identity_issuer, identity_subject: @user.identity_subject,
      operation: 'event.update', locale: 'ja-JP', time_zone: 'Asia/Tokyo', status: 'completed',
      revision: 1, execution_expires_at: @completed_at - 1.minute,
      status_available_until: @completed_at + 400.days,
      receipt_detail_available_until: @completed_at + 30.days,
      idempotency_available_until: @completed_at + 400.days,
      messages: ['secret text'], target_ref: "st1_#{'A' * 43}", target_event_id: nil,
      target_version: "sv1_test-k1_#{'B' * 43}", relationship_fingerprint: "sr1_test-k1_#{'C' * 43}",
      target_display: { 'title' => '保持予定' }, before_snapshot: { 'private' => 'before' },
      after_snapshot: { 'private' => 'after' }, changed_fields: ['title'],
      planned_related_effects: { 'type' => 'none' }, content_digest: 'd' * 64,
      idempotency_key_digest: 'e' * 64, result_id: SecureRandom.uuid,
      receipt: {
        'result_id' => SecureRandom.uuid, 'operation' => 'event.update',
        'completed_at' => @completed_at.utc.iso8601(6), 'domain_outcome' => 'event_updated'
      },
      refresh_scope: { 'private' => 'scope' }, completed_at: @completed_at
    )
    @proposal.secretary_mutation_audits.create!(event_type: 'mutation_completed', revision: 1,
      payload: {}, occurred_at: @completed_at, created_at: @completed_at)
    @proposal.secretary_mutation_outbox_entries.create!(public_id: SecureRandom.uuid,
      event_type: 'secretary_mutation.completed', status: 'pending', payload: {}, occurred_at: @completed_at)
  end

  test 'thirty-day cleanup keeps only the minimal tombstone and exact fractional deadlines' do
    result = SecretaryMutation::RetentionCleanup.call(now: @completed_at + 31.days, batch_size: 10)
    assert_equal({ tombstoned: 1, purged: 0 }, result)
    @proposal.reload
    assert_equal 'completed_tombstone', @proposal.status
    assert_equal 'receipt_detail_expired', @proposal.reason_code
    assert_equal 'tombstone', @proposal.receipt.fetch('kind')
    assert_equal @completed_at.utc.iso8601(6), @proposal.receipt.fetch('completed_at')
    assert_equal '123456', @proposal.receipt.fetch('completed_at')[/\.(\d{6})Z\z/, 1]
    assert_nil @proposal.target_ref
    assert_nil @proposal.before_snapshot
    assert_nil @proposal.after_snapshot
    assert_nil @proposal.content_digest
    assert_nil @proposal.refresh_scope
    assert_equal 'e' * 64, @proposal.idempotency_key_digest
    assert_equal 1, @proposal.secretary_mutation_audits.count
    assert_equal 1, @proposal.secretary_mutation_outbox_entries.count
  end

  test 'four-hundred-day cleanup removes receipt and idempotency material but preserves separate audit outbox' do
    result = SecretaryMutation::RetentionCleanup.call(now: @completed_at + 401.days, batch_size: 10)
    assert_equal({ tombstoned: 0, purged: 1 }, result)
    @proposal.reload
    assert_nil @proposal.receipt
    assert_nil @proposal.result_id
    assert_nil @proposal.idempotency_key_digest
    assert_nil @proposal.completed_at
    assert_nil @proposal.receipt_detail_available_until
    assert_nil @proposal.idempotency_available_until
    assert_equal @completed_at + 401.days, @proposal.status_purged_at
    assert_equal 1, @proposal.secretary_mutation_audits.count
    assert_equal 1, @proposal.secretary_mutation_outbox_entries.count
    assert_equal({ tombstoned: 0, purged: 0 },
      SecretaryMutation::RetentionCleanup.call(now: @completed_at + 402.days, batch_size: 10))
  end

  test 'expired availability purges abandoned and terminal unexecuted details without batch starvation' do
    now = @completed_at + 10.days
    previously_purged = build_unexecuted(status: 'rejected', suffix: 'old',
      status_available_until: now - 3.days)
    previously_purged.update_columns(status_purged_at: now - 2.days, messages: [], candidate_mappings: [])
    abandoned = build_unexecuted(status: 'ready', suffix: 'abandoned',
      status_available_until: now - 2.days)
    rejected = build_unexecuted(status: 'rejected', suffix: 'rejected',
      status_available_until: now - 1.day)

    first = SecretaryMutation::RetentionCleanup.call(now: now, batch_size: 1)
    assert_equal({ tombstoned: 0, purged: 1 }, first)
    abandoned.reload
    assert_equal 'expired', abandoned.status
    assert_equal 'execution_expired', abandoned.reason_code
    assert_equal now, abandoned.status_purged_at
    assert_empty abandoned.messages
    assert_empty abandoned.candidate_mappings
    assert_nil abandoned.before_snapshot

    second = SecretaryMutation::RetentionCleanup.call(now: now, batch_size: 1)
    assert_equal({ tombstoned: 0, purged: 1 }, second)
    rejected.reload
    assert_equal 'rejected', rejected.status
    assert_equal now, rejected.status_purged_at
    assert_empty rejected.messages
    assert_nil rejected.target_ref
    assert_equal({ tombstoned: 0, purged: 0 },
      SecretaryMutation::RetentionCleanup.call(now: now, batch_size: 1))
  end

  test 'batch size bounds work and no production scheduler is implied' do
    assert_raises(ArgumentError) { SecretaryMutation::RetentionCleanup.call(now: @completed_at, batch_size: 0) }
    assert_raises(ArgumentError) { SecretaryMutation::RetentionCleanup.call(now: @completed_at, batch_size: 1_001) }
    assert_equal 'default', SecretaryMutationRetentionCleanupJob.new.queue_name
  end


  private

  def build_unexecuted(status:, suffix:, status_available_until:)
    SecretaryMutationProposal.create!(
      user: @user, public_id: SecureRandom.uuid, home_subject: SecureRandom.uuid,
      identity_issuer: @user.identity_issuer, identity_subject: @user.identity_subject,
      operation: 'event.update', locale: 'ja-JP', time_zone: 'Asia/Tokyo', status: status,
      reason_code: status == 'rejected' ? 'no_effect' : nil, revision: 1,
      execution_expires_at: status_available_until - 30.days,
      status_available_until: status_available_until, messages: ["private #{suffix}"],
      question: 'private question', candidate_mappings: [{ 'private' => suffix }],
      target_ref: "st1_#{'D' * 43}", target_version: "sv1_test-k1_#{'E' * 43}",
      relationship_fingerprint: "sr1_test-k1_#{'F' * 43}",
      target_display: { 'title' => suffix }, before_snapshot: { 'private' => suffix },
      after_snapshot: { 'private' => suffix }, changed_fields: ['title'],
      planned_related_effects: { 'type' => 'none' }, content_digest: 'f' * 64
    )
  end
end
