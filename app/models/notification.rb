# frozen_string_literal: true

class Notification < ApplicationRecord
  belongs_to :user

  enum kind: {
    event_changed: 0,
    event_request: 1,
    mention: 2,
    message: 3
  }, _default: :event_changed

  scope :unread, -> { where(read_at: nil) }
end
