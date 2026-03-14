# frozen_string_literal: true

module Api
  # Event chat messages (ChatRoom chatable: Event)
  #
  # Routes (added by patcher):
  #   GET  /api/events/:event_id/chat_messages
  #   POST /api/events/:event_id/chat_messages
  class EventChatMessagesController < BaseController
    before_action :set_event
    before_action :authorize_event!

    def index
      room = ChatRoom.find_or_create_by!(chatable: @event)
      limit = (params[:limit].presence || 80).to_i
      limit = [[limit, 1].max, 200].min

      messages = room.messages.includes(:user).order(created_at: :desc).limit(limit).reverse

      render json: {
        chat_room_id: room.id,
        messages: messages.map { |m| serialize_message(m) }
      }
    end

    def create
      room = ChatRoom.find_or_create_by!(chatable: @event)
      body = params[:body].to_s.strip
      return render(json: { error: 'body is required' }, status: :unprocessable_entity) if body.blank?

      message = room.messages.create!(user: current_user, body: body)

      render json: {
        chat_room_id: room.id,
        message: serialize_message(message)
      }, status: :created
    end

    private

    def set_event
      @event = Event.find(params[:event_id])
    end

    def authorize_event!
      return if can_view_event?(@event)

      render json: { error: 'forbidden' }, status: :forbidden
    end

    # NOTE: We keep this permissive enough for MVP.
    # - creator can view
    # - participant can view
    # - member of any group the event is linked to can view
    def can_view_event?(event)
      uid = current_user.id

      if event.respond_to?(:created_by_id) && event.created_by_id.present?
        return true if event.created_by_id == uid
      end

      if defined?(EventParticipant)
        return true if EventParticipant.exists?(event_id: event.id, user_id: uid)
      end

      if defined?(EventGroup) && defined?(GroupMember)
        group_ids = EventGroup.where(event_id: event.id).pluck(:group_id)
        return true if group_ids.any? && GroupMember.exists?(group_id: group_ids, user_id: uid)
      end

      if event.respond_to?(:group_id) && event.group_id.present? && defined?(GroupMember)
        return true if GroupMember.exists?(group_id: event.group_id, user_id: uid)
      end

      false
    end

    def serialize_message(message)
      u = message.user
      name = if u.respond_to?(:display_name)
               u.display_name
             elsif u.respond_to?(:name)
               u.name
             elsif u.respond_to?(:email)
               u.email
             else
               'user'
             end

      {
        id: message.id,
        body: message.body,
        created_at: message.created_at&.iso8601,
        user: {
          id: u.id,
          name: name
        }
      }
    end
  end
end
