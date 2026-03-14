# frozen_string_literal: true

module Api
  # Fix for: GET /api/groups/:id/events returns 500
  # - uses correct column names: start_at / end_at
  # - does not depend on model associations (robust)
  class GroupEventsController < BaseController
    # GET /api/groups/:id/events?start=...&end=...
    def index
      group = Group.find(params[:id])

      unless GroupMember.exists?(group_id: group.id, user_id: current_user.id)
        return render json: { error: 'forbidden' }, status: :forbidden
      end

      range_start = parse_time(params[:start])
      range_end   = parse_time(params[:end])

      event_ids = EventGroup.where(group_id: group.id).select(:event_id)
      scope = Event.where(id: event_ids).distinct

      if range_start && range_end
        scope = scope.where('end_at > ? AND start_at < ?', range_start, range_end)
      end

      events = scope.order(:start_at)

      # preload event_type colors without relying on associations
      type_ids = events.map(&:event_type_id).compact.uniq
      type_color = EventType.where(id: type_ids).pluck(:id, :color).to_h

      # preload group_ids per event
      ids = events.map(&:id)
      eg_pairs = ids.empty? ? [] : EventGroup.where(event_id: ids).pluck(:event_id, :group_id)
      group_ids_by_event = Hash.new { |h, k| h[k] = [] }
      eg_pairs.each { |eid, gid| group_ids_by_event[eid] << gid }

      render json: events.map { |e| serialize_fc_event(e, type_color, group_ids_by_event) }
    end

    private

    def parse_time(s)
      return nil if s.blank?
      Time.zone.parse(s)
    rescue StandardError
      nil
    end

    def serialize_fc_event(e, type_color, group_ids_by_event)
      {
        id: e.id,
        title: e.title,
        start: e.start_at&.iso8601,
        end: e.end_at&.iso8601,
        allDay: !!e.all_day,
        color: (type_color[e.event_type_id] if e.event_type_id) || '#3b82f6',
        extendedProps: {
          parent_id: e.parent_id,
          event_type_id: e.event_type_id,
          group_ids: group_ids_by_event[e.id]
        }
      }
    end
  end
end
