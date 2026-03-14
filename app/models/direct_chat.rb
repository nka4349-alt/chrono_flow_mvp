# frozen_string_literal: true

class DirectChat < ApplicationRecord
  belongs_to :user_a, class_name: 'User'
  belongs_to :user_b, class_name: 'User'

  has_one :chat_room, as: :chatable, dependent: :destroy

  validates :user_a_id, presence: true
  validates :user_b_id, presence: true
  validates :user_a_id, uniqueness: { scope: :user_b_id }
  validate :different_users

  before_validation :normalize_pair

  def self.between!(u1, u2)
    a_id, b_id = [u1.id, u2.id].map(&:to_i).sort
    find_or_create_by!(user_a_id: a_id, user_b_id: b_id)
  end

  def participants
    [user_a, user_b]
  end

  def includes_user?(user)
    return false unless user
    [user_a_id, user_b_id].map(&:to_i).include?(user.id.to_i)
  end

  def peer_for(user)
    return nil unless user
    return user_b if user_a_id.to_i == user.id.to_i
    return user_a if user_b_id.to_i == user.id.to_i

    nil
  end

  private

  def normalize_pair
    return if user_a_id.blank? || user_b_id.blank?

    a_id, b_id = [user_a_id, user_b_id].map(&:to_i).sort
    self.user_a_id = a_id
    self.user_b_id = b_id
  end

  def different_users
    return if user_a_id.blank? || user_b_id.blank?
    return unless user_a_id.to_i == user_b_id.to_i

    errors.add(:user_b_id, 'must be different from user_a')
  end
end
