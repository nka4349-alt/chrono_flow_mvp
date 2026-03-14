# frozen_string_literal: true

class Friendship < ApplicationRecord
  belongs_to :user
  belongs_to :friend, class_name: 'User'

  validates :user_id, presence: true
  validates :friend_id, presence: true
  validates :user_id, uniqueness: { scope: :friend_id }
  validate :different_users

  before_validation :normalize_pair

  scope :for_user, ->(user_id) {
    where('user_id = :id OR friend_id = :id', id: user_id)
  }

  def self.connected?(u1, u2)
    return false if u1.blank? || u2.blank?

    a_id, b_id = [u1.id, u2.id].map(&:to_i).sort
    exists?(user_id: a_id, friend_id: b_id)
  end

  def includes_user?(u)
    return false unless u
    [user_id, friend_id].map(&:to_i).include?(u.id.to_i)
  end

  def peer_for(u)
    return nil unless u
    return friend if user_id.to_i == u.id.to_i
    return user if friend_id.to_i == u.id.to_i

    nil
  end

  private

  def normalize_pair
    return if user_id.blank? || friend_id.blank?

    a_id, b_id = [user_id, friend_id].map(&:to_i).sort
    self.user_id = a_id
    self.friend_id = b_id
  end

  def different_users
    return if user_id.blank? || friend_id.blank?
    return unless user_id.to_i == friend_id.to_i

    errors.add(:friend_id, 'must be different from user')
  end
end
