# frozen_string_literal: true

class AiRecommendationFeedback < ApplicationRecord
  belongs_to :ai_recommendation
  belongs_to :ai_conversation
  belongs_to :user

  enum action: {
    accepted_copy: 0,
    later: 1,
    dismissed: 2
  }

  validates :action, presence: true
end
