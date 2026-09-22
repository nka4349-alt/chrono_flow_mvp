# frozen_string_literal: true

module SecretaryMutation
  class ResponseBuilder
    def initialize(proposal:, request_id:, trace_id:, now:)
      @proposal = proposal
      @request_id = request_id
      @trace_id = trace_id
      @now = now
    end

    def call
      if @proposal.executed? && @now >= @proposal.receipt_detail_available_until
        tombstone_response
      else
        full_response
      end
    end

    private

    def full_response
      {
        'version' => 'draft-0.1',
        'request_id' => @request_id,
        'trace_id' => @trace_id,
        'provider' => 'chrono_flow',
        'operation' => @proposal.operation,
        'proposal_id' => @proposal.public_id,
        'revision' => @proposal.revision,
        'status' => @proposal.status,
        'reason_code' => @proposal.reason_code,
        'execution_expires_at' => timestamp(@proposal.execution_expires_at),
        'status_available_until' => timestamp(@proposal.status_available_until),
        'receipt_detail_available_until' => timestamp(@proposal.receipt_detail_available_until),
        'idempotency_available_until' => timestamp(@proposal.idempotency_available_until),
        'question' => @proposal.status == 'completed' ? nil : @proposal.question,
        'candidates' => candidates,
        'target' => target,
        'before' => @proposal.before_snapshot,
        'after' => @proposal.after_snapshot,
        'changed_fields' => @proposal.changed_fields,
        'relationship_fingerprint' => @proposal.relationship_fingerprint,
        'planned_related_effects' => @proposal.planned_related_effects,
        'content_digest' => @proposal.content_digest,
        'receipt' => @proposal.receipt,
        'refresh_scope' => @proposal.refresh_scope
      }
    end

    def tombstone_response
      receipt = @proposal.receipt
      base = full_response
      base.merge(
        'status' => 'completed_tombstone', 'reason_code' => 'receipt_detail_expired',
        'execution_expires_at' => nil,
        'question' => nil, 'candidates' => nil, 'target' => nil, 'before' => nil, 'after' => nil,
        'changed_fields' => [], 'relationship_fingerprint' => nil, 'planned_related_effects' => nil,
        'content_digest' => nil,
        'receipt' => {
          'kind' => 'tombstone', 'result_id' => receipt.fetch('result_id'),
          'operation' => receipt.fetch('operation'), 'completed_at' => receipt.fetch('completed_at'),
          'domain_outcome' => receipt.fetch('domain_outcome')
        },
        'refresh_scope' => nil
      )
    end

    def candidates
      return nil unless @proposal.status == 'needs_target'

      mappings = @proposal.candidate_mappings
      {
        'truncated' => mappings.any? { |item| item['truncated'] == true },
        'items' => mappings.reject { |item| item['truncated'] }.map do |item|
          {
            'candidate_ref' => item.fetch('candidate_ref'), 'kind' => 'event',
            'display' => item.fetch('display'), 'target_version' => item.fetch('target_version')
          }
        end
      }
    end

    def target
      return nil unless @proposal.target_ref

      {
        'target_ref' => @proposal.target_ref, 'target_version' => @proposal.target_version,
        'kind' => 'event', 'display' => @proposal.target_display
      }
    end

    def timestamp(value)
      value&.utc&.iso8601(value.usec.zero? ? 0 : 6)
    end
  end
end
