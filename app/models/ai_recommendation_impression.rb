# frozen_string_literal: true

class AiRecommendationImpression < ApplicationRecord
  INTERACTION_LABELS = %w[accepted_copy later dismissed].freeze

  belongs_to :ai_policy_run
  belongs_to :ai_conversation
  belongs_to :ai_recommendation, optional: true
  belongs_to :user
  belongs_to :group, optional: true

  validates :kind, presence: true
  validates :recommendation_status, presence: true
  validates :rank_position, numericality: { greater_than: 0, only_integer: true }
  validates :interaction_label, inclusion: { in: INTERACTION_LABELS }, allow_blank: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
