# frozen_string_literal: true

require "date"
require "time"
require "tzinfo"

module ChronoFlowSpecialist
  class ScheduleReader
    MAX_EVENTS = 24
    BATCH_SIZE = 100
    MAX_PROJECTED_TEXT_BYTES = 524_288
    SELECTED_COLUMNS = %i[id title start_at end_at all_day location updated_at].freeze

    def initialize(fact_id:)
      @fact_id = fact_id
    end

    def call(user:, request:, now:)
      zone_name = request.fetch("time_zone")
      exact_zone!(zone_name)
      start_at, end_at = utc_bounds(zone_name, now)
      scope = Event.left_outer_joins(:event_participants)
                   .where("events.created_by_id = :user_id OR event_participants.user_id = :user_id", user_id: user.id)
                   .where("events.start_at < ? AND events.end_at > ?", end_at, start_at)
                   .distinct
      scope = scope.where.not(id: EventGroup.select(:event_id))

      selected = []
      scope.select(:id, :start_at, :end_at).find_each(batch_size: BATCH_SIZE) do |event|
        fact_id = @fact_id.for(event, kind: "schedule_event")
        selected << [[event.start_at, event.end_at, fact_id], event.id, fact_id]
        selected.sort_by!(&:first)
        selected.pop if selected.length > MAX_EVENTS
      end

      selected_ids = selected.map { |_sort_key, event_id, _fact_id| event_id }
      ensure_projected_text_within_bound!(selected_ids)
      events = scope.where(id: selected_ids).select(SELECTED_COLUMNS).index_by(&:id)
      selected.map { |_sort_key, event_id, fact_id| build_fact(events.fetch(event_id), zone_name, fact_id) }
    end

    private

    def exact_zone!(name)
      TZInfo::Timezone.get(name)
    rescue TZInfo::InvalidTimezoneIdentifier
      raise Errors::Error.new(:invalid_request_schema)
    end

    def utc_bounds(zone_name, now)
      rails_zone = Time.find_zone!(zone_name)
      local_date = now.in_time_zone(rails_zone).to_date
      end_date = local_date + 14
      [
        rails_zone.local(local_date.year, local_date.month, local_date.day).utc,
        rails_zone.local(end_date.year, end_date.month, end_date.day).utc
      ]
    end

    def build_fact(event, request_zone, fact_id)
      {
        "id" => fact_id,
        "fact_type" => "schedule_event",
        "fields" => {
          "title" => event.title,
          "start_at" => wire_start(event, request_zone),
          "end_at" => wire_end(event, request_zone),
          "all_day" => !!event.all_day,
          "location" => event.location
        },
        "source_updated_at" => numeric_offset_time(event.updated_at, request_zone)
      }
    end

    def ensure_projected_text_within_bound!(event_ids)
      return if event_ids.empty?

      expression = <<~SQL.squish
        COALESCE(
          SUM(
            octet_length(COALESCE(events.title, ''))
            + octet_length(COALESCE(events.location, ''))
          ),
          0
        )
      SQL
      projected_bytes = Event.where(id: event_ids).pick(Arel.sql(expression)).to_i
      raise Errors::Error.new(:invalid_response_schema) if projected_bytes > MAX_PROJECTED_TEXT_BYTES
    end

    def wire_start(event, request_zone)
      event.all_day? ? application_calendar_date(event.start_at) : numeric_offset_time(event.start_at, request_zone)
    end

    def wire_end(event, request_zone)
      event.all_day? ? application_calendar_date(event.end_at) : numeric_offset_time(event.end_at, request_zone)
    end

    def application_calendar_date(value)
      value.in_time_zone(Time.zone).to_date.iso8601
    end

    def numeric_offset_time(value, zone_name)
      value.in_time_zone(zone_name).iso8601(0)
    end
  end
end
