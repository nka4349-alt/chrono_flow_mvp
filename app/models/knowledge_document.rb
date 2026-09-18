# frozen_string_literal: true

require 'digest'
require 'securerandom'

class KnowledgeDocument < ApplicationRecord
  SOURCE_TYPES = %w[official_facility_document user_note].freeze
  STATUSES = %w[draft active superseded revoked expired].freeze
  VISIBILITIES = %w[private tenant].freeze
  TERMINAL_STATUSES = %w[superseded revoked expired].freeze
  TEMPORAL_KEYS = %w[issued_at valid_from valid_until verified_at verified_until].freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/
  SCOPE_REFERENCE_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  IMMUTABLE_ATTRIBUTES = %w[
    public_id series_ref document_version tenant_scope_ref user_scope_ref place_ref
    source_type visibility title language canonical_text content_sha256 source_sha256
    source_timezone source_temporal_json issued_at valid_from valid_until verified_at verified_until
  ].freeze

  self.filter_attributes += %i[canonical_text title source_temporal_json]

  has_many :knowledge_chunks, dependent: :destroy, inverse_of: :knowledge_document
  has_one :place_knowledge_link, dependent: :destroy, inverse_of: :knowledge_document

  scope :active_version, -> { where(status: 'active', deleted_at: nil) }
  scope :owned_by, ->(tenant_scope_ref:, user_scope_ref:) {
    where(tenant_scope_ref: tenant_scope_ref, user_scope_ref: user_scope_ref)
  }
  scope :visible_to, ->(tenant_scope_ref:, user_scope_ref:) {
    if tenant_scope_ref.blank? || user_scope_ref.blank?
      none
    else
      where(tenant_scope_ref: tenant_scope_ref).where(
        'knowledge_documents.user_scope_ref = :owner OR ' \
        '(knowledge_documents.source_type = :official AND knowledge_documents.visibility = :shared)',
        owner: user_scope_ref, official: 'official_facility_document', shared: 'tenant'
      )
    end
  }

  before_validation :assign_public_id, on: :create

  validates :public_id, presence: true, uniqueness: true,
                        format: { with: /\Akdoc_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ }
  validates :series_ref, :document_version, :tenant_scope_ref, :user_scope_ref, :place_ref,
            presence: true, length: { maximum: 200 }
  validates :tenant_scope_ref, :user_scope_ref, :place_ref, format: { with: SCOPE_REFERENCE_PATTERN }
  validates :document_version, uniqueness: { scope: %i[tenant_scope_ref user_scope_ref series_ref] }
  validates :title, presence: true, length: { maximum: 500 }
  validates :language, presence: true, length: { maximum: 32 }
  validates :source_timezone, presence: true, length: { maximum: 100 }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :canonical_text, presence: true
  validates :content_sha256, :source_sha256, format: { with: SHA256_PATTERN }
  validate :validate_canonical_text
  validate :validate_source_metadata
  validate :validate_temporal_bounds
  validate :validate_immutable_identity, on: :update
  validate :validate_lifecycle, on: :update

  private

  def assign_public_id
    self.public_id ||= "kdoc_#{SecureRandom.uuid}"
  end

  def validate_canonical_text
    text = canonical_text
    return unless text.is_a?(String)

    unless text.encoding == Encoding::UTF_8 && text.valid_encoding? && !text.match?(/[\r\u0000]/)
      errors.add(:canonical_text, 'must be canonical UTF-8 text with LF line endings and no NUL')
      return
    end

    errors.add(:content_sha256, 'does not match canonical text') unless Digest::SHA256.hexdigest(text) == content_sha256
  end

  def validate_source_metadata
    errors.add(:visibility, 'must be private for user notes') if source_type == 'user_note' && visibility != 'private'
    if !source_temporal_json.is_a?(Hash) || (source_temporal_json.keys - TEMPORAL_KEYS).any? ||
       source_temporal_json.values.any? { |value| !value.nil? && !value.is_a?(String) }
      errors.add(:source_temporal_json, 'must contain only original temporal strings')
    end
    TZInfo::Timezone.get(source_timezone) if source_timezone.present?
  rescue TZInfo::InvalidTimezoneIdentifier
    errors.add(:source_timezone, 'must be an IANA timezone')
  end

  def validate_temporal_bounds
    if valid_from && valid_until && valid_until <= valid_from
      errors.add(:valid_until, 'must be after valid_from')
    end
    if verified_at && verified_until && verified_until <= verified_at
      errors.add(:verified_until, 'must be after verified_at')
    end
    effective_end = [valid_until, verified_until].compact.min
    if valid_from && effective_end && valid_from >= effective_end
      errors.add(:valid_from, 'must precede the effective expiry')
    end
  end

  def validate_immutable_identity
    IMMUTABLE_ATTRIBUTES.each do |attribute|
      errors.add(attribute, 'is immutable; register a new version') if will_save_change_to_attribute?(attribute)
    end
  end

  def validate_lifecycle
    if will_save_change_to_status?
      previous = status_in_database
      if TERMINAL_STATUSES.include?(previous) || (previous == 'active' && status == 'draft')
        errors.add(:status, 'cannot reactivate or rewind this version')
      end
    end
    if deleted_at_in_database && will_save_change_to_deleted_at?
      errors.add(:deleted_at, 'cannot clear or change a deletion tombstone')
    end
    errors.add(:status, 'cannot activate a deleted version') if deleted_at && status == 'active' && will_save_change_to_status?
  end
end
