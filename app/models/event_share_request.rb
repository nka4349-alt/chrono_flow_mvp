# frozen_string_literal: true

class EventShareRequest < ApplicationRecord
  belongs_to :event
  belongs_to :requested_by, class_name: 'User'
  belongs_to :target, polymorphic: true
  belongs_to :responded_by, class_name: 'User', optional: true

  enum :status, { pending: 0, approved: 1, rejected: 2 }, _default: :pending

  validates :event_id, :requested_by_id, :target_type, :target_id, presence: true
  validates :target_type, inclusion: { in: %w[User Group] }

  def self.for_user(user)
    where(target_type: 'User', target_id: user.id)
  end

  def self.for_groups(group_ids)
    where(target_type: 'Group', target_id: group_ids)
  end
end
