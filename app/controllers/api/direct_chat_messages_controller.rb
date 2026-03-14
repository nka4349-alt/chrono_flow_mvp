# frozen_string_literal: true

module Api
  # Direct chat messages (ChatRoom chatable: DirectChat)
  #
  # Routes (added by patcher):
  #   GET  /api/direct_chats/:id/chat_messages
  #   POST /api/direct_chats/:id/chat_messages
  class DirectChatMessagesController < BaseController
    before_action :set_direct_chat
    before_action :authorize_participant!

    def index
      room = ChatRoom.find_or_create_by!(chatable: @direct_chat)
      limit = (params[:limit].presence || 80).to_i
      limit = [[limit, 1].max, 200].min

      messages = room.messages.includes(:user).order(created_at: :desc).limit(limit).reverse

      render json: {
        chat_room_id: room.id,
        messages: messages.map { |m| serialize_message(m) }
      }
    end

    def create
      room = ChatRoom.find_or_create_by!(chatable: @direct_chat)
      body = params[:body].to_s.strip
      return render(json: { error: 'body is required' }, status: :unprocessable_entity) if body.blank?

      message = room.messages.create!(user: current_user, body: body)

      render json: {
        chat_room_id: room.id,
        message: serialize_message(message)
      }, status: :created
    end

    private

    def set_direct_chat
      @direct_chat = DirectChat.find(params[:id])
    end

    def authorize_participant!
      uid = current_user.id

      a_id = @direct_chat.respond_to?(:user_a_id) ? @direct_chat.user_a_id : nil
      b_id = @direct_chat.respond_to?(:user_b_id) ? @direct_chat.user_b_id : nil

      ok = [a_id, b_id].compact.map(&:to_i).include?(uid.to_i)
      return if ok

      render json: { error: 'forbidden' }, status: :forbidden
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
