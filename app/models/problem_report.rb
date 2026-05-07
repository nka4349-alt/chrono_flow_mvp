# frozen_string_literal: true

class ProblemReport < ApplicationRecord
  STATUSES = %w[open investigating resolved closed].freeze
  PRIORITIES = %w[low normal high urgent].freeze
  CATEGORIES = %w[general ai_schedule ai_failure calendar permission account billing other].freeze

  belongs_to :user
  belongs_to :ai_usage_event, optional: true
  belongs_to :ai_recommendation, optional: true

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :priority, presence: true, inclusion: { in: PRIORITIES }
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :subject, presence: true, length: { maximum: 160 }
  validates :body, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :open_recent, -> { where(status: %w[open investigating]).recent_first }

  def resolved?
    status.in?(%w[resolved closed])
  end
end
