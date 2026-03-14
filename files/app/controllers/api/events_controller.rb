# frozen_string_literal: true

module Api
  class EventsController < BaseController
    before_action :set_event, only: %i[show update destroy share_to_groups add_to_my_calendar]

    # GET /api/events?start=...&end=...&scope=home
    def index
      start_t = parse_time(params[:start]) || Time.zone.now.beginning_of_month
      end_t   = parse_time(params[:end]) || (Time.zone.now.end_of_month + 1.day)

      scope = params[:scope].presence || 'home'

      events = case scope
               when 'home'
                 home_events_for(current_user, start_t, end_t)
               else
                 # fallback: same as home
                 home_events_for(current_user, start_t, end_t)
               end

      render json: events.map { |ev| serialize_fc_event(ev, scope: 'home') }
    end

    # GET /api/events/:id
    def show
      authorize_event_read!(@event)
      render json: serialize_event(@event)
    end

    # POST /api/events
    def create
      attrs = event_params
      group_ids = Array(attrs.delete(:group_ids)).map(&:to_i).uniq

      if group_ids.any?
        allowed_ids = GroupMember.where(user_id: current_user.id, group_id: group_ids).pluck(:group_id)
        missing = group_ids - allowed_ids
        return render json: { error: 'forbidden' }, status: :forbidden if missing.any?
      end

      event = Event.new(attrs)
      event.created_by_id = current_user.id

      Event.transaction do
        event.save!

        if group_ids.any?
          # Creating a group event: link to groups, but DO NOT auto-add to personal calendar.
          group_ids.each do |gid|
            EventGroup.find_or_create_by!(event_id: event.id, group_id: gid)
          end
        else
          # Personal event: ensure creator can see it.
          EventParticipant.find_or_create_by!(event_id: event.id, user_id: current_user.id)
        end
      end

      render json: serialize_event(event), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # PATCH/PUT /api/events/:id
    def update
      authorize_event_edit!(@event)
      @event.update!(event_params.except(:group_ids))
      render json: serialize_event(@event)
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # DELETE /api/events/:id
    def destroy
      authorize_event_edit!(@event)
      @event.destroy!
      head :no_content
    end

    # POST /api/events/:id/share_to_groups { group_ids: [...] }
    def share_to_groups
      authorize_event_edit!(@event)

      ids = Array(params[:group_ids]).map(&:to_i).uniq
      return render json: { error: 'group_ids required' }, status: :unprocessable_entity if ids.empty?

      allowed_ids = GroupMember.where(user_id: current_user.id, group_id: ids).pluck(:group_id)
      missing = ids - allowed_ids
      return render json: { error: 'forbidden' }, status: :forbidden if missing.any?

      Event.transaction do
        ids.each do |gid|
          EventGroup.find_or_create_by!(event_id: @event.id, group_id: gid)
        end
      end

      render json: { ok: true, group_ids: EventGroup.where(event_id: @event.id).pluck(:group_id) }
    end

    # POST /api/events/:id/add_to_my_calendar
    def add_to_my_calendar
      authorize_event_read!(@event)
      EventParticipant.find_or_create_by!(event_id: @event.id, user_id: current_user.id)
      render json: { ok: true }
    end

    private

    def set_event
      @event = Event.find(params[:id])
    end

    def event_params
      ep = params[:event].presence || params
      permitted = ep.permit(:title, :start_at, :end_at, :all_day, :event_type_id, :parent_id, :description, group_ids: [])
      permitted[:all_day] = ActiveModel::Type::Boolean.new.cast(permitted[:all_day])
      permitted
    end

    def parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def home_events_for(user, start_t, end_t)
      # Home calendar should show:
      # 1) personal events created_by user (events not linked to any group)
      # 2) events the user explicitly added (EventParticipant)

      personal_created = Event
                        .where(created_by_id: user.id)
                        .where.not(id: Event.joins('INNER JOIN event_groups ON event_groups.event_id = events.id').select(:id))

      participating_ids = EventParticipant.where(user_id: user.id).select(:event_id)
      participating = Event.where(id: participating_ids)

      Event
        .where(id: personal_created.select(:id))
        .or(Event.where(id: participating.select(:id)))
        .distinct
        .where('events.start_at < ? AND events.end_at > ?', end_t, start_t)
        .order(:start_at)
    end

    def authorize_event_read!(event)
      return true if event.created_by_id == current_user.id
      return true if EventParticipant.exists?(event_id: event.id, user_id: current_user.id)

      in_group = GroupMember.joins('INNER JOIN event_groups ON event_groups.group_id = group_members.group_id')
                            .where('event_groups.event_id = ? AND group_members.user_id = ?', event.id, current_user.id)
                            .exists?
      return true if in_group

      render json: { error: 'forbidden' }, status: :forbidden
      false
    end

    def authorize_event_edit!(event)
      group_ids = EventGroup.where(event_id: event.id).pluck(:group_id)

      if group_ids.any?
        # group event: must be group admin/owner in at least one linked group
        allowed = GroupMember.where(user_id: current_user.id, group_id: group_ids)
                             .where(role: [GroupMember.roles['admin'], GroupMember.roles['owner']])
                             .exists?
        return true if allowed
      else
        # personal event: only creator
        return true if event.created_by_id == current_user.id
      end

      render json: { error: 'forbidden' }, status: :forbidden
      false
    end

    def serialize_event(ev)
      {
        id: ev.id,
        title: ev.title,
        start_at: ev.start_at&.iso8601,
        end_at: ev.end_at&.iso8601,
        all_day: !!ev.all_day,
        event_type_id: ev.event_type_id,
        parent_id: ev.parent_id,
        description: ev.try(:description),
        group_ids: EventGroup.where(event_id: ev.id).pluck(:group_id)
      }
    end

    def serialize_fc_event(ev, scope:)
      type_color = EventType.where(id: ev.event_type_id).pick(:color)
      base_color = scope == 'group' ? '#ef4444' : '#3b82f6'
      color = type_color.presence || base_color

      {
        id: ev.id,
        title: ev.title,
        start: ev.start_at&.iso8601,
        end: ev.end_at&.iso8601,
        allDay: !!ev.all_day,
        backgroundColor: color,
        borderColor: color,
        extendedProps: {
          description: ev.try(:description),
          event_type_id: ev.event_type_id,
          parent_id: ev.parent_id,
          group_ids: EventGroup.where(event_id: ev.id).pluck(:group_id),
          scope: scope
        }
      }
    end
  end
end
