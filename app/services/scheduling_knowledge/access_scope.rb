# frozen_string_literal: true

module SchedulingKnowledge
  # Construct only from the authenticated server context, never model arguments.
  class AccessScope
    class Denied < StandardError; end

    REFERENCE = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
    attr_reader :tenant_scope_ref, :user_scope_ref

    def initialize(tenant_scope_ref:, user_scope_ref:)
      @tenant_scope_ref = reference!(tenant_scope_ref).dup.freeze
      @user_scope_ref = reference!(user_scope_ref).dup.freeze
      freeze
    end

    def owned_documents
      KnowledgeDocument.where(tenant_scope_ref: tenant_scope_ref, user_scope_ref: user_scope_ref)
    end

    def readable?(document)
      document.tenant_scope_ref == tenant_scope_ref &&
        (document.user_scope_ref == user_scope_ref ||
          (document.source_type == 'official_facility_document' && document.visibility == 'tenant'))
    end

    def find_owned!(public_id)
      raise Denied, 'document is unavailable in this scope' unless public_id.is_a?(String)

      owned_documents.find_by(public_id: public_id) || raise(Denied, 'document is unavailable in this scope')
    end

    private

    def reference!(value)
      raise ArgumentError, 'a canonical scope reference is required' unless value.is_a?(String) && REFERENCE.match?(value)

      value
    end
  end
end
