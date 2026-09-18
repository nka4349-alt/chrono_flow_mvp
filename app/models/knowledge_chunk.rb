# frozen_string_literal: true

require 'digest'
require 'securerandom'

class KnowledgeChunk < ApplicationRecord
  IMMUTABLE_ATTRIBUTES = %w[
    knowledge_document_id public_id sequence section_path_json page_number
    character_start character_end content content_sha256
  ].freeze

  self.filter_attributes += %i[content section_path_json]

  belongs_to :knowledge_document, inverse_of: :knowledge_chunks

  scope :available, -> {
    joins(knowledge_document: :place_knowledge_link)
      .merge(KnowledgeDocument.active_version)
      .where(invalidated_at: nil, place_knowledge_links: { active: true })
      .where('place_knowledge_links.tenant_scope_ref = knowledge_documents.tenant_scope_ref ' \
             'AND place_knowledge_links.user_scope_ref = knowledge_documents.user_scope_ref ' \
             'AND place_knowledge_links.place_ref = knowledge_documents.place_ref')
  }

  before_validation :assign_public_id, on: :create

  validates :public_id, presence: true, uniqueness: true,
                        format: { with: /\Akchunk_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/ }
  validates :sequence, numericality: { only_integer: true, greater_than_or_equal_to: 0 },
                       uniqueness: { scope: :knowledge_document_id }
  validates :page_number, numericality: { only_integer: true, greater_than: 0 }
  validates :character_start, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :character_end, numericality: { only_integer: true, greater_than: 0 }
  validates :character_start, uniqueness: { scope: %i[knowledge_document_id character_end] }
  validates :content, presence: true, length: { maximum: 1200 }
  validates :content_sha256, format: { with: KnowledgeDocument::SHA256_PATTERN }
  validate :validate_section_path
  validate :validate_exact_evidence
  validate :validate_immutable_evidence, on: :update

  private

  def assign_public_id
    self.public_id ||= "kchunk_#{SecureRandom.uuid}"
  end

  def validate_section_path
    unless section_path_json.is_a?(Array) && section_path_json.all? { |item| item.is_a?(String) && item.present? }
      errors.add(:section_path_json, 'must be an array of nonblank section labels')
    end
  end

  def validate_exact_evidence
    text = content
    return unless text.is_a?(String)

    unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
      errors.add(:content, 'must be UTF-8 text')
      return
    end
    errors.add(:content_sha256, 'does not match content') unless Digest::SHA256.hexdigest(text) == content_sha256
    return unless character_start.is_a?(Integer) && character_end.is_a?(Integer)

    if character_end <= character_start || character_end - character_start != text.length
      errors.add(:character_end, 'must delimit the exact half-open content interval')
      return
    end
    document_text = knowledge_document&.canonical_text
    unless document_text && document_text[character_start...character_end] == text && character_end <= document_text.length
      errors.add(:content, 'must match its exact canonical document slice')
    end
  end

  def validate_immutable_evidence
    IMMUTABLE_ATTRIBUTES.each do |attribute|
      errors.add(attribute, 'is immutable') if will_save_change_to_attribute?(attribute)
    end
    if invalidated_at_in_database && will_save_change_to_invalidated_at?
      errors.add(:invalidated_at, 'cannot clear or change an invalidation tombstone')
    end
  end
end
