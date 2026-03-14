# frozen_string_literal: true

module Api
  class ChatMessagesController < BaseController
    before_action :resolve_context!

    # GET /api/.../chat_messages?limit=80
    def index
      limit = params[:limit].presence&.to_i || 80

      messages = @chat_room.messages
                           .includes(:user)
                           .order(created_at: :desc)
                           .limit(limit)
                           .reverse

      render json: {
        scope: @chat_scope,
        chat_room_id: @chat_room.id,
        messages: messages.map { |m| serialize_message(m) }
      }
    end

    # POST /api/.../chat_messages { body: "..." }
    def create
      body = params[:body].to_s.strip
      return render json: { error: 'body is required' }, status: :unprocessable_entity if body.blank?

      message = @chat_room.messages.create!(user: current_user, body: body)

      render json: { message: serialize_message(message) }, status: :created
    end

    private

    def resolve_context!
      if params[:group_id].present?
        resolve_group_context!
      elsif params[:event_id].present?
        resolve_event_context!
      elsif params[:user_id].present?
        resolve_direct_context!
      else
        render json: { error: 'chat context missing' }, status: :bad_request
      end
    end

    def resolve_group_context!
      group = Group.find(params[:group_id])

      unless GroupMember.exists?(group_id: group.id, user_id: current_user.id)
        return render json: { error: 'forbidden' }, status: :forbidden
      end

      @chat_scope = { type: 'group', id: group.id, name: group.name }
      @chat_room = ChatRoom.find_or_create_by!(chatable: group)
    end

    def resolve_event_context!
      event = Event.find(params[:event_id])

      # Read allowed if: creator OR participant OR member of any group linked to the event
      allowed = (event.created_by_id == current_user.id) ||
                EventParticipant.exists?(event_id: event.id, user_id: current_user.id) ||
                GroupMember.joins('INNER JOIN event_groups ON event_groups.group_id = group_members.group_id')
                          .where('event_groups.event_id = ? AND group_members.user_id = ?', event.id, current_user.id)
                          .exists?

      return render json: { error: 'forbidden' }, status: :forbidden unless allowed

      @chat_scope = { type: 'event', id: event.id, name: event.title }
      @chat_room = ChatRoom.find_or_create_by!(chatable: event)
    end

    def resolve_direct_context!
      other = User.find(params[:user_id])
      return render json: { error: 'cannot chat with yourself' }, status: :unprocessable_entity if other.id == current_user.id

      allowed = Friendship.exists?(user_id: current_user.id, friend_id: other.id) ||
                Friendship.exists?(user_id: other.id, friend_id: current_user.id) ||
                GroupMember.where(user_id: current_user.id)
                          .where(group_id: GroupMember.where(user_id: other.id).select(:group_id))
                          .exists?

      return render json: { error: 'forbidden' }, status: :forbidden unless allowed

      direct = DirectChat.between!(current_user, other)
      @chat_scope = { type: 'direct', id: other.id, name: other.name }
      @chat_room = ChatRoom.find_or_create_by!(chatable: direct)
    end

    def serialize_message(m)
      {
        id: m.id,
        body: m.body,
        created_at: m.created_at.iso8601,
        user: {
          id: m.user_id,
          name: m.user&.name
        }
      }
    end
  end
end
