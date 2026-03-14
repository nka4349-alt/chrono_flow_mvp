# frozen_string_literal: true

class EventShare < ApplicationRecord
  belongs_to :event
  belongs_to :from_user, class_name: 'User'
  belongs_to :to_group, class_name: 'Group'

  validates :action, presence: true
end
