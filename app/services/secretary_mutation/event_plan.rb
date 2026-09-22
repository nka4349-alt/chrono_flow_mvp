# frozen_string_literal: true

module SecretaryMutation
  class EventPlan
    Plan = Struct.new(:status, :reason_code, :question, :before, :after,
      :changed_fields, :planned_related_effects, keyword_init: true)

    def initialize(event:, operation:, messages:, time_zone:, now:)
      @event = event
      @operation = operation
      @messages = messages
      @time_zone = time_zone
      @now = now
    end

    def call
      before = EventProjection.snapshot(@event, time_zone: @time_zone)
      return deletion(before) if @operation == 'event.delete'

      update(before)
    end

    private

    def deletion(before)
      if EventProjection.notification_rows(@event).exists?
        return Plan.new(status: 'rejected', reason_code: 'ineligible_notification_history',
          question: '通知履歴が残っているため、この予定は削除できません。', before: before, after: nil,
          changed_fields: [], planned_related_effects: { 'type' => 'none' })
      end

      effects = EventProjection.delete_effects(@event)
      Plan.new(status: 'ready', reason_code: nil,
        question: "#{before.fetch('title')}と、表示したリマインダー・チャット等の関連情報を削除しますか？",
        before: before, after: nil, changed_fields: ['$record'], planned_related_effects: effects)
    end

    def update(before)
      after = Marshal.load(Marshal.dump(before))
      message = @messages.join("\n").unicode_normalize(:nfkc)
      requested_fields = []
      requested_fields << 'title' if assign_text(after, 'title', message,
        /(?:タイトル|件名)(?:を|は)?[「『"]?(.+?)[」』"]?(?:に|へ)(?:変更|更新)/m)
      requested_fields << 'location' if assign_text(after, 'location', message,
        /場所(?:を|は)?[「『"]?(.+?)[」』"]?(?:に|へ)(?:変更|更新)/m)
      if message.match?(/(?:説明|詳細)(?:を|は)?(?:削除|空に)/)
        after['description'] = nil
        requested_fields << 'description'
      else
        requested_fields << 'description' if assign_text(after, 'description', message,
          /(?:説明|詳細)(?:を|は)?[「『"]?(.+?)[」』"]?(?:に|へ)(?:変更|更新)/m)
      end
      replacement_schedule = schedule_from(message, before.fetch('schedule'))
      if replacement_schedule
        after['schedule'] = replacement_schedule
        requested_fields << 'schedule'
      end

      changed = %w[title description location schedule].select { |field| before[field] != after[field] }.sort
      if changed.empty?
        if requested_fields.any?
          return Plan.new(status: 'rejected', reason_code: 'no_effect',
            question: '指定された内容は現在の予定と同じため、変更はありません。',
            before: before, after: nil, changed_fields: [], planned_related_effects: { 'type' => 'none' })
        end

        return Plan.new(status: 'needs_clarification', reason_code: nil,
          question: 'タイトル、説明、場所、または開始・終了日時の変更内容を指定してください。',
          before: before, after: nil, changed_fields: [], planned_related_effects: { 'type' => 'none' })
      end
      if changed.include?('schedule') && EventProjection.pending_reminder?(@event)
        return Plan.new(status: 'rejected', reason_code: 'reminder_consistency_requires_gate',
          question: '通知予定があるため、日時変更は現在実行できません。', before: before, after: nil,
          changed_fields: [], planned_related_effects: { 'type' => 'none' })
      end

      Plan.new(status: 'ready', reason_code: nil,
        question: "#{before.fetch('title')}を確認した内容へ変更しますか？", before: before, after: after,
        changed_fields: changed, planned_related_effects: { 'type' => 'none' })
    end

    def assign_text(snapshot, field, message, pattern)
      value = message.match(pattern)&.[](1)&.strip
      return false unless value

      value = value.sub(/[。．]\z/, '').strip
      return false unless value.present? && value.length <= (field == 'description' ? 4_000 : 200)

      validate_text_field!(field, value)
      snapshot[field] = value
      true
    end

    def validate_text_field!(field, value)
      case field
      when 'title'
        SecretaryMutation::Contract.event_title!(value)
      when 'location'
        SecretaryMutation::Contract.event_location!(value)
      when 'description'
        SecretaryMutation::Contract.description!(value)
      else
        raise Error.new(:invalid_request)
      end
    rescue SecretaryMutation::Contract::Invalid
      raise Error.new(:invalid_request), cause: nil
    end

    def schedule_from(message, original)
      zone = ActiveSupport::TimeZone[@time_zone]
      iso_values = message.scan(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})/)
      if iso_values.length == 2
        start_at, end_at = iso_values.map { |value| Time.iso8601(value) }
        return nil unless end_at > start_at

        return datetime_schedule(start_at.in_time_zone(zone), end_at.in_time_zone(zone))
      end

      match = message.match(/(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日[^\n]{0,80}?(\d{1,2})(?::|時)(\d{1,2})?分?[^\n]{0,30}?(?:から|〜|～|－|-)[^\n]{0,30}?(\d{1,2})(?::|時)(\d{1,2})?分?/)
      if match
        year = (match[1] || @now.in_time_zone(zone).year).to_i
        start_at = unambiguous_local(zone, year, match[2].to_i, match[3].to_i,
          match[4].to_i, (match[5] || 0).to_i)
        end_at = unambiguous_local(zone, year, match[2].to_i, match[3].to_i,
          match[6].to_i, (match[7] || 0).to_i)
        return nil unless start_at && end_at && end_at > start_at

        return datetime_schedule(start_at, end_at)
      end

      date_match = message.match(/(?:日付|予定日)?(?:を|は)?(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日(?:に|へ)(?:変更|移動|延期)/)
      return nil unless date_match

      year = (date_match[1] || @now.in_time_zone(zone).year).to_i
      date = Date.new(year, date_match[2].to_i, date_match[3].to_i)
      if original.fetch('precision') == 'date'
        duration = Date.iso8601(original.fetch('end_on')) - Date.iso8601(original.fetch('start_on'))
        return date_schedule(date, date + duration.to_i)
      end

      original_start = Time.iso8601(original.fetch('start_at')).in_time_zone(zone)
      original_end = Time.iso8601(original.fetch('end_at')).in_time_zone(zone)
      start_at = unambiguous_local(zone, date.year, date.month, date.day,
        original_start.hour, original_start.min, original_start.sec)
      return nil unless start_at

      datetime_schedule(start_at, start_at + (original_end - original_start))
    rescue ArgumentError
      nil
    end

    def datetime_schedule(start_at, end_at)
      {
        'precision' => 'datetime', 'start_at' => EventProjection.rfc3339(start_at),
        'end_at' => EventProjection.rfc3339(end_at), 'start_on' => nil, 'end_on' => nil,
        'time_zone' => @time_zone, 'end_exclusive' => true
      }
    end

    def date_schedule(start_on, end_on)
      zone = ActiveSupport::TimeZone[@time_zone]
      return nil unless unambiguous_local(zone, start_on.year, start_on.month, start_on.day, 0, 0)
      return nil unless unambiguous_local(zone, end_on.year, end_on.month, end_on.day, 0, 0)

      {
        'precision' => 'date', 'start_at' => nil, 'end_at' => nil,
        'start_on' => start_on.iso8601, 'end_on' => end_on.iso8601,
        'time_zone' => @time_zone, 'end_exclusive' => true
      }
    end

    def unambiguous_local(zone, year, month, day, hour, minute, second = 0)
      wall_clock = DateTime.new(year, month, day, hour, minute, second)
      return nil unless zone.tzinfo.periods_for_local(wall_clock).one?

      value = zone.local(year, month, day, hour, minute, second)
      expected = [year, month, day, hour, minute, second]
      return nil unless [value.year, value.month, value.day, value.hour, value.min, value.sec] == expected

      value
    rescue ArgumentError
      nil
    end
  end
end
