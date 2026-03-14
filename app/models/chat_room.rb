# frozen_string_literal: true

class ChatRoom < ApplicationRecord
  belongs_to :chatable, polymorphic: true

  has_many :messages, dependent: :destroy

  validates :chatable_id, uniqueness: { scope: :chatable_type }
end
