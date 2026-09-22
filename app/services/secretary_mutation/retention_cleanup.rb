# frozen_string_literal: true

module SecretaryMutation
  class RetentionCleanup
    DEFAULT_BATCH_SIZE = 100
    MAX_BATCH_SIZE = 1_000

    def self.call(now: Time.current, batch_size: DEFAULT_BATCH_SIZE)
      new(now: now, batch_size: batch_size).call
    end

    def initialize(now:, batch_size:)
      @now = now
      @batch_size = Integer(batch_size)
      raise ArgumentError, 'invalid batch size' unless @batch_size.between?(1, MAX_BATCH_SIZE)
    end

    def call
      purged = purge_expired_status_details
      tombstoned = tombstone_expired_details(@batch_size - purged)
      { tombstoned: tombstoned, purged: purged }
    end

    private

    def purge_expired_status_details
      scope = SecretaryMutationProposal.where(status_purged_at: nil)
        .where('status_available_until <= ?', @now).order(:status_available_until, :id).limit(@batch_size)
      purged = 0
      scope.each do |proposal|
        proposal.with_lock do
          next if proposal.status_purged_at || proposal.status_available_until > @now

          terminal_status = if %w[completed completed_tombstone].include?(proposal.status)
            { status: 'completed_tombstone', reason_code: 'receipt_detail_expired' }
          elsif proposal.terminal?
            {}
          else
            { status: 'expired', reason_code: 'execution_expired' }
          end
          proposal.update_columns({
            messages: [],
            question: nil, candidate_mappings: [], target_ref: nil, target_event_id: nil,
            target_version: nil, relationship_fingerprint: nil, target_display: nil,
            before_snapshot: nil, after_snapshot: nil, changed_fields: [], planned_related_effects: nil,
            content_digest: nil, idempotency_key_digest: nil, result_id: nil, receipt: nil,
            refresh_scope: nil, completed_at: nil, receipt_detail_available_until: nil,
            idempotency_available_until: nil, cancelled_at: nil, conflicted_at: nil, expired_at: nil,
            status_purged_at: @now, updated_at: @now
          }.merge(terminal_status))
          purged += 1
        end
      end
      purged
    end

    def tombstone_expired_details(remaining)
      return 0 if remaining <= 0

      scope = SecretaryMutationProposal.where(status: 'completed')
        .where('receipt_detail_available_until <= ? AND status_available_until > ?', @now, @now)
        .order(:receipt_detail_available_until, :id).limit(remaining)
      tombstoned = 0
      scope.each do |proposal|
        proposal.with_lock do
          next unless proposal.status == 'completed' && proposal.receipt_detail_available_until <= @now

          receipt = proposal.receipt
          proposal.update_columns(
            status: 'completed_tombstone', reason_code: 'receipt_detail_expired', messages: [],
            question: nil, candidate_mappings: [], target_ref: nil, target_event_id: nil,
            target_version: nil, relationship_fingerprint: nil, target_display: nil,
            before_snapshot: nil, after_snapshot: nil, changed_fields: [], planned_related_effects: nil,
            content_digest: nil, refresh_scope: nil,
            receipt: {
              'kind' => 'tombstone', 'result_id' => receipt.fetch('result_id'),
              'operation' => receipt.fetch('operation'), 'completed_at' => receipt.fetch('completed_at'),
              'domain_outcome' => receipt.fetch('domain_outcome')
            },
            updated_at: @now
          )
          tombstoned += 1
        end
      end
      tombstoned
    end
  end
end
