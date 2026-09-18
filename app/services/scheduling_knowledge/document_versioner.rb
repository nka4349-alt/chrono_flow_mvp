# frozen_string_literal: true

module SchedulingKnowledge
  class DocumentVersioner
    MUTABLE_METADATA = %i[title language source_timezone issued_at valid_from valid_until verified_at verified_until].freeze

    def self.call(scope:, document_id:, document_version:, content:, **metadata)
      raise ArgumentError, 'trusted scope is required' unless scope.is_a?(AccessScope)
      raise ArgumentError, 'unknown version metadata' unless (metadata.keys - MUTABLE_METADATA).empty?

      current = scope.find_owned!(document_id)
      replacement = nil
      current.with_lock do
        raise ArgumentError, 'only an active undeleted document can be versioned' unless current.status == 'active' && current.deleted_at.nil?

        link = current.place_knowledge_link
        raise ArgumentError, 'an active place link is required' unless link&.active?

        inherited = current.source_temporal_json.symbolize_keys.slice(*ValidityNormalizer::FIELDS)
        inherited.merge!(title: current.title, language: current.language, source_timezone: current.source_timezone)
        DocumentInvalidator.call(scope: scope, document_id: current.public_id, reason: 'superseded')
        replacement = DocumentRegistrar.call(
          scope: scope, place_ref: current.place_ref, source_type: current.source_type,
          document_version: document_version, series_ref: current.series_ref, content: content,
          visibility: current.visibility, status: 'active', knowledge_requirement: link.knowledge_requirement,
          **inherited.merge(metadata)
        )
      end
      replacement
    end
  end
end
