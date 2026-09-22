# frozen_string_literal: true

module SecretaryMutation
  class EventTargetSearch
    Result = Struct.new(:events, :truncated, keyword_init: true)

    def initialize(user:, message:, time_zone:, now:)
      @user = user
      @message = message.to_s
      @time_zone = time_zone
      @now = now
    end

    def call
      zone = ActiveSupport::TimeZone[@time_zone]
      raise Error.new(:invalid_request) unless zone

      local_date = @now.in_time_zone(zone).to_date
      start_date = local_date - 366
      end_date = local_date + 732
      window_start = zone.local(start_date.year, start_date.month, start_date.day).utc
      window_end = zone.local(end_date.year, end_date.month, end_date.day).utc
      overlap_sql = <<~SQL.squish
        (
          events.all_day = FALSE
          AND events.start_at < ? AND events.end_at > ?
        ) OR (
          events.all_day = TRUE
          AND (events.start_at AT TIME ZONE 'UTC' AT TIME ZONE ?)::date < ?
          AND (events.end_at AT TIME ZONE 'UTC' AT TIME ZONE ?)::date > ?
        )
      SQL
      relation = Event.where(created_by_id: @user.id, parent_id: nil)
        .where(overlap_sql, window_end, window_start, Time.zone.tzinfo.name, end_date,
          Time.zone.tzinfo.name, start_date)
        .where('events.end_at > events.start_at')
        .where("events.title ~ '[^[:space:]]' AND char_length(events.title) <= 200")
        .where("events.title !~ '[[:cntrl:]]'")
        .where(<<~SQL.squish)
          events.description IS NULL OR (
            char_length(events.description) <= 4000
            AND regexp_replace(events.description, E'\\n', '', 'g') !~ '[[:cntrl:]]'
          )
        SQL
        .where("events.location IS NULL OR (char_length(events.location) <= 200 AND events.location !~ '[[:cntrl:]]')")
        .where(<<~SQL.squish, @user.id)
          NOT EXISTS (SELECT 1 FROM events children WHERE children.parent_id = events.id)
          AND NOT EXISTS (SELECT 1 FROM event_groups WHERE event_groups.event_id = events.id)
          AND NOT EXISTS (SELECT 1 FROM event_access_grants WHERE event_access_grants.event_id = events.id)
          AND NOT EXISTS (SELECT 1 FROM event_shares WHERE event_shares.event_id = events.id)
          AND NOT EXISTS (SELECT 1 FROM event_requests WHERE event_requests.event_id = events.id)
          AND NOT EXISTS (SELECT 1 FROM event_share_requests WHERE event_share_requests.event_id = events.id)
          AND NOT EXISTS (
            SELECT 1 FROM event_participants
            WHERE event_participants.event_id = events.id AND event_participants.user_id <> ?
          )
        SQL
      if (hint = target_hint)
        escaped = ActiveRecord::Base.sanitize_sql_like(hint)
        relation = relation.where('events.title ILIKE ?', "%#{escaped}%")
      end
      rows = relation.order(:start_at, :end_at, :id).limit(6).to_a
        .select { |event| EventProjection.eligible?(event, @user) }
      Result.new(events: rows.first(5), truncated: rows.length == 6)
    end

    private

    def target_hint
      normalized = @message.unicode_normalize(:nfkc).strip
      patterns = [
        /[「『]([^」』]{1,200})[」』](?:の予定)?(?:を|の)/,
        /(.{1,200}?)(?:の(?:タイトル|件名|場所|説明)|を(?:削除|消して|変更|更新))/
      ]
      patterns.each do |pattern|
        value = normalized.match(pattern)&.[](1)&.strip
        return value if value.present?
      end
      nil
    end
  end
end
