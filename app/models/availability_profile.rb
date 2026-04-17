# frozen_string_literal: true

class AvailabilityProfile < ApplicationRecord
  belongs_to :contact

  enum preference_kind: {
    available: 0,
    preferred: 1,
    unavailable: 2
  }, _default: :available

  enum source_kind: {
    manual: 0,
    inferred: 1,
    imported: 2
  }, _default: :manual

  DAYS = {
    0 => '日',
    1 => '月',
    2 => '火',
    3 => '水',
    4 => '木',
    5 => '金',
    6 => '土'
  }.freeze

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:weekday, :start_minute, :end_minute, :id) }

  validates :weekday, inclusion: { in: 0..6 }
  validates :start_minute, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: 24 * 60 }
  validates :end_minute, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 24 * 60 }
  validate :start_before_end

  def day_label
    DAYS[weekday.to_i] || weekday.to_s
  end

  def start_hhmm
    minutes_to_hhmm(start_minute)
  end

  def end_hhmm
    minutes_to_hhmm(end_minute)
  end

  private

  def start_before_end
    return if start_minute.blank? || end_minute.blank?
    return if start_minute.to_i < end_minute.to_i

    errors.add(:end_minute, 'must be greater than start_minute')
  end

  def minutes_to_hhmm(value)
    total = value.to_i
    hours = total / 60
    minutes = total % 60
    format('%<hours>02d:%<minutes>02d', hours:, minutes:)
  end
end
