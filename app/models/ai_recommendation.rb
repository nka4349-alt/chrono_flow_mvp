# frozen_string_literal: true

class AiRecommendation < ApplicationRecord
  KINDS = %w[draft_event group_event_copy].freeze

  belongs_to :ai_conversation
  belongs_to :user
  belongs_to :group, optional: true
  belongs_to :source_event, class_name: 'Event', optional: true
  belongs_to :created_event, class_name: 'Event', optional: true

  has_many :ai_recommendation_feedbacks, dependent: :destroy
  has_many :ai_recommendation_impressions, dependent: :nullify

  enum status: {
    pending: 0,
    accepted_copy: 1,
    dismissed: 2,
    later: 3,
    archived: 4
  }, _default: :pending

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :title, presence: true
  validate :end_after_start

  scope :active_for_display, -> { where(status: [statuses[:pending], statuses[:later]]).order(created_at: :desc, id: :desc) }

  def draft_event?
    kind == 'draft_event'
  end

  def group_event_copy?
    kind == 'group_event_copy'
  end

  private

  def end_after_start
    return if start_at.blank? || end_at.blank?
    return if end_at > start_at

    errors.add(:end_at, 'must be later than start_at')
  end
end
