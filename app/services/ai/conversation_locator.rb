# frozen_string_literal: true

module Ai
  class ConversationLocator
    def self.call(...)
      new(...).call
    end

    def initialize(user:, scope_type:, group_id: nil)
      @user = user
      @scope_type = scope_type.to_s.presence || 'home'
      @group_id = group_id.presence
    end

    def call
      case @scope_type
      when 'group'
        locate_group_conversation
      when 'home'
        locate_home_conversation
      else
        raise ArgumentError, 'invalid scope'
      end
    end

    private

    attr_reader :user

    def locate_home_conversation
      AiConversation.find_or_create_by!(user: user, scope_type: 'home', group_id: nil).tap do |conversation|
        conversation.touch(:last_used_at)
      end
    end

    def locate_group_conversation
      raise ActiveRecord::RecordNotFound, 'group_id is required' if @group_id.blank?

      group = Group.find(@group_id)
      allowed = GroupMember.exists?(group_id: group.id, user_id: user.id)
      allowed ||= group.respond_to?(:owner_id) && group.owner_id.to_i == user.id.to_i
      raise StandardError, 'Forbidden' unless allowed

      AiConversation.find_or_create_by!(user: user, scope_type: 'group', group: group).tap do |conversation|
        conversation.touch(:last_used_at)
      end
    end
  end
end
