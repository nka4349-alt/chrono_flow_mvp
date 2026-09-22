# frozen_string_literal: true

class SecretaryMutationProposal < ApplicationRecord
  PRIVATE_ATTRIBUTES = %i[
    home_subject identity_issuer identity_subject messages question candidate_mappings
    target_ref target_event_id target_version relationship_fingerprint target_display
    before_snapshot after_snapshot planned_related_effects content_digest
    idempotency_key_digest receipt refresh_scope
  ].freeze

  self.filter_attributes += PRIVATE_ATTRIBUTES

  belongs_to :user
  has_many :secretary_mutation_audits, dependent: :destroy
  has_many :secretary_mutation_outbox_entries, dependent: :destroy

  OPERATIONS = %w[event.update event.delete].freeze
  STATUSES = %w[needs_target needs_clarification ready rejected completed completed_tombstone cancelled expired conflicted].freeze
  TERMINAL_STATUSES = %w[rejected completed completed_tombstone cancelled expired conflicted].freeze

  validates :public_id, :home_subject, :identity_issuer, :identity_subject,
    :operation, :locale, :time_zone, :status, :execution_expires_at, :status_available_until, presence: true
  validates :operation, inclusion: { in: OPERATIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def executed?
    completed_at.present? && idempotency_key_digest.present? && result_id.present? && receipt.present?
  end
end
