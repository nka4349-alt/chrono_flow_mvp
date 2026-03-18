# frozen_string_literal: true

module Api
  class ChatMessagesController < BaseController
    before_action :resolve_context!

    # GET /api/groups/:group_id/chat_messages?limit=80
    # GET /api/events/:event_id/chat_messages?limit=80
    def index
      limit = params[:limit].to_i
      limit = 80 if limit <= 0
      limit = 200 if limit > 200

      # 削除済みイベントなどで chat_room が無い場合は空を返す
      unless @chat_room
        return render json: {
          chat_room_id: nil,
          context: @context,
          messages: []
        }
      end

      messages = @chat_room.messages.includes(:user).order(created_at: :desc).limit(limit).to_a.reverse

      render json: {
        chat_room_id: @chat_room.id,
        context: @context,
        messages: messages.map { |m| serialize_message(m) }
      }
    end

    # POST /api/groups/:group_id/chat_messages
    # POST /api/events/:event_id/chat_messages
    def create
      return json_error('not found', status: :not_found) unless @chat_room

      body = params[:body].to_s.strip
      return json_error('body is required', status: :bad_request) if body.blank?

      msg = @chat_room.messages.create!(user_id: current_user.id, body: body)

      render json: { message: serialize_message(msg) }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def resolve_context!
      if params[:group_id].present?
        resolve_group_context!
      elsif params[:event_id].present?
        resolve_event_context!
      else
        json_error('missing context', status: :bad_request)
        return
      end

      return if performed?
      @chat_room = ChatRoom.find_or_create_by!(chatable: @chatable) if @chatable
    end

    def resolve_group_context!
      group = Group.find(params[:group_id])
      unless GroupMember.exists?(group_id: group.id, user_id: current_user.id)
        return json_error('Forbidden', status: :forbidden)
      end

      @context = { type: 'group', id: group.id }
      @chatable = group
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    end

    def resolve_event_context!
      event = Event.find_by(id: params[:event_id])

      # 削除済みイベントなら GET は空を返すため context だけ作る
      unless event
        @context = { type: 'event', id: params[:event_id].to_i }
        @chatable = nil
        return
      end

      if event.respond_to?(:created_by_id) && event.created_by_id.to_i == current_user.id
        ok = true
      else
        ok = false
        if ActiveRecord::Base.connection.data_source_exists?('event_participants')
          ok ||= EventParticipant.exists?(event_id: event.id, user_id: current_user.id)
        end
        if !ok && ActiveRecord::Base.connection.data_source_exists?('event_groups')
          gids = EventGroup.where(event_id: event.id).pluck(:group_id)
          ok ||= GroupMember.where(user_id: current_user.id, group_id: gids).exists? if gids.any?
        end
      end

      return json_error('Forbidden', status: :forbidden) unless ok

      @context = { type: 'event', id: event.id }
      @chatable = event
    end

    def serialize_message(m)
      {
        id: m.id,
        body: m.body,
        created_at: m.created_at&.iso8601,
        user_id: m.user_id,
        user_name: if m.user.respond_to?(:name)
                     m.user.name
                   elsif m.user.respond_to?(:email)
                     m.user.email
                   else
                     'user'
                   end
      }
    end
  end
end
