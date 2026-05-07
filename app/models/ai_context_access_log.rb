# frozen_string_literal: true

class AiContextAccessLog < ApplicationRecord
  belongs_to :user
  belongs_to :event, optional: true
  belongs_to :group, optional: true

  validates :permission_used, presence: true
  validates :ai_context_mode, presence: true
  validates :request_id, presence: true
end
