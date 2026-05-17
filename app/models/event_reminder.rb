# frozen_string_literal: true

class EventReminder < ApplicationRecord
  belongs_to :user
  belongs_to :event

  enum status: {
    pending: 0,
    delivered: 1,
    cancelled: 2
  }, _default: :pending

  validates :remind_at, presence: true
  validates :minutes_before, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :due, ->(now = Time.current) { pending.where('remind_at <= ?', now) }
  scope :upcoming, ->(now = Time.current) { pending.where('remind_at > ?', now) }

  def self.deliver_due_for_user!(user, now: Time.current)
    where(user: user).due(now).includes(:event).find_each do |reminder|
      reminder.deliver!
    end
  end

  def deliver!
    return if delivered? || cancelled?

    Notification.create!(
      user: user,
      kind: :event_reminder,
      payload: {
        event_id: event_id,
        event_title: event&.title,
        event_start_at: event&.start_at&.iso8601,
        event_end_at: event&.end_at&.iso8601,
        all_day: !!event&.try(:all_day),
        remind_at: remind_at&.iso8601,
        minutes_before: minutes_before
      }
    )

    update!(status: :delivered, delivered_at: Time.current)
  end
end
