# frozen_string_literal: true

module Api
  # GET /api/groups/:id/events?start=...&end=...
  #
  # Purpose:
  # - Serve FullCalendar-compatible events for a specific group
  # - Keep this isolated from Api::GroupsController to avoid breaking other group actions
  class GroupEventsController < BaseController
    before_action :set_group
    before_action :authorize_member!

    def index
      start_time = parse_time(params[:start])
      end_time   = parse_time(params[:end])

      # Fallback to a safe window if parameters are missing/bad.
      start_time ||= Time.zone.now.beginning_of_month
      end_time   ||= Time.zone.now.end_of_month

      events = Event
        .joins("INNER JOIN event_groups ON event_groups.event_id = events.id")
        .where(event_groups: { group_id: @group.id })
        .where("events.end_at > ? AND events.start_at < ?", start_time, end_time)
        .distinct
        .order(:start_at)

      render json: { events: events.map { |e| serialize_event(e) } }
    end

    private

    def set_group
      @group = Group.find(params[:id])
    end

    def authorize_member!
      return if GroupMember.exists?(group_id: @group.id, user_id: current_user.id)

      render json: { error: "Not a member" }, status: :forbidden
    end

    def serialize_event(event)
      color = EventType.where(id: event.event_type_id).limit(1).pluck(:color).first
      group_ids = EventGroup.where(event_id: event.id).pluck(:group_id)

      {
        id: event.id,
        title: event.title,
        start: event.start_at&.iso8601,
        end: event.end_at&.iso8601,
        allDay: !!event.all_day,
        backgroundColor: color,
        borderColor: color,
        extendedProps: {
          group_ids: group_ids,
          created_by_id: event.created_by_id,
          event_type_id: event.event_type_id
        }
      }
    end
  end
end
