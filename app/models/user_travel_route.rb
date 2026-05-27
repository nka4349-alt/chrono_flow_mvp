# frozen_string_literal: true

class UserTravelRoute < ApplicationRecord
  TRANSPORT_MODES = %w[train car walk bus public_transport unknown].freeze

  belongs_to :user

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:origin_name, :destination_name, :id) }

  validates :origin_name, presence: true
  validates :destination_name, presence: true
  validates :travel_minutes, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 300 }
  validates :arrival_buffer_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 180 }, allow_nil: true
  validates :transport_mode, inclusion: { in: TRANSPORT_MODES }, allow_blank: true
end
