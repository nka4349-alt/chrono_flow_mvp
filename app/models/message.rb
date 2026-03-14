# frozen_string_literal: true

class Message < ApplicationRecord
  belongs_to :chat_room
  belongs_to :user

  validates :body, presence: true

  scope :recent, ->(limit = 50) { order(created_at: :desc).limit(limit).reverse }
end
