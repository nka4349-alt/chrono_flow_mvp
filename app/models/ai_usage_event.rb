# frozen_string_literal: true

class AiUsageEvent < ApplicationRecord
  STATUSES = %w[success fallback failed timeout].freeze
  FAILURE_STATUSES = %w[failed timeout fallback].freeze

  belongs_to :user
  belongs_to :ai_conversation, optional: true
  belongs_to :ai_policy_run, optional: true
  belongs_to :group, optional: true

  has_many :problem_reports, dependent: :nullify

  validates :feature_key, presence: true
  validates :route, presence: true
  validates :provider, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :failures, -> { where(status: FAILURE_STATUSES) }
  scope :successful, -> { where(status: 'success') }
  scope :fallbacks, -> { where(status: 'fallback') }
  scope :failed, -> { where(status: 'failed') }

  def failed_like?
    FAILURE_STATUSES.include?(status.to_s)
  end
end
