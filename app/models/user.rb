# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password

  has_many :created_events, class_name: 'Event', foreign_key: :created_by_id, inverse_of: :created_by, dependent: :nullify

  has_many :event_participants, dependent: :destroy
  has_many :participating_events, through: :event_participants, source: :event

  has_many :group_members, dependent: :destroy
  has_many :groups, through: :group_members

  has_many :messages, dependent: :nullify
  has_many :notifications, dependent: :destroy
  validates :name, presence: true
  validates :email, presence: true, uniqueness: true

  def display_name
    name.presence || email
  end
end
