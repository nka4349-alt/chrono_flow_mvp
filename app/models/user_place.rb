# frozen_string_literal: true

class UserPlace < ApplicationRecord
  KINDS = %w[home work station gym hospital client school other].freeze

  belongs_to :user

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:kind, :label, :id) }

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :label, presence: true
  validates :place_name, presence: true
end
