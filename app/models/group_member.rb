# frozen_string_literal: true

class GroupMember < ApplicationRecord
  belongs_to :group
  belongs_to :user

  enum role: { member: 0, admin: 1 }, _default: :member

  validates :user_id, uniqueness: { scope: :group_id }

  def can_manage_events?
    admin? || group.owner_id == user_id
  end
end
