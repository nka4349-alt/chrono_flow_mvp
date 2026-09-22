# frozen_string_literal: true

module SecretaryCreation
  class EventWriter
    def self.call(user:, details:)
      Contract.validate_details!(details, provider: 'chrono_flow')
      validate_canonical_text!(details.fetch('title'), required: true)
      validate_canonical_text!(details.fetch('location'), required: false)

      # Preserve the personal event + copied participant save convention used by
      # Api::AiRecommendationsController, without touching its conversation drafts.
      event = Event.create!(
        created_by: user, title: details.fetch('title'), description: details.fetch('description'),
        location: details.fetch('location'), start_at: Time.iso8601(details.fetch('start_at')),
        end_at: Time.iso8601(details.fetch('end_at')), all_day: details.fetch('all_day'), color: '#3b82f6'
      )
      EventParticipant.create!(event: event, user: user, source: :copied)
      event
    end

    def self.validate_canonical_text!(value, required:)
      raise Contract::Invalid unless value.is_a?(String) &&
        [Encoding::UTF_8, Encoding::US_ASCII].include?(value.encoding) && value.valid_encoding?

      canonical = value.encode(Encoding::UTF_8).gsub(/[\p{Cc}\p{Space}]+/u, ' ').strip
      raise Contract::Invalid unless value == canonical
      raise Contract::Invalid if required && canonical.empty?
    end
    private_class_method :validate_canonical_text!
  end
end
