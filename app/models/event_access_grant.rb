# frozen_string_literal: true

class EventAccessGrant < ApplicationRecord
  PERMISSIONS = %w[free_busy title_time detail comment edit admin].freeze
  PRINCIPAL_TYPES = %w[User Group].freeze

  belongs_to :event
  belongs_to :granted_by, class_name: 'User', optional: true

  validates :principal_type, presence: true, inclusion: { in: PRINCIPAL_TYPES }
  validates :principal_id, presence: true
  validates :permission, presence: true, inclusion: { in: PERMISSIONS }
  validates :event_id, uniqueness: { scope: %i[principal_type principal_id] }

  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }
end
