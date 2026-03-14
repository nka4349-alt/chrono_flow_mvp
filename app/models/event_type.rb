# frozen_string_literal: true

class EventType < ApplicationRecord
  belongs_to :user
  has_many :events, dependent: :nullify

  validates :name, presence: true

  # color は任意（例: "#3b82f6"）
end
