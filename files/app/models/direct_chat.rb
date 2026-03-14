# frozen_string_literal: true

class DirectChat < ApplicationRecord
  belongs_to :user_a, class_name: 'User'
  belongs_to :user_b, class_name: 'User'

  has_one :chat_room, as: :chatable, dependent: :destroy

  validates :user_a_id, presence: true
  validates :user_b_id, presence: true
  validates :user_b_id, uniqueness: { scope: :user_a_id }
  validate :ordered_pair
  validate :not_self

  # Find or create a direct chat room between two users.
  def self.between!(u1, u2)
    a_id, b_id = [u1.id, u2.id].sort
    find_or_create_by!(user_a_id: a_id, user_b_id: b_id)
  end

  private

  def ordered_pair
    return if user_a_id.blank? || user_b_id.blank?
    errors.add(:user_a_id, 'must be smaller than user_b_id') unless user_a_id < user_b_id
  end

  def not_self
    errors.add(:user_b_id, 'cannot be yourself') if user_a_id.present? && user_b_id == user_a_id
  end
end
