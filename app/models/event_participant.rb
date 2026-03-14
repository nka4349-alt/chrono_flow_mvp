# frozen_string_literal: true

class EventParticipant < ApplicationRecord
  belongs_to :event
  belongs_to :user

  enum source: { linked: 0, copied: 1, requested: 2 }, _default: :linked

  validates :user_id, uniqueness: { scope: :event_id }
end
