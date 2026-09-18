# frozen_string_literal: true

require 'digest'
require 'securerandom'

module SchedulingKnowledge
  class DocumentRegistrar
    def self.call(scope:, place_ref:, source_type:, document_version:, title:, content:, source_timezone:,
                  language: 'ja', visibility: 'private', status: 'draft', knowledge_requirement: 'optional',
                  issued_at: nil, valid_from: nil, valid_until: nil, verified_at: nil, verified_until: nil,
                  series_ref: nil)
      raise ArgumentError, 'trusted scope is required' unless scope.is_a?(AccessScope)
      raise ArgumentError, 'initial status must be draft or active' unless %w[draft active].include?(status)
      unless place_ref.is_a?(String) && AccessScope::REFERENCE.match?(place_ref)
        raise ArgumentError, 'a canonical place reference is required'
      end

      canonical = CanonicalText.normalize(content)
      chunks = Chunker.call(canonical_text: canonical)
      validity = ValidityNormalizer.call(source_timezone: source_timezone, issued_at: issued_at,
                                         valid_from: valid_from, valid_until: valid_until,
                                         verified_at: verified_at, verified_until: verified_until)
      KnowledgeDocument.transaction do
        if series_ref
          lineage = scope.owned_documents.where(series_ref: series_ref)
          expected = { place_ref: place_ref, source_type: source_type, visibility: visibility }
          unless lineage.exists? && lineage.where.not(expected).none?
            raise ArgumentError, 'document series identity cannot be rebound'
          end
        end
        document = KnowledgeDocument.create!(
          tenant_scope_ref: scope.tenant_scope_ref, user_scope_ref: scope.user_scope_ref,
          place_ref: place_ref, source_type: source_type, visibility: visibility,
          document_version: document_version, series_ref: series_ref || "kseries_#{SecureRandom.uuid}",
          title: title, language: language, status: status, canonical_text: canonical,
          content_sha256: Digest::SHA256.hexdigest(canonical), source_sha256: Digest::SHA256.hexdigest(content),
          **validity
        )
        chunks.each { |chunk| document.knowledge_chunks.create!(**chunk) }
        document.create_place_knowledge_link!(tenant_scope_ref: scope.tenant_scope_ref,
                                               user_scope_ref: scope.user_scope_ref, place_ref: place_ref,
                                               knowledge_requirement: knowledge_requirement, active: true)
        document
      end
    end
  end
end
