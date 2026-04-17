# frozen_string_literal: true

class AiConversation < ApplicationRecord
  SCOPE_TYPES = %w[home group].freeze

  belongs_to :user
  belongs_to :group, optional: true

  has_many :ai_messages, dependent: :destroy
  has_many :ai_recommendations, dependent: :destroy
  has_many :ai_policy_runs, dependent: :destroy
  has_many :ai_tool_invocations, through: :ai_policy_runs
  has_many :ai_recommendation_impressions, through: :ai_policy_runs

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validate :group_presence_matches_scope

  scope :recently_used, -> { order(last_used_at: :desc, created_at: :desc) }

  def home?
    scope_type == 'home'
  end

  def group?
    scope_type == 'group'
  end

  private

  def group_presence_matches_scope
    if home? && group_id.present?
      errors.add(:group_id, 'must be blank for home conversations')
    elsif group? && group_id.blank?
      errors.add(:group_id, 'is required for group conversations')
    end
  end
end
