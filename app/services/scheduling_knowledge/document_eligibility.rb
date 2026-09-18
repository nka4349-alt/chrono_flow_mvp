# frozen_string_literal: true

module SchedulingKnowledge
  # Metadata eligibility only. A true result never establishes Hard applicability.
  class DocumentEligibility
    RECENT_SECONDS = 90 * 86_400
    RECONFIRM_SECONDS = 180 * 86_400

    def self.call(document:, scope:, place_ref:, target_start_at:, target_end_at:, now: Time.current)
      return false unless scope.is_a?(AccessScope) && document.is_a?(KnowledgeDocument) && document.persisted?

      document = KnowledgeDocument.visible_to(tenant_scope_ref: scope.tenant_scope_ref,
                                               user_scope_ref: scope.user_scope_ref).find_by(id: document.id)
      return false unless document
      return false unless document.status == 'active' && document.deleted_at.nil?
      return false unless document.place_ref == place_ref
      return false unless [target_start_at, target_end_at, now].all? { |time| time.is_a?(Time) || time.is_a?(ActiveSupport::TimeWithZone) }
      return false unless target_start_at < target_end_at

      # Read current link state; an association cached before invalidation must not grant access.
      link = PlaceKnowledgeLink.find_by(knowledge_document_id: document.id, active: true)
      return false unless link && link.tenant_scope_ref == document.tenant_scope_ref &&
                          link.user_scope_ref == document.user_scope_ref && link.place_ref == document.place_ref

      starts_at = document.valid_from
      ends_at = [document.valid_until, document.verified_until].compact.min
      if document.source_type == 'official_facility_document' && ends_at.nil?
        anchor = [document.issued_at, document.verified_at].compact.max
        return false unless anchor && anchor <= now

        ends_at = anchor + RECENT_SECONDS # Recent, undated official documents are Soft candidates only.
      end
      return false if starts_at && target_start_at < starts_at
      return false if ends_at && (now >= ends_at || target_end_at > ends_at)

      true
    end

    def self.reconfirmation_due?(document:, now: Time.current)
      document.source_type == 'user_note' && document.created_at &&
        now > document.created_at + RECONFIRM_SECONDS
    end
  end
end
