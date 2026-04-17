# frozen_string_literal: true

class AiPolicyRun < ApplicationRecord
  REQUEST_KINDS = %w[chat_message refresh_only].freeze

  belongs_to :ai_conversation
  belongs_to :user
  belongs_to :group, optional: true

  has_many :ai_tool_invocations, dependent: :destroy
  has_many :ai_recommendation_impressions, dependent: :destroy

  validates :scope_type, presence: true
  validates :provider, presence: true
  validates :request_kind, presence: true, inclusion: { in: REQUEST_KINDS }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
