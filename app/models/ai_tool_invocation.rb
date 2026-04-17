# frozen_string_literal: true

class AiToolInvocation < ApplicationRecord
  belongs_to :ai_policy_run
  belongs_to :ai_conversation
  belongs_to :user

  validates :tool_name, presence: true
  validates :status, presence: true
  validates :position, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  scope :ordered, -> { order(position: :asc, id: :asc) }
end
