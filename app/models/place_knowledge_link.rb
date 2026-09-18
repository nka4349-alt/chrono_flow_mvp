# frozen_string_literal: true

class PlaceKnowledgeLink < ApplicationRecord
  KNOWLEDGE_REQUIREMENTS = %w[none optional required].freeze
  IMMUTABLE_ATTRIBUTES = %w[knowledge_document_id tenant_scope_ref user_scope_ref place_ref].freeze

  belongs_to :knowledge_document, inverse_of: :place_knowledge_link

  scope :active, -> { where(active: true) }

  validates :knowledge_document_id, uniqueness: true
  validates :tenant_scope_ref, :user_scope_ref, :place_ref, presence: true, length: { maximum: 200 }
  validates :tenant_scope_ref, :user_scope_ref, :place_ref,
            format: { with: KnowledgeDocument::SCOPE_REFERENCE_PATTERN }
  validates :knowledge_requirement, inclusion: { in: KNOWLEDGE_REQUIREMENTS }
  validates :active, inclusion: { in: [true, false] }
  validate :validate_document_binding
  validate :validate_immutable_binding, on: :update

  private

  def validate_document_binding
    return unless knowledge_document

    %w[tenant_scope_ref user_scope_ref place_ref].each do |attribute|
      errors.add(attribute, 'must match the document owner and place') unless public_send(attribute) == knowledge_document.public_send(attribute)
    end
  end

  def validate_immutable_binding
    IMMUTABLE_ATTRIBUTES.each do |attribute|
      errors.add(attribute, 'is immutable') if will_save_change_to_attribute?(attribute)
    end
  end
end
