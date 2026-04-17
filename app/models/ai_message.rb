# frozen_string_literal: true

class AiMessage < ApplicationRecord
  belongs_to :ai_conversation

  enum role: { user: 0, assistant: 1, system: 2 }, _default: :user

  validates :body, presence: true

  scope :chronological, -> { order(created_at: :asc, id: :asc) }
end
