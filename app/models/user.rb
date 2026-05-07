# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password

  has_many :created_events, class_name: 'Event', foreign_key: :created_by_id, inverse_of: :created_by, dependent: :nullify

  has_many :event_participants, dependent: :destroy
  has_many :participating_events, through: :event_participants, source: :event

  has_many :group_members, dependent: :destroy
  has_many :groups, through: :group_members

  has_many :contacts, dependent: :destroy
  has_many :availability_profiles, through: :contacts
  has_many :linked_contacts, class_name: 'Contact', foreign_key: :linked_user_id, inverse_of: :linked_user, dependent: :nullify

  has_many :messages, dependent: :nullify
  has_many :notifications, dependent: :destroy

  has_many :ai_conversations, dependent: :destroy
  has_many :ai_recommendations, dependent: :destroy
  has_many :ai_recommendation_feedbacks, dependent: :destroy
  has_many :ai_policy_runs, dependent: :destroy
  has_many :ai_tool_invocations, dependent: :destroy
  has_many :ai_recommendation_impressions, dependent: :destroy
  has_many :ai_usage_events, dependent: :destroy
  has_many :problem_reports, dependent: :destroy

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true

  def display_name
    name.presence || email
  end

  def admin?
    return true if has_attribute?(:admin) && ActiveModel::Type::Boolean.new.cast(self[:admin])

    ENV.fetch('CHRONOFLOW_ADMIN_EMAILS', '')
       .split(',')
       .map { |value| value.to_s.strip.downcase }
       .reject(&:blank?)
       .include?(email.to_s.downcase)
  end
end
