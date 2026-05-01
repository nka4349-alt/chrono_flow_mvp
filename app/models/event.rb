# frozen_string_literal: true

class Event < ApplicationRecord
  COLOR_PALETTE = %w[
    #ef4444
    #3b82f6
    #facc15
    #22c55e
    #06b6d4
    #ec4899
    #8b5cf6
    #f97316
    #84cc16
    #111827
  ].freeze

  belongs_to :created_by, class_name: 'User', inverse_of: :created_events

  belongs_to :event_type, optional: true

  belongs_to :parent, class_name: 'Event', optional: true
  has_many :children, class_name: 'Event', foreign_key: 'parent_id', dependent: :nullify

  has_many :event_groups, dependent: :destroy
  has_many :groups, through: :event_groups

  has_many :event_participants, dependent: :destroy
  has_many :participants, through: :event_participants, source: :user

  has_many :event_shares, dependent: :destroy
  has_many :event_requests, dependent: :destroy

  has_many :source_ai_recommendations,
           class_name: 'AiRecommendation',
           foreign_key: :source_event_id,
           inverse_of: :source_event,
           dependent: :nullify
  has_many :created_ai_recommendations,
           class_name: 'AiRecommendation',
           foreign_key: :created_event_id,
           inverse_of: :created_event,
           dependent: :nullify

  has_one :chat_room, as: :chatable, dependent: :destroy

  validates :title, presence: true
  validates :start_at, presence: true
  validates :end_at, presence: true
  validates :color, inclusion: { in: COLOR_PALETTE }, allow_blank: false

  before_validation :normalize_color
  before_destroy :nullify_ai_recommendation_event_references

  validate :end_after_start

  private

  def nullify_ai_recommendation_event_references
    return unless defined?(AiRecommendation)
    return unless ActiveRecord::Base.connection.data_source_exists?('ai_recommendations')

    columns = AiRecommendation.column_names
    touch_attrs = columns.include?('updated_at') ? { updated_at: Time.current } : {}

    if columns.include?('source_event_id')
      AiRecommendation.where(source_event_id: id).update_all({ source_event_id: nil }.merge(touch_attrs))
    end

    if columns.include?('created_event_id')
      AiRecommendation.where(created_event_id: id).update_all({ created_event_id: nil }.merge(touch_attrs))
    end
  end

  def normalize_color
    self.color = '#3b82f6' if color.blank?
    self.color = color.downcase if color.present?
  end

  def end_after_start
    return if start_at.blank? || end_at.blank?
    errors.add(:end_at, 'は開始時刻より後にしてください') if end_at < start_at
  end
end
