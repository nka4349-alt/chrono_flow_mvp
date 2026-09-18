# frozen_string_literal: true

module SchedulingKnowledge
  class DocumentInvalidator
    REASONS = %w[superseded revoked expired deleted].freeze

    def self.call(scope:, document_id:, reason:, now: Time.current)
      raise ArgumentError, 'trusted scope is required' unless scope.is_a?(AccessScope)
      raise ArgumentError, 'unknown invalidation reason' unless REASONS.include?(reason)
      unless now.is_a?(Time) || now.is_a?(ActiveSupport::TimeWithZone)
        raise ArgumentError, 'a server timestamp is required'
      end

      document = scope.find_owned!(document_id)
      document.with_lock do
        invalidate_locked!(document, reason: reason, now: now)
      end
      document
    end

    def self.invalidate_locked!(document, reason:, now:)
      if reason == 'deleted'
        document.update!(deleted_at: now) unless document.deleted_at
      elsif %w[draft active].include?(document.status)
        document.update!(status: reason)
      elsif document.status != reason
        raise ArgumentError, 'terminal document cannot change lifecycle'
      end
      document.knowledge_chunks.where(invalidated_at: nil).update_all(invalidated_at: now, updated_at: now)
      document.place_knowledge_link&.update!(active: false)
    end
    private_class_method :invalidate_locked!
  end
end
