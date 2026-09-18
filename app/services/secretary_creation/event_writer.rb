# frozen_string_literal: true

module SecretaryCreation
  class EventWriter
    def self.call(user:, details:)
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
  end
end
