# frozen_string_literal: true

class EventRequest < ApplicationRecord
  belongs_to :event
  belongs_to :group

  belongs_to :target_user, class_name: 'User'
  belongs_to :requested_by, class_name: 'User'

  enum status: { pending: 0, approved: 1, rejected: 2 }, _default: :pending

  validates :event_id, :group_id, :target_user_id, :requested_by_id, presence: true

  # v1: 1イベント x 1ユーザー につき1レコード（履歴は将来拡張）
  validates :target_user_id, uniqueness: { scope: :event_id }
end
