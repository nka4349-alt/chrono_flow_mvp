# frozen_string_literal: true

module Api
  class EventsController < BaseController
    before_action :set_event, only: %i[show update destroy share_to_groups add_to_my_calendar]
    before_action :authorize_event_access!, only: %i[show share_to_groups add_to_my_calendar]
    before_action :authorize_event_edit!, only: %i[update destroy]

    # GET /api/events?start=...&end=...&scope=home
    def index
      start_at = parse_time_param(params[:start])
      end_at   = parse_time_param(params[:end])

      events = home_events_scope

      if start_at && end_at
        events = events.where('events.start_at < ? AND events.end_at > ?', end_at, start_at)
      end

      events = events.distinct

      render json: { events: events.map { |ev| serialize_fc_event(ev) } }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # GET /api/events/:id
    def show
      render json: { event: serialize_fc_event(@event) }
    end

    # POST /api/events
    def create
      attrs = event_params
      parent_id = attrs[:parent_id]
      ev = nil
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: [parent_id], require_all: parent_id.present?
      ) do |locked_events|
        parent = locked_events[parent_id.to_i] if parent_id.present?
        raise SecretaryMutation::NativeWriterGuard::Forbidden if parent && !event_accessible?(parent)

        ev = Event.new(attrs)
        ev.created_by_id = current_user.id if ev.respond_to?(:created_by_id=)
        ev.save!

        group_ids = Array(params[:group_ids]).map(&:to_i).uniq
        if group_ids.any?
          attach_groups!(ev, group_ids)
        else
          ensure_personal_participant!(ev)
        end
      end

      render json: { event: serialize_fc_event(ev) }, status: :created
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH /api/events/:id
    def update
      attrs = event_params
      target_ids = [@event.id, @event.parent_id, attrs[:parent_id]]
      requested_parent_id = attrs[:parent_id]
      verify_ids = -> { [@event.id, Event.where(id: @event.id).pick(:parent_id), requested_parent_id] }
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: target_ids, verify_event_ids: verify_ids
      ) do |locked_events|
        @event = locked_events.fetch(@event.id)
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless event_editable?(@event)
        if attrs[:parent_id].present?
          parent = locked_events.fetch(attrs[:parent_id].to_i)
          raise SecretaryMutation::NativeWriterGuard::Forbidden unless event_accessible?(parent)
        end

        @event.update!(attrs)
        if params.key?(:group_ids)
          group_ids = Array(params[:group_ids]).map(&:to_i).uniq
          replace_groups!(@event, group_ids)
        end
      end

      render json: { event: serialize_fc_event(@event) }
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::MissingTarget
      json_error('not found', status: :not_found)
    rescue SecretaryMutation::NativeWriterGuard::TargetSetChanged
      json_error('conflict', status: :conflict)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # DELETE /api/events/:id
    def destroy
      child_ids = Event.where(parent_id: @event.id).pluck(:id)
      target_ids = [@event.id, @event.parent_id, *child_ids]
      verify_ids = lambda do
        [@event.id, Event.where(id: @event.id).pick(:parent_id),
          *Event.where(parent_id: @event.id).order(:id).pluck(:id)]
      end
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: target_ids, verify_event_ids: verify_ids
      ) do |locked_events|
        @event = locked_events.fetch(@event.id)
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless event_editable?(@event)

        # 共有リクエスト
        if defined?(EventShareRequest) && ActiveRecord::Base.connection.data_source_exists?('event_share_requests')
          EventShareRequest.where(event_id: @event.id).delete_all
        end

        # 旧共有/依頼
        if defined?(EventShare) && ActiveRecord::Base.connection.data_source_exists?('event_shares')
          EventShare.where(event_id: @event.id).delete_all
        end
        if defined?(EventRequest) && ActiveRecord::Base.connection.data_source_exists?('event_requests')
          EventRequest.where(event_id: @event.id).delete_all
        end

        # イベント参加者
        if defined?(EventParticipant) && ActiveRecord::Base.connection.data_source_exists?('event_participants')
          EventParticipant.where(event_id: @event.id).delete_all
        end

        # グループ紐付け
        if defined?(EventGroup) && ActiveRecord::Base.connection.data_source_exists?('event_groups')
          EventGroup.where(event_id: @event.id).delete_all
        end

        # イベントチャット
        if defined?(ChatRoom)
          room = ChatRoom.find_by(chatable_type: 'Event', chatable_id: @event.id)
          if room
            room.messages.delete_all if room.respond_to?(:messages)
            room.destroy!
          end
        end

        # AI提案履歴は残し、削除対象イベントへの参照だけ外す。
        nullify_ai_recommendation_event_refs!(@event.id)

        @event.destroy!
      end

      render json: { ok: true }
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::MissingTarget
      json_error('not found', status: :not_found)
    rescue SecretaryMutation::NativeWriterGuard::TargetSetChanged
      json_error('conflict', status: :conflict)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # POST /api/events/:id/share_to_groups
    def share_to_groups
      group_ids = Array(params[:group_ids]).map(&:to_i).uniq
      return json_error('group_ids is required', status: :bad_request) if group_ids.empty?

      SecretaryMutation::NativeWriterGuard.with_events(actor: current_user, event_ids: [@event.id]) do |locked_events|
        @event = locked_events.fetch(@event.id)
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless event_accessible?(@event)
        attach_groups!(@event, group_ids)
      end

      render json: { ok: true, event: serialize_fc_event(@event) }
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::MissingTarget
      json_error('not found', status: :not_found)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # POST /api/events/:id/add_to_my_calendar
    def add_to_my_calendar
      mode = params[:mode].to_s
      mode = 'link' if mode.blank?
      return json_error('invalid mode', status: :bad_request) unless %w[link copy].include?(mode)

      target_ids = [@event.id, @event.parent_id]
      result = nil
      verify_ids = -> { [@event.id, Event.where(id: @event.id).pick(:parent_id)] }
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: target_ids, verify_event_ids: verify_ids
      ) do |locked_events|
        @event = locked_events.fetch(@event.id)
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless event_accessible?(@event)

        if mode == 'link'
          ensure_personal_participant!(@event)
          result = @event
        else
          result = Event.new(
            title: @event.title, start_at: @event.start_at, end_at: @event.end_at,
            all_day: @event.try(:all_day), event_type_id: @event.try(:event_type_id),
            parent_id: @event.try(:parent_id), description: @event.try(:description),
            location: @event.try(:location), color: @event.try(:color)
          )
          result.created_by_id = current_user.id if result.respond_to?(:created_by_id=)
          result.save!
          ensure_personal_participant!(result)
        end
      end
      render json: { ok: true, event: serialize_fc_event(result) }, status: (mode == 'copy' ? :created : :ok)
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::MissingTarget
      json_error('not found', status: :not_found)
    rescue SecretaryMutation::NativeWriterGuard::TargetSetChanged
      json_error('conflict', status: :conflict)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def nullify_ai_recommendation_event_refs!(event_id)
      return unless defined?(AiRecommendation)
      return unless ActiveRecord::Base.connection.data_source_exists?('ai_recommendations')

      columns = AiRecommendation.column_names
      touch_attrs = columns.include?('updated_at') ? { updated_at: Time.current } : {}

      if columns.include?('source_event_id')
        AiRecommendation.where(source_event_id: event_id).update_all({ source_event_id: nil }.merge(touch_attrs))
      end

      if columns.include?('created_event_id')
        AiRecommendation.where(created_event_id: event_id).update_all({ created_event_id: nil }.merge(touch_attrs))
      end
    end

    def set_event
      @event = Event.find(params[:id])
    end

    def event_params
      p = params.require(:event)
      allowed = %i[title start_at end_at all_day description]
      allowed << :location if Event.column_names.include?('location')
      allowed << :color if Event.column_names.include?('color')
      allowed << :event_type_id if Event.column_names.include?('event_type_id')
      allowed << :parent_id if Event.column_names.include?('parent_id')
      p.permit(*allowed)
    end

    def parse_time_param(v)
      return nil if v.blank?
      Time.zone.parse(v.to_s)
    rescue StandardError
      nil
    end

    def calendar_zone
      @calendar_zone ||= Time.find_zone(ENV['APP_TIMEZONE'].presence || 'Asia/Tokyo') || Time.zone
    end

    def calendar_timestamp(value)
      return nil if value.blank?

      value.in_time_zone(calendar_zone).iso8601
    end

    def calendar_all_day_date(value)
      return nil if value.blank?

      value.in_time_zone(calendar_zone).to_date.iso8601
    end

    def calendar_event_start(event)
      event.try(:all_day) ? calendar_all_day_date(event.start_at) : calendar_timestamp(event.start_at)
    end

    def calendar_event_end(event, display_end)
      event.try(:all_day) ? calendar_all_day_date(event.end_at) : calendar_timestamp(display_end)
    end

    def calendar_actual_start(event)
      event.try(:all_day) ? calendar_all_day_date(event.start_at) : calendar_timestamp(event.start_at)
    end

    def calendar_actual_end(event)
      event.try(:all_day) ? calendar_all_day_date(event.end_at) : calendar_timestamp(event.end_at)
    end

    def home_events_scope
      uid = current_user.id
      scope = Event.all

      if ActiveRecord::Base.connection.data_source_exists?('event_participants')
        scope = scope.left_outer_joins(:event_participants)

        if ActiveRecord::Base.connection.data_source_exists?('event_groups')
          scope.where(
            "event_participants.user_id = :uid OR (events.created_by_id = :uid AND NOT EXISTS (SELECT 1 FROM event_groups eg WHERE eg.event_id = events.id))",
            uid: uid
          )
        else
          scope.where("event_participants.user_id = :uid OR events.created_by_id = :uid", uid: uid)
        end
      else
        scope = scope.where(created_by_id: uid)
      end
    end

    def attach_groups!(event, group_ids)
      return unless ActiveRecord::Base.connection.data_source_exists?('event_groups')

      group_ids.each do |gid|
        EventGroup.find_or_create_by!(event_id: event.id, group_id: gid)
      end
    end

    def replace_groups!(event, group_ids)
      return unless ActiveRecord::Base.connection.data_source_exists?('event_groups')

      EventGroup.where(event_id: event.id).where.not(group_id: group_ids).delete_all
      attach_groups!(event, group_ids)
    end

    def ensure_personal_participant!(event)
      return unless ActiveRecord::Base.connection.data_source_exists?('event_participants')

      EventParticipant.find_or_create_by!(event_id: event.id, user_id: current_user.id)
    rescue NameError
    end

    def authorize_event_access!
      return if event_accessible?(@event)

      json_error('Forbidden', status: :forbidden)
    end

    def authorize_event_edit!
      return if event_editable?(@event)

      json_error('Forbidden', status: :forbidden)
    end

    def event_editable?(event)
      creator_id = event.respond_to?(:created_by_id) ? event.created_by_id : nil
      creator_id.present? && creator_id.to_i == current_user.id
    end

    def event_accessible?(event)
      uid = current_user.id

      if event.respond_to?(:created_by_id) && event.created_by_id.to_i == uid
        return true
      end

      if ActiveRecord::Base.connection.data_source_exists?('event_participants')
        return true if EventParticipant.exists?(event_id: event.id, user_id: uid)
      end

      if ActiveRecord::Base.connection.data_source_exists?('event_groups')
        gids = EventGroup.where(event_id: event.id).pluck(:group_id)
        return false if gids.empty?

        return GroupMember.where(user_id: uid, group_id: gids).exists?
      end

      false
    end

    def calendar_display_end(event)
      start_at = event.start_at
      end_at = event.end_at

      return end_at if start_at.blank? || end_at.blank?
      return end_at if event.try(:all_day)

      starts_at_midnight = start_at.hour.zero? && start_at.min.zero? && start_at.sec.zero?
      ends_at_midnight = end_at.hour.zero? && end_at.min.zero? && end_at.sec.zero?

      if starts_at_midnight && ends_at_midnight && end_at.to_date > start_at.to_date
        end_at + 1.day
      else
        end_at
      end
    end

    def serialize_fc_event(event)
      group_ids =
        if ActiveRecord::Base.connection.data_source_exists?('event_groups')
          EventGroup.where(event_id: event.id).pluck(:group_id)
        else
          []
        end

      color = nil
      color = event.color if event.respond_to?(:color) && event.color.present?
      if color.blank? && event.respond_to?(:event_type_id) && event.event_type_id.present? && defined?(EventType)
        color = EventType.where(id: event.event_type_id).limit(1).pluck(:color).first
      end
      color ||= '#3b82f6'
      display_end = calendar_display_end(event)

      {
        id: event.id,
        title: event.title,
        start: calendar_event_start(event),
        end: calendar_event_end(event, display_end),
        allDay: !!event.try(:all_day),
        backgroundColor: color,
        borderColor: color,
        extendedProps: {
          group_ids: group_ids,
          parent_id: (event.respond_to?(:parent_id) ? event.parent_id : nil),
          created_by_id: (event.respond_to?(:created_by_id) ? event.created_by_id : nil),
          location: (event.respond_to?(:location) ? event.location : nil),
          description: (event.respond_to?(:description) ? event.description : nil),
          color: color,
          actual_start: calendar_actual_start(event),
          actual_end: calendar_actual_end(event),
          actual_all_day: !!event.try(:all_day)
        }
      }
    end
  end
end
