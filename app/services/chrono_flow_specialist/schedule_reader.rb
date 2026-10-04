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

    class ReadFacts < Array
      attr_reader :warnings

      def initialize(facts, warnings: [])
        super(facts)
        @warnings = warnings.freeze
      end
    end

    def initialize(fact_id:)
      @fact_id = fact_id
    end

    def call(user:, request:, now:)
      zone_name = request.fetch("time_zone")
      exact_zone!(zone_name)
      start_at, end_at = utc_bounds(zone_name, now)
      refresh = request.dig('constraints', 'refresh_scope').present?
      return refresh_facts(user, zone_name, now, start_at, end_at) if refresh

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
      facts = selected.filter_map do |_sort_key, event_id, fact_id|
        event = events.fetch(event_id)
        title = projected_text(event.title)
        next if title.blank?

        build_fact(event, zone_name, fact_id, title: title, location: projected_text(event.location))
      end
      ReadFacts.new(facts)
    end

    private

    # One SQL command gives counts, day membership, bounded rows and their text
    # size the same PostgreSQL statement snapshot, including under Rails test
    # transactions. Ordinary reads retain their existing opaque-ID tie choice.
    def refresh_facts(user, zone_name, now, start_at, end_at)
      target_date = now.in_time_zone(Time.find_zone!(zone_name)).to_date
      next_date = target_date + 1
      next_day_at = Time.find_zone!(zone_name).local(next_date.year, next_date.month, next_date.day).utc
      sql = <<~SQL
        WITH eligible AS MATERIALIZED (
          SELECT e.id, e.start_at, e.end_at,
            CASE WHEN e.all_day THEN
              (e.start_at AT TIME ZONE 'UTC' AT TIME ZONE :calendar_zone)::date <= :target_date
              AND (e.end_at AT TIME ZONE 'UTC' AT TIME ZONE :calendar_zone)::date > :target_date
            ELSE e.start_at < :next_day_at AND e.end_at > :start_at END AS target_day
          FROM events e
          WHERE (e.created_by_id = :user_id OR EXISTS (
            SELECT 1 FROM event_participants p WHERE p.event_id = e.id AND p.user_id = :user_id
          )) AND e.start_at < :end_at AND e.end_at > :start_at
            AND NOT EXISTS (SELECT 1 FROM event_groups g WHERE g.event_id = e.id)
        ), summary AS (
          SELECT count(*) AS total_count, count(*) FILTER (WHERE target_day) AS today_count FROM eligible
        ), selected AS MATERIALIZED (
          SELECT * FROM eligible ORDER BY start_at, end_at, id LIMIT :result_limit
        ), text_size AS (
          SELECT COALESCE(sum(octet_length(COALESCE(e.title, ''))
            + octet_length(COALESCE(e.location, ''))), 0) AS projected_bytes
          FROM selected s JOIN events e ON e.id = s.id
        )
        SELECT summary.total_count, summary.today_count, text_size.projected_bytes,
          e.id, e.start_at, e.end_at, e.all_day, e.updated_at, s.target_day,
          CASE WHEN text_size.projected_bytes <= :maximum_text_bytes THEN e.title END AS title,
          CASE WHEN text_size.projected_bytes <= :maximum_text_bytes THEN e.location END AS location
        FROM summary CROSS JOIN text_size LEFT JOIN selected s ON true LEFT JOIN events e ON e.id = s.id
        ORDER BY s.start_at, s.end_at, s.id
      SQL
      rows = ActiveRecord::Base.uncached do
        Event.find_by_sql([sql, {
          user_id: user.id, calendar_zone: Time.zone.tzinfo.name, target_date: target_date,
          next_day_at: next_day_at, start_at: start_at, end_at: end_at,
          result_limit: MAX_EVENTS, maximum_text_bytes: MAX_PROJECTED_TEXT_BYTES
        }])
      end
      first = rows.fetch(0)
      raise Errors::Error.new(:invalid_response_schema) if first.projected_bytes.to_i > MAX_PROJECTED_TEXT_BYTES

      total_count = first.total_count.to_i
      today_count = first.today_count.to_i
      warnings = []
      warnings << 'schedule_context_truncated' if total_count > MAX_EVENTS
      facts = rows.filter_map do |event|
        next if event.id.nil?
        title = projected_text(event.title)
        if title.blank?
          warnings << 'schedule_context_event_omitted'
          next
        end
        fact = build_fact(event, zone_name, @fact_id.for(event, kind: 'schedule_event'),
          title: title, location: projected_text(event.location))
        fact.fetch('fields')['day_relation'] = event.target_day ? 'target_day' : 'outside_target_day'
        [event.start_at, event.end_at, fact]
      end.sort_by { |start, finish, fact| [start, finish, fact.fetch('id')] }.map(&:last)
      facts << {
        'id' => @fact_id.for(user, kind: 'schedule_summary'), 'fact_type' => 'schedule_summary',
        'fields' => {
          'target_date' => target_date.iso8601, 'time_zone' => zone_name,
          'total_count' => total_count, 'today_count' => today_count,
          'returned_count' => facts.length, 'partial' => warnings.any?
        },
        'source_updated_at' => numeric_offset_time(now, zone_name)
      }
      ReadFacts.new(facts, warnings: warnings.uniq)
    end

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

    def build_fact(event, request_zone, fact_id, title:, location:)
      {
        "id" => fact_id,
        "fact_type" => "schedule_event",
        "fields" => {
          "title" => title,
          "start_at" => wire_start(event, request_zone),
          "end_at" => wire_end(event, request_zone),
          "all_day" => !!event.all_day,
          "location" => location
        },
        "source_updated_at" => numeric_offset_time(event.updated_at, request_zone)
      }
    end

    def projected_text(value)
      return nil if value.nil?
      return "" unless value.is_a?(String) &&
        [Encoding::UTF_8, Encoding::US_ASCII].include?(value.encoding) && value.valid_encoding?

      value.encode(Encoding::UTF_8).gsub(/[\p{Cc}\p{Space}]+/u, " ").strip
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
