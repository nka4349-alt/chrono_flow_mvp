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
    # body: { event: {title,start_at,end_at,all_day}, group_ids: [1,2] }
    def create
      ev = Event.new(event_params)
      ev.created_by_id = current_user.id if ev.respond_to?(:created_by_id=)

      ev.save!

      group_ids = Array(params[:group_ids]).map(&:to_i).uniq

      if group_ids.any?
        attach_groups!(ev, group_ids)
        # NOTE: group-created events are NOT added to personal calendar automatically.
      else
        ensure_personal_participant!(ev)
      end

      render json: { event: serialize_fc_event(ev) }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH /api/events/:id
    def update
      @event.update!(event_params)

      # group_ids update (optional): allow passing group_ids to replace
      if params.key?(:group_ids)
        group_ids = Array(params[:group_ids]).map(&:to_i).uniq
        replace_groups!(@event, group_ids)
      end

      render json: { event: serialize_fc_event(@event) }
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # DELETE /api/events/:id
    def destroy
      @event.destroy!
      render json: { ok: true }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # POST /api/events/:id/share_to_groups
    # body: { group_ids: [1,2] }
    def share_to_groups
      group_ids = Array(params[:group_ids]).map(&:to_i).uniq
      return json_error('group_ids is required', status: :bad_request) if group_ids.empty?

      attach_groups!(@event, group_ids)

      render json: { ok: true, event: serialize_fc_event(@event) }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # POST /api/events/:id/add_to_my_calendar
    # body: { mode: 'link'|'copy' }
    def add_to_my_calendar
      mode = params[:mode].to_s
      mode = 'link' if mode.blank?

      case mode
      when 'link'
        ensure_personal_participant!(@event)
        render json: { ok: true, event: serialize_fc_event(@event) }
      when 'copy'
        dup = Event.new(
          title: @event.title,
          start_at: @event.start_at,
          end_at: @event.end_at,
          all_day: @event.try(:all_day),
          event_type_id: (@event.respond_to?(:event_type_id) ? @event.event_type_id : nil),
          parent_id: (@event.respond_to?(:parent_id) ? @event.parent_id : nil),
          description: (@event.respond_to?(:description) ? @event.description : nil),
          location: (@event.respond_to?(:location) ? @event.location : nil),
          color: (@event.respond_to?(:color) ? @event.color : nil)
        )
        dup.created_by_id = current_user.id if dup.respond_to?(:created_by_id=)
        dup.save!
        ensure_personal_participant!(dup)
        render json: { ok: true, event: serialize_fc_event(dup) }, status: :created
      else
        json_error('invalid mode', status: :bad_request)
      end
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

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

    # Home (personal) calendar events
    # - Always include events where the user is an EventParticipant
    # - Also include events the user created that are NOT group-linked (so group-created events won't leak)
    def home_events_scope
      uid = current_user.id

      scope = Event.all

      # join participants
      if ActiveRecord::Base.connection.data_source_exists?('event_participants')
        scope = scope.left_outer_joins(:event_participants)

        if ActiveRecord::Base.connection.data_source_exists?('event_groups')
          # created_by but NOT group-linked
          scope.where(
            "event_participants.user_id = :uid OR (events.created_by_id = :uid AND NOT EXISTS (SELECT 1 FROM event_groups eg WHERE eg.event_id = events.id))",
            uid: uid
          )
        else
          scope.where("event_participants.user_id = :uid OR events.created_by_id = :uid", uid: uid)
        end
      else
        # fallback
        scope = scope.where(created_by_id: uid)
      end

      scope
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
      # model not present
    end

    def authorize_event_access!
      return if event_accessible?(@event)

      json_error('Forbidden', status: :forbidden)
    end

    def authorize_event_edit!
      # Editing is limited to creator for now
      creator_id = @event.respond_to?(:created_by_id) ? @event.created_by_id : nil
      return if creator_id.present? && creator_id.to_i == current_user.id

      json_error('Forbidden', status: :forbidden)
    end

    def event_accessible?(event)
      uid = current_user.id

      # personal (creator or participant)
      if event.respond_to?(:created_by_id) && event.created_by_id.to_i == uid
        return true
      end

      if ActiveRecord::Base.connection.data_source_exists?('event_participants')
        return true if EventParticipant.exists?(event_id: event.id, user_id: uid)
      end

      # group-linked and member of any group
      if ActiveRecord::Base.connection.data_source_exists?('event_groups')
        gids = EventGroup.where(event_id: event.id).pluck(:group_id)
        return false if gids.empty?

        return GroupMember.where(user_id: uid, group_id: gids).exists?
      end

      false
    end

    def serialize_fc_event(event)
      group_ids = if ActiveRecord::Base.connection.data_source_exists?('event_groups')
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

      {
        id: event.id,
        title: event.title,
        start: event.start_at&.iso8601,
        end: event.end_at&.iso8601,
        allDay: !!event.try(:all_day),
        backgroundColor: color,
        borderColor: color,
        extendedProps: {
          group_ids: group_ids,
          parent_id: (event.respond_to?(:parent_id) ? event.parent_id : nil),
          created_by_id: (event.respond_to?(:created_by_id) ? event.created_by_id : nil),
          location: (event.respond_to?(:location) ? event.location : nil),
          description: (event.respond_to?(:description) ? event.description : nil),
          color: (event.respond_to?(:color) ? event.color : nil)
        }
      }
    end
  end
end
