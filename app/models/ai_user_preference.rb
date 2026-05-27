# frozen_string_literal: true

class AiUserPreference < ApplicationRecord
  VALUE_TYPES = %w[integer string boolean json].freeze

  belongs_to :user

  validates :key, presence: true, uniqueness: { scope: :user_id }
  validates :value, presence: true
  validates :value_type, inclusion: { in: VALUE_TYPES }, allow_blank: true
end
