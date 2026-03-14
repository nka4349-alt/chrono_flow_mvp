# frozen_string_literal: true

class Friendship < ApplicationRecord
  belongs_to :user
  belongs_to :friend, class_name: 'User'

  validates :user_id, presence: true
  validates :friend_id, presence: true
  validates :friend_id, uniqueness: { scope: :user_id }
  validate :not_self

  private

  def not_self
    errors.add(:friend_id, 'cannot be yourself') if user_id.present? && friend_id == user_id
  end
end
