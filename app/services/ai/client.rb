# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'date'

module Ai
  class Client
    DEFAULT_TIMEOUT = 20

    GARBAGE_KEYWORDS = %w[
      ゴミ出し ごみ出し ゴミ捨て ごみ捨て
      ゴミ ごみ 可燃ごみ 燃えるごみ 資源ごみ 不燃ごみ
    ].freeze

    WEEKDAY_MAP = {
      '日' => 0, '日曜' => 0, '日曜日' => 0,
      '月' => 1, '月曜' => 1, '月曜日' => 1,
      '火' => 2, '火曜' => 2, '火曜日' => 2,
      '水' => 3, '水曜' => 3, '水曜日' => 3,
      '木' => 4, '木曜' => 4, '木曜日' => 4,
      '金' => 5, '金曜' => 5, '金曜日' => 5,
      '土' => 6, '土曜' => 6, '土曜日' => 6
    }.freeze

    WEEKDAY_LABELS = {
      0 => '日曜',
      1 => '月曜',
      2 => '火曜',
      3 => '水曜',
      4 => '木曜',
      5 => '金曜',
      6 => '土曜'
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(context:, user_message:, refresh_only: false)
      @context = context
      @user_message = user_message.to_s
      @refresh_only = refresh_only
    end

    def call
      recurrence_response = monthly_garbage_recurrence_response
      return secretary_labels(recurrence_response) if recurrence_response

      structured_response = local_structured_schedule_response
      return secretary_labels(structured_response) if structured_response

      secretary_labels(request_remote)
    rescue StandardError => e
      secretary_labels(fallback_response(e))
    end

    private

    def monthly_garbage_recurrence_response
      text = normalize_japanese(@user_message)
      return nil unless context_value(:scope).to_s == 'home'
      return nil unless GARBAGE_KEYWORDS.any? { |keyword| text.include?(normalize_japanese(keyword)) }

      now = context_now
      year, month = target_year_month(text, now)
      weekdays = target_weekdays(text)

      return nil unless year && month && weekdays.any?

      dates = dates_for_month_weekdays(year, month, weekdays, now.to_date)
      return nil if dates.empty?

      label = "#{month}月の#{weekdays.map { |weekday| WEEKDAY_LABELS[weekday] }.join('・')}"

      event_payloads = dates.first(10).map do |date|
        start_at = app_time_zone.local(date.year, date.month, date.day, 0, 0, 0)
        end_at = start_at + 1.day

        {
          'title' => 'ゴミ出し',
          'description' => 'AI秘書提案の予定候補',
          'start_at' => start_at.iso8601,
          'end_at' => end_at.iso8601,
          'all_day' => true,
          'color' => '#64748b',
          'category' => 'personal',
          'intent' => 'errand',
          'schedule_profile' => 'errand',
          'target_date' => date.iso8601
        }
      end

      date_labels = event_payloads.map do |payload|
        begin
          Date.iso8601(payload['target_date']).strftime('%-m/%-d')
        rescue StandardError
          payload['target_date']
        end
      end.join('、')

      recommendations = [
        {
          'kind' => 'draft_event',
          'title' => "ゴミ出し（#{label}）",
          'description' => "#{date_labels} にゴミ出し",
          'reason' => "#{label}のゴミ出しを1件のまとめ候補にしました。追加すると各日に予定を作成します。",
          'start_at' => event_payloads.first['start_at'],
          'end_at' => event_payloads.first['end_at'],
          'all_day' => true,
          'payload' => {
            'title' => "ゴミ出し（#{label}）",
            'description' => "#{date_labels} にゴミ出し",
            'start_at' => event_payloads.first['start_at'],
            'end_at' => event_payloads.first['end_at'],
            'all_day' => true,
            'color' => '#64748b',
            'category' => 'personal',
            'intent' => 'errand',
            'schedule_profile' => 'errand',
            'rank_position' => 1,
            'recurrence_kind' => 'monthly_weekdays',
            'recurrence_label' => label,
            'target_dates' => event_payloads.map { |payload| payload['target_date'] },
            'events' => event_payloads
          }
        }
      ]

      {
        assistant_message: "#{label}のゴミ出しを1件のまとめ候補にしました。追加すると各日に予定を作成します。",
        recommendations: recommendations,
        provider: 'rails-garbage-recurrence-v1',
        policy_run: {
          provider: 'rails-garbage-recurrence-v1',
          policy_version: 'rails-garbage-recurrence-v1',
          route: 'rails_preprocessor',
          request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
          prompt_snapshot: {
            user_message: @user_message,
            refresh_only: @refresh_only,
            scope: context_value(:scope)
          },
          context_snapshot: {
            scope: context_value(:scope),
            timezone: context_value(:timezone),
            now: context_value(:now)
          },
          result_metadata: {
            recommendation_count: recommendations.length,
            recurrence_label: label,
            bundled_event_count: event_payloads.length
          }
        },
        tool_invocations: []
      }
    end


    # === CF_LOCAL_STRUCTURED_AI_V5 ===

    def local_structured_schedule_response
      return nil unless context_value(:scope).to_s == 'home'
      return nil if @refresh_only

      text = normalize_japanese(@user_message)
      return nil if text.blank?

      local_existing_event_change_response(text) ||
        local_availability_response(text) ||
        local_date_range_response(text) ||
        local_recurrence_response(text) ||
        local_multi_event_response(text) ||
        local_single_explicit_event_response(text)
    end

    # 既存予定の変更・削除は、対象候補の検出まで。自動実行はしない。
    def local_existing_event_change_response(text)
      action =
        if text.match?(/削除|消して|キャンセル|取り消し/)
          '削除'
        elsif text.match?(/変更|移動|ずらして|リスケ/)
          '変更'
        end
      return nil unless action

      matches = matched_existing_events(text).first(5)
      msg = if matches.any?
              rows = matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")
              "#{action}対象と思われる予定を見つけました。安全のため自動#{action}はせず、対象予定を開いて確認してください。\n#{rows}"
            else
              "#{action}指示として受け取りましたが、対象予定を特定できませんでした。予定を開いて直接編集してください。"
            end

      {
        assistant_message: msg,
        recommendations: [],
        provider: 'rails-local-existing-event-guard-v5',
        policy_run: local_policy_run('rails-local-existing-event-guard-v5', { guarded_action: action, matched_count: matches.length }),
        tool_invocations: []
      }
    end

    def local_availability_response(text)
      return nil unless text.match?(/空き|空いて|都合|合わせ|候補|いつ|できれば|無理なら/)

      descriptor = local_event_descriptor(text)
      return nil if descriptor[:participant_names].empty?

      duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title])).last
      duration ||= default_duration_minutes_for_title(descriptor[:activity_title])

      dates = candidate_dates_for_request(text)
      return nil if dates.empty?

      window_start, window_end = preferred_minute_window(text)
      buffer = descriptor[:buffer_minutes].to_i
      candidates = []

      dates.each do |date|
        minute = window_start
        while minute + duration <= window_end
          start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
          end_at = start_at + duration.minutes

          if free_for_all?(start_at, end_at, participant_names: descriptor[:participant_names], buffer_minutes: buffer)
            candidates << local_event_hash(
              title: descriptor[:title],
              start_at: start_at,
              end_at: end_at,
              all_day: false,
              color: color_for_local_title(descriptor[:title]),
              category: category_for_local_title(descriptor[:title]),
              intent: intent_for_local_title(descriptor[:title]),
              schedule_profile: profile_for_local_title(descriptor[:title]),
              reason: "#{descriptor[:participant_names].join('・')}と重なりにくい空き時間として候補を出しました。",
              contact_name: descriptor[:contact_name],
              participant_names: descriptor[:participant_names],
              location: descriptor[:location],
              buffer_minutes: buffer
            )
            break if candidates.length >= 3
          end

          minute += 30
        end
        break if candidates.length >= 3
      end

      return nil if candidates.empty?

      build_local_candidates_response(
        assistant_message: "#{descriptor[:participant_names].join('・')}との空き時間を見て、#{candidates.length}件の候補を出しました。",
        reason: '自分と相手の予定・相手の空き時間条件・前後バッファを見て候補を選びました。',
        events: candidates,
        provider: 'rails-local-peer-availability-v5'
      )
    end

    def local_multi_event_response(text)
      items = parse_local_event_items(text)
      return nil unless items.length >= 2

      events = items.map do |item|
        build_local_event_payload(
          title: item[:title],
          date: item[:date],
          text: item[:text],
          start_minute: item[:start_minute],
          duration_minutes: item[:duration_minutes],
          default_duration: item[:duration_minutes] || default_duration_minutes_for_title(item[:activity_title]),
          contact_name: item[:contact_name],
          participant_names: item[:participant_names],
          location: item[:location],
          buffer_minutes: item[:buffer_minutes],
          all_day: false
        )
      end.compact

      return nil unless events.length >= 2

      build_local_bundle_response(
        title: "予定まとめ（#{events.length}件）",
        assistant_message: "#{events.length}件の予定候補をまとめて作成しました。",
        reason: '複数の日付・予定名・相手名を読み取り、まとめて予定候補にしました。',
        events: events,
        provider: 'rails-local-multi-event-v5'
      )
    end

    def local_single_explicit_event_response(text)
      date = first_local_date_from_text(text)
      return nil unless date

      descriptor = local_event_descriptor(text)
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      event = build_local_event_payload(
        title: descriptor[:title],
        date: date,
        text: text,
        start_minute: start_minute,
        duration_minutes: duration,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes],
        all_day: false
      )

      build_local_bundle_response(
        title: descriptor[:title],
        assistant_message: "#{date.strftime('%-m/%-d')} #{minute_label(start_minute)}から#{duration}分の#{descriptor[:title]}として候補を作成しました。",
        reason: '日付・開始時刻・所要時間を読み取り、指定に合わせた予定候補にしました。',
        events: [event],
        provider: 'rails-local-single-explicit-v5'
      )
    end

    def local_date_range_response(text)
      match = text.match(/(?:(?<sy>\d{4})年)?(?<sm>1[0-2]|0?[1-9])(?:月|[\/\-])(?<sd>3[01]|[12]\d|0?[1-9])日?\s*(?:から|〜|~|-)\s*(?:(?<ey>\d{4})年)?(?:(?<em>1[0-2]|0?[1-9])(?:月|[\/\-]))?(?<ed>3[01]|[12]\d|0?[1-9])日?(?:まで)?(?<tail>[^、。]*)/)
      return nil unless match

      now = context_now
      start_date = local_date_from_parts(year: match[:sy], month: match[:sm], day: match[:sd], now: now)
      end_date = local_date_from_parts(year: match[:ey] || match[:sy], month: match[:em] || match[:sm], day: match[:ed], now: now)
      return nil unless start_date && end_date

      end_date = Date.new(end_date.year + 1, end_date.month, end_date.day) if end_date < start_date
      descriptor = local_event_descriptor(match[:tail].presence || text, fallback_title: local_title_from_text(text))

      start_at = app_time_zone.local(start_date.year, start_date.month, start_date.day, 0, 0, 0)
      exclusive_end = end_date + 1
      end_at = app_time_zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day, 0, 0, 0)

      event = local_event_hash(
        title: descriptor[:title],
        start_at: start_at,
        end_at: end_at,
        all_day: true,
        color: color_for_local_title(descriptor[:title]),
        category: category_for_local_title(descriptor[:title]),
        intent: intent_for_local_title(descriptor[:title]),
        schedule_profile: profile_for_local_title(descriptor[:title]),
        reason: "#{start_date.strftime('%-m/%-d')}から#{end_date.strftime('%-m/%-d')}までの期間予定として候補を作成しました。",
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes]
      )

      build_local_bundle_response(
        title: descriptor[:title],
        assistant_message: "#{start_date.strftime('%-m/%-d')}から#{end_date.strftime('%-m/%-d')}までの#{descriptor[:title]}として候補を作成しました。",
        reason: event['reason'],
        events: [event],
        provider: 'rails-local-date-range-v5'
      )
    end

    def local_recurrence_response(text)
      return nil unless text.match?(/毎週|隔週|毎月/)

      local_monthly_nth_weekday_response(text) ||
        local_monthly_day_response(text) ||
        local_weekly_or_biweekly_response(text)
    end

    def local_weekly_or_biweekly_response(text)
      return nil unless text.match?(/毎週|隔週/)

      weekdays = target_weekdays(text)
      return nil if weekdays.empty?

      interval = text.include?('隔週') ? 2 : 1
      now = context_now
      descriptor = local_event_descriptor(text, fallback_title: '定例')
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      events = []
      weekdays.each do |weekday|
        first = next_weekday_on_or_after(now.to_date, weekday)
        8.times do |i|
          date = first + (i * interval * 7)
          events << build_local_event_payload(
            title: descriptor[:title],
            date: date,
            text: text,
            start_minute: start_minute,
            duration_minutes: duration,
            default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
            contact_name: descriptor[:contact_name],
            participant_names: descriptor[:participant_names],
            location: descriptor[:location],
            buffer_minutes: descriptor[:buffer_minutes],
            all_day: false
          )
        end
      end

      label = interval == 2 ? '隔週' : '毎週'
      build_local_bundle_response(
        title: "#{descriptor[:title]}（#{label}）",
        assistant_message: "#{label}の#{descriptor[:title]}として、#{events.length}件の予定候補を作成しました。",
        reason: "#{label}の繰り返し予定として候補をまとめました。",
        events: events.sort_by { |event| event['start_at'].to_s }.first(16),
        provider: 'rails-local-weekly-recurrence-v5'
      )
    end

    def local_monthly_nth_weekday_response(text)
      match = text.match(/毎月第(?<ordinal>[1-5一二三四五])(?<weekday>[月火水木金土日])(?:曜|曜日)?/)
      return nil unless match

      ordinal = japanese_ordinal_to_i(match[:ordinal])
      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless ordinal && weekday

      descriptor = local_event_descriptor(text, fallback_title: '定例')
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      dates = []
      year = context_now.year
      month = context_now.month
      12.times do
        date = nth_weekday_date(year, month, weekday, ordinal)
        dates << date if date && date >= context_now.to_date
        year, month = add_months(year, month, 1)
        break if dates.length >= 6
      end

      events = dates.map do |date|
        build_local_event_payload(
          title: descriptor[:title],
          date: date,
          text: text,
          start_minute: start_minute,
          duration_minutes: duration,
          default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          all_day: false
        )
      end

      build_local_bundle_response(
        title: "#{descriptor[:title]}（毎月第#{ordinal}#{match[:weekday]}曜）",
        assistant_message: "毎月第#{ordinal}#{match[:weekday]}曜の#{descriptor[:title]}として、#{events.length}件の予定候補を作成しました。",
        reason: '毎月第n曜日の繰り返し予定として候補をまとめました。',
        events: events,
        provider: 'rails-local-monthly-nth-weekday-v5'
      )
    end

    def local_monthly_day_response(text)
      match = text.match(/毎月(?<day>3[01]|[12]\d|0?[1-9])日/)
      return nil unless match

      day = match[:day].to_i
      descriptor = local_event_descriptor(text, fallback_title: '予定')
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
      start_minute ||= default_start_minute_for_title(descriptor[:activity_title])

      dates = []
      year = context_now.year
      month = context_now.month
      12.times do
        begin
          date = Date.new(year, month, day)
          dates << date if date >= context_now.to_date
        rescue Date::Error
        end
        year, month = add_months(year, month, 1)
        break if dates.length >= 6
      end

      events = dates.map do |date|
        build_local_event_payload(
          title: descriptor[:title],
          date: date,
          text: text,
          start_minute: start_minute,
          duration_minutes: duration,
          default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          all_day: false
        )
      end

      build_local_bundle_response(
        title: "#{descriptor[:title]}（毎月#{day}日）",
        assistant_message: "毎月#{day}日の#{descriptor[:title]}として、#{events.length}件の予定候補を作成しました。",
        reason: '毎月指定日の繰り返し予定として候補をまとめました。',
        events: events,
        provider: 'rails-local-monthly-day-v5'
      )
    end

    def build_local_bundle_response(title:, assistant_message:, reason:, events:, provider:)
      first = events.first
      {
        assistant_message: assistant_message,
        recommendations: [
          {
            'kind' => 'draft_event',
            'title' => title,
            'description' => first['description'],
            'reason' => reason,
            'start_at' => first['start_at'],
            'end_at' => first['end_at'],
            'all_day' => first['all_day'],
            'payload' => first.merge('events' => events)
          }
        ],
        provider: provider,
        policy_run: local_policy_run(provider, { recommendation_count: 1, bundled_event_count: events.length }),
        tool_invocations: []
      }
    end

    def build_local_candidates_response(assistant_message:, reason:, events:, provider:)
      {
        assistant_message: assistant_message,
        recommendations: events.map do |event|
          {
            'kind' => 'draft_event',
            'title' => event['title'],
            'description' => event['description'],
            'reason' => reason,
            'start_at' => event['start_at'],
            'end_at' => event['end_at'],
            'all_day' => event['all_day'],
            'payload' => event
          }
        end,
        provider: provider,
        policy_run: local_policy_run(provider, { recommendation_count: events.length }),
        tool_invocations: []
      }
    end

    def local_policy_run(provider, metadata = {})
      {
        provider: provider,
        policy_version: provider,
        route: 'rails_local_structured_parser',
        request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
        prompt_snapshot: { user_message: @user_message, scope: context_value(:scope) },
        context_snapshot: { timezone: context_value(:timezone), now: context_value(:now) },
        result_metadata: metadata
      }
    end

    def build_local_event_payload(title:, date:, text:, start_minute: nil, duration_minutes: nil, default_duration: 60, contact_name: nil, participant_names: [], location: nil, buffer_minutes: nil, all_day: false)
      final_title = title.presence || local_event_descriptor(text)[:title]
      start_minute ||= parse_local_time_and_duration(text, default_duration: default_duration).first

      if all_day || start_minute.nil?
        start_at = app_time_zone.local(date.year, date.month, date.day, 0, 0, 0)
        end_at = start_at + 1.day
        all_day = true
      else
        duration = duration_minutes || parse_local_time_and_duration(text, default_duration: default_duration).last || default_duration
        start_at = app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
        end_at = start_at + duration.minutes
        all_day = false
      end

      local_event_hash(
        title: final_title,
        start_at: start_at,
        end_at: end_at,
        all_day: all_day,
        color: color_for_local_title(final_title),
        category: category_for_local_title(final_title),
        intent: intent_for_local_title(final_title),
        schedule_profile: profile_for_local_title(final_title),
        reason: local_reason_for_participants(participant_names),
        contact_name: contact_name,
        participant_names: participant_names,
        location: location,
        buffer_minutes: buffer_minutes
      )
    end

    def local_event_hash(title:, start_at:, end_at:, all_day:, color:, category:, intent:, schedule_profile:, reason:, contact_name: nil, participant_names: [], location: nil, buffer_minutes: nil)
      names = Array(participant_names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      payload = {
        'title' => title,
        'description' => local_description_for_payload(contact_name: contact_name, participant_names: names, buffer_minutes: buffer_minutes),
        'start_at' => start_at.iso8601,
        'end_at' => end_at.iso8601,
        'all_day' => all_day,
        'color' => color,
        'category' => category,
        'intent' => intent,
        'schedule_profile' => schedule_profile,
        'reason' => reason
      }
      payload['contact_name'] = contact_name.to_s.strip if contact_name.to_s.strip.present?
      payload['participant_names'] = names if names.any?
      payload['location'] = location.to_s.strip if location.to_s.strip.present?
      payload['buffer_minutes'] = buffer_minutes.to_i if buffer_minutes.to_i.positive?
      payload['relation_tags'] = ['contact'] if names.any? || contact_name.to_s.strip.present?
      payload
    end

    def local_description_for_payload(contact_name:, participant_names:, buffer_minutes:)
      parts = ['AI秘書提案の予定候補']
      names = Array(participant_names).presence || [contact_name].compact
      parts << "相手: #{names.join('・')}" if names.any?
      parts << "前後バッファ: #{buffer_minutes}分" if buffer_minutes.to_i.positive?
      parts.join(' / ')
    end

    def parse_local_event_items(text)
      split_event_clauses(text).filter_map do |clause|
        date = first_local_date_from_text(clause)
        next unless date
        descriptor = local_event_descriptor(clause)
        start_minute, duration = parse_local_time_and_duration(clause, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
        {
          date: date,
          title: descriptor[:title],
          activity_title: descriptor[:activity_title],
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes],
          start_minute: start_minute || default_start_minute_for_title(descriptor[:activity_title]),
          duration_minutes: duration || default_duration_minutes_for_title(descriptor[:activity_title]),
          text: clause
        }
      end
    end

    def split_event_clauses(text)
      normalize_japanese(text).split(/(?:、|。|,|;|；|そして|それから|あとで|あと)/).map(&:strip).reject(&:blank?)
    end

    def candidate_dates_for_request(text)
      normalized = normalize_japanese(text)
      now = context_now
      if normalized.include?('翌週')
        start = now.to_date + ((8 - now.wday) % 7) + 7
        return (0..4).map { |i| start + i }
      end
      if normalized.include?('来週')
        start = now.to_date + ((8 - now.wday) % 7)
        return (0..4).map { |i| start + i }
      end
      if (date = first_local_date_from_text(text))
        return [date]
      end
      (0..10).map { |i| now.to_date + i }.select { |d| d.wday.between?(1, 5) }.first(7)
    end

    def first_local_date_from_text(text)
      now = context_now
      normalized = normalize_japanese(text)

      return now.to_date if normalized.include?('今日') || normalized.include?('きょう')
      return now.to_date + 1 if normalized.include?('明日') || normalized.include?('あした')
      return now.to_date + 2 if normalized.include?('明後日') || normalized.include?('あさって')

      if normalized.include?('来月頭')
        year, month = add_months(now.year, now.month, 1)
        return Date.new(year, month, 1)
      end
      if normalized.include?('月末')
        target = Date.new(now.year, now.month, -1)
        return target >= now.to_date ? target : Date.new(*add_months(now.year, now.month, 1), -1)
      end
      if normalized.match?(/gw中|ゴールデンウィーク中/)
        target = Date.new(now.year, 5, 3)
        return target >= now.to_date ? target : Date.new(now.year + 1, 5, 3)
      end
      if normalized.match?(/gw明け|ゴールデンウィーク明け|連休明け/)
        target = Date.new(now.year, 5, 7)
        return target >= now.to_date ? target : Date.new(now.year + 1, 5, 7)
      end

      match = normalized.match(/(?:(?<year>\d{4})年)?(?<month>1[0-2]|0?[1-9])(?:月|[\/\-])(?<day>3[01]|[12]\d|0?[1-9])日?/)
      return local_date_from_parts(year: match[:year], month: match[:month], day: match[:day], now: now) if match

      match = normalized.match(/(?<!\d)(?<day>3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/)
      return local_date_from_parts(year: nil, month: now.month, day: match[:day], now: now) if match

      nil
    end

    def local_date_from_parts(year:, month:, day:, now:)
      date = Date.new(year.present? ? year.to_i : now.year, month.present? ? month.to_i : now.month, day.to_i)
      if year.blank? && date < now.to_date
        date = month.present? ? Date.new(date.year + 1, date.month, date.day) : date.next_month
      end
      date
    rescue StandardError
      nil
    end

    def local_event_descriptor(text, fallback_title: nil)
      activity_title = activity_title_from_text(text, fallback_title: fallback_title)
      names = participant_names_from_text(text)
      {
        title: compose_local_event_title(activity_title, names),
        activity_title: activity_title,
        participant_names: names,
        contact_name: names.first,
        location: extract_local_location(text),
        buffer_minutes: extract_local_buffer_minutes(text)
      }
    end

    def participant_names_from_text(text)
      normalized = normalize_japanese(text)
      names = []
      known_contact_names.each do |name|
        names << name if normalize_japanese(name).present? && normalized.include?(normalize_japanese(name))
      end
      normalized.scan(/(?<name>[^\s、。\/\d]+?(?:さん|くん|君|ちゃん)?|[a-zA-Z][a-zA-Z0-9_\-]{0,20})(?:と|との)(?=会議|定例|打ち合わせ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|予定)/) do
        name = clean_participant_name(Regexp.last_match[:name].to_s)
        names << name if valid_participant_name?(name)
      end
      names.map(&:strip).reject(&:blank?).uniq.first(4)
    end

    def known_contact_names
      contacts = Array(context_value(:contacts)).filter_map do |contact|
        next unless contact.respond_to?(:to_h)
        attrs = contact.to_h
        (attrs[:display_name] || attrs['display_name'] || attrs[:name] || attrs['name']).to_s.strip.presence
      end
      friends = Array(context_value(:friends)).filter_map do |friend|
        next unless friend.respond_to?(:to_h)
        attrs = friend.to_h
        (attrs[:name] || attrs['name'] || attrs[:display_name] || attrs['display_name']).to_s.strip.presence
      end
      (contacts + friends).uniq.sort_by { |name| -normalize_japanese(name).length }
    end

    def clean_participant_name(value)
      normalize_japanese(value).gsub(/^(?:に|は|で|を|と|、|。)+/, '').gsub(/(?:さん|くん|君|ちゃん)$/, '').strip
    end

    def valid_participant_name?(name)
      return false if name.blank? || name.length > 18 || name.match?(/\A\d+\z/)
      !%w[会議 定例 飲み会 飲み 食事 旅行 予定 レビュー 通院 病院 午後 午前 今日 明日 明後日].include?(name)
    end

    def compose_local_event_title(activity_title, names)
      names = Array(names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      names.empty? ? clean_activity_title(activity_title) : "#{names.join('・')}と#{clean_activity_title(activity_title)}"
    end

    def activity_title_from_text(text, fallback_title: nil)
      cleaned = clean_activity_title(remove_participant_phrases(remove_date_time_phrases(text)))
      return cleaned if cleaned.present? && cleaned.length <= 18 && !request_phrase_only?(cleaned)
      fallback_title.presence || local_title_from_text(text)
    end

    def remove_participant_phrases(text)
      normalized = normalize_japanese(text)
      known_contact_names.each { |name| normalized = normalized.gsub(/#{Regexp.escape(normalize_japanese(name))}(?:さん|くん|君|ちゃん)?(?:と|との)/, '') }
      normalized.gsub(/[^\s、。\/\d]+?(?:さん|くん|君|ちゃん)?(?:と|との)(?=会議|定例|打ち合わせ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|予定)/, '')
    end

    def remove_date_time_phrases(text)
      normalize_japanese(text)
        .gsub(/(?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])(?:月|[\/\-])(?:3[01]|[12]\d|0?[1-9])日?/, '')
        .gsub(/(?<!\d)(?:3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/, '')
        .gsub(/(今日|明日|明後日|来週|翌週|今週|月末|来月頭|gw中|gw明け|連休明け)/, '')
        .gsub(/(午前|午後|夕方|夜|今夜|今晩)?\s*\d{1,2}[:：]\d{2}(?:\s*(?:から|以降|まで|〜|~|-)\s*\d{1,3}(?:\.\d+)?(?:時間|分)?|\s*(?:から|以降|まで|に|開始)?)?/, '')
        .gsub(/(午前|午後|夕方|夜|今夜|今晩)?\s*\d{1,2}時(?:(?:\d{1,2})分?|半)?(?:\s*(?:から|以降|まで|〜|~|-)\s*\d{1,3}(?:\.\d+)?(?:時間|分)?|\s*(?:から|以降|まで|に|開始)?)?/, '')
        .gsub(/毎週|隔週|毎月|第[1-5一二三四五][月火水木金土日](?:曜|曜日)?/, '')
    end

    def clean_activity_title(value)
      title = normalize_japanese(value).gsub(/^(に|は|で|を)+/, '')
      title = title.gsub(/\s*(を)?(入れてください|入れて|入れる|追加してください|追加して|追加|登録してください|登録して|登録|お願いします|お願い|してください|して)\s*$/, '')
      title = title.gsub(/\s*(を|に|は|で)\s*$/, '').strip
      title.present? ? title : '予定'
    end

    def request_phrase_only?(value)
      normalize_japanese(value).match?(/\A(入れて|追加|お願い|お願いします|ください|して)+\z/)
    end

    def clean_local_title(value)
      title = clean_activity_title(value)
      title.blank? || title.length > 18 || request_phrase_only?(title) ? local_title_from_text(title) : title
    end

    def local_title_from_text(text)
      normalized = normalize_japanese(text)
      return '定例' if normalized.include?('定例')
      return '飲み会' if normalized.include?('飲み会') || normalized.include?('飲み')
      return '食事' if normalized.match?(/食事|ご飯|ごはん|ランチ|ディナー/)
      return '旅行' if normalized.include?('旅行')
      return '会議' if normalized.match?(/会議|ミーティング|打ち合わせ/)
      return 'レビュー' if normalized.include?('レビュー')
      return '通院' if normalized.match?(/通院|病院/)
      return '支払い' if normalized.include?('支払い')
      '予定'
    end

    def parse_local_time_and_duration(text, default_duration:)
      normalized = normalize_period_words(normalize_japanese(text))
      start_minute = nil
      duration = nil
      if (m = normalized.match(/(?<hour>\d{1,2})[:：](?<minute>\d{2})\s*(?:から|開始|に|以降)?/))
        start_minute = clamp_hour(m[:hour].to_i) * 60 + clamp_minute(m[:minute].to_i)
      elsif (m = normalized.match(/(?<hour>\d{1,2})時(?:(?<minute>\d{1,2})分?|(?<half>半))?\s*(?:から|開始|に|以降)?/))
        start_minute = clamp_hour(m[:hour].to_i) * 60 + (m[:half] ? 30 : clamp_minute(m[:minute].to_i))
      end
      if (m = normalized.match(/(?:から|〜|~|-)\s*(?<end_hour>\d{1,2})[:：](?<end_minute>\d{2})/)) && start_minute
        end_minute = clamp_hour(m[:end_hour].to_i) * 60 + clamp_minute(m[:end_minute].to_i)
        end_minute += 24 * 60 if end_minute <= start_minute
        duration = end_minute - start_minute
      elsif (m = normalized.match(/(?:から|〜|~|-)\s*(?<value>\d{1,3}(?:\.\d+)?)(?<unit>時間|分)?(?![\d:：時])/))
        duration = duration_value_to_minutes(m[:value], m[:unit])
      elsif (m = normalized.match(/(?<value>\d{1,3}(?:\.\d+)?)\s*時間/))
        duration = duration_value_to_minutes(m[:value], '時間')
      elsif (m = normalized.match(/(?<value>\d{1,3})\s*分/))
        duration = duration_value_to_minutes(m[:value], '分')
      end
      [start_minute, duration || default_duration]
    end

    def normalize_period_words(text)
      normalize_japanese(text)
        .gsub(/(午前|朝)\s*12時/, '0時')
        .gsub(/(午後|夕方|夜|今夜|今晩)\s*(\d{1,2})([:：]\d{2})/) { "#{period_hour(Regexp.last_match[2].to_i)}#{Regexp.last_match[3]}" }
        .gsub(/(午後|夕方|夜|今夜|今晩)\s*(\d{1,2})時/) { "#{period_hour(Regexp.last_match[2].to_i)}時" }
        .gsub(/(午前|朝)\s*(\d{1,2})時/) { "#{Regexp.last_match[2].to_i}時" }
    end

    def preferred_minute_window(text)
      normalized = normalize_period_words(normalize_japanese(text))
      return [13 * 60, 18 * 60] if normalized.include?('午後')
      return [9 * 60, 12 * 60] if normalized.match?(/午前|朝/)
      return [17 * 60, 20 * 60] if normalized.include?('夕方')
      return [18 * 60, 22 * 60] if normalized.match?(/夜|今夜|今晩/)
      [9 * 60, 18 * 60]
    end

    def free_for_all?(start_at, end_at, participant_names:, buffer_minutes: 0)
      check_start = start_at - buffer_minutes.to_i.minutes
      check_end = end_at + buffer_minutes.to_i.minutes
      return false if conflicts_with_events?(context_value(:personal_events), check_start, check_end)
      return false if conflicts_with_events?(matching_peer_events(participant_names), check_start, check_end)
      return false unless fits_contact_profiles?(participant_names, start_at, end_at)
      true
    end

    def conflicts_with_events?(events, start_at, end_at)
      Array(events).any? do |event|
        next false unless event.respond_to?(:to_h)
        attrs = event.to_h
        s = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
        e = app_time_zone.parse((attrs[:end_at] || attrs['end_at']).to_s) rescue nil
        s && e && e > start_at && s < end_at
      end
    end

    def matching_peer_events(names)
      normalized_names = Array(names).map { |name| normalize_japanese(name) }.reject(&:blank?)
      Array(context_value(:peer_events)).select do |event|
        peer_name = normalize_japanese(event[:peer_name] || event['peer_name'])
        normalized_names.any? { |name| peer_name.include?(name) || name.include?(peer_name) }
      end
    end

    def fits_contact_profiles?(names, start_at, end_at)
      contacts = Array(context_value(:contacts)).select do |contact|
        name = normalize_japanese(contact[:display_name] || contact['display_name'])
        Array(names).any? { |n| name.include?(normalize_japanese(n)) || normalize_japanese(n).include?(name) }
      end
      return true if contacts.empty?
      contacts.all? do |contact|
        profiles = Array(contact[:availability_profiles] || contact['availability_profiles'])
        next true if profiles.empty?
        profiles.any? do |profile|
          attrs = profile.to_h
          weekday = attrs[:weekday] || attrs['weekday']
          start_minute = attrs[:start_minute] || attrs['start_minute']
          end_minute = attrs[:end_minute] || attrs['end_minute']
          weekday.to_i == start_at.wday && start_minute.to_i <= start_at.hour * 60 + start_at.min && end_minute.to_i >= end_at.hour * 60 + end_at.min
        end
      end
    end

    def matched_existing_events(text)
      date = first_local_date_from_text(text)
      title = local_title_from_text(text)
      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)
        attrs = event.to_h
        event_title = attrs[:title] || attrs['title']
        start_at = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
        title_match = title.blank? || event_title.to_s.include?(title)
        date_match = date.blank? || (start_at && start_at.to_date == date)
        title_match && date_match
      end
    end

    def format_event_for_message(event)
      attrs = event.to_h
      start_at = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
      title = attrs[:title] || attrs['title']
      start_at ? "#{start_at.strftime('%-m/%-d %H:%M')} #{title}" : title.to_s
    end

    def extract_local_location(text)
      m = normalize_japanese(text).match(/(?<location>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,20})で(?=会議|定例|打ち合わせ|ミーティング|飲み会|食事|旅行|通院|レビュー|予定)/)
      return nil unless m
      m[:location]
    end

    def extract_local_buffer_minutes(text)
      normalized = normalize_japanese(text)
      return Regexp.last_match[:minutes].to_i if normalized.match(/前後\s*(?<minutes>\d{1,3})\s*分/)
      return Regexp.last_match[:minutes].to_i if normalized.match(/(?<minutes>\d{1,3})\s*分\s*(?:空けて|あけて|バッファ)/)
      nil
    end

    def local_reason_for_participants(names)
      names = Array(names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      names.empty? ? '指定内容に合わせて予定候補を作成しました。' : "#{names.join('・')}との予定として候補を作成しました。"
    end

    def period_hour(hour)
      (1..11).include?(hour) ? hour + 12 : hour
    end

    def duration_value_to_minutes(value, unit)
      number = value.to_f
      minutes = if unit.to_s.include?('分')
                  number.round
                elsif unit.to_s.include?('時間')
                  (number * 60).round
                elsif number <= 12
                  (number * 60).round
                else
                  number.round
                end
      [[minutes, 15].max, 480].min
    end

    def clamp_hour(value)
      [[value, 0].max, 23].min
    end

    def clamp_minute(value)
      [[value, 0].max, 59].min
    end

    def next_weekday_on_or_after(date, weekday)
      date + ((weekday - date.wday) % 7)
    end

    def add_months(year, month, count)
      index = year * 12 + (month - 1) + count
      [index / 12, index % 12 + 1]
    end

    def nth_weekday_date(year, month, weekday, ordinal)
      first = Date.new(year, month, 1)
      date = first + ((weekday - first.wday) % 7) + ((ordinal - 1) * 7)
      date.month == month ? date : nil
    rescue StandardError
      nil
    end

    def japanese_ordinal_to_i(value)
      { '一' => 1, '二' => 2, '三' => 3, '四' => 4, '五' => 5 }.fetch(value.to_s, value.to_i)
    end

    def minute_label(minute)
      "#{minute / 60}:#{(minute % 60).to_s.rjust(2, '0')}"
    end

    def default_start_minute_for_title(title)
      title.to_s.match?(/飲み|食事|ランチ|ディナー/) ? 18 * 60 : 9 * 60
    end

    def default_duration_minutes_for_title(title)
      case title
      when /飲み|食事/ then 120
      when /旅行/ then 240
      when /定例|会議|調整|レビュー/ then 60
      else 60
      end
    end

    def color_for_local_title(title)
      title.to_s.match?(/飲み|食事|旅行/) ? '#f97316' : '#3b82f6'
    end

    def category_for_local_title(title)
      title.to_s.match?(/飲み|食事|旅行/) ? 'leisure' : 'work'
    end

    def intent_for_local_title(title)
      case title
      when /飲み|食事/ then 'meal'
      when /旅行/ then 'travel'
      when /定例|会議/ then 'meeting'
      else 'general'
      end
    end

    def profile_for_local_title(title)
      title.to_s.match?(/飲み|食事/) ? 'social' : (title.to_s.match?(/旅行/) ? 'travel' : 'work')
    end

    # === END CF_LOCAL_STRUCTURED_AI_V5 ===




    def request_remote
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      uri = URI.parse("#{service_url}/chat/respond")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 3
      http.read_timeout = DEFAULT_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(
        {
          scope: context_value(:scope),
          user_message: @user_message,
          refresh_only: @refresh_only,
          context: @context
        }
      )

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "AI service error: HTTP #{response.code}"
      end

      parsed = JSON.parse(response.body)
      duration_ms = elapsed_ms(started_at)
      provider = parsed['provider'].presence || 'rules-v4-work-intent'

      {
        assistant_message: parsed['assistant_message'].to_s,
        recommendations: Array(parsed['recommendations']),
        provider: provider,
        policy_run: normalize_policy_run(parsed['policy_run'], provider: provider, duration_ms: duration_ms),
        tool_invocations: normalize_tool_invocations(parsed['tool_invocations'])
      }
    end

    def service_url
      explicit_url = ENV['AI_SERVICE_URL'].to_s.strip
      return explicit_url if explicit_url.present?

      internal_hostport = ENV['AI_SERVICE_HOSTPORT'].to_s.strip
      return "http://#{internal_hostport}" if internal_hostport.present?

      'http://127.0.0.1:8001'
    end

    def fallback_response(error)
      candidate_events = Array(context_value(:candidate_group_events)).first(3)
      recommendations = candidate_events.map do |event|
        {
          'kind' => 'group_event_copy',
          'title' => event[:title] || event['title'],
          'description' => event[:description] || event['description'],
          'reason' => 'AIサービスに接続できなかったため、所属グループの近日イベントを候補表示しています。',
          'start_at' => event[:start_at] || event['start_at'],
          'end_at' => event[:end_at] || event['end_at'],
          'all_day' => event[:all_day] || event['all_day'],
          'source_event_id' => event[:id] || event['id'],
          'payload' => {
            source_event_id: event[:id] || event['id'],
            title: event[:title] || event['title'],
            description: event[:description] || event['description'],
            start_at: event[:start_at] || event['start_at'],
            end_at: event[:end_at] || event['end_at'],
            all_day: event[:all_day] || event['all_day'],
            location: event[:location] || event['location'],
            color: event[:color] || event['color']
          }
        }
      end

      message = if recommendations.any?
                  'AIサービスに接続できませんでした。代わりに、近日のグループイベント候補を表示します。'
                else
                  'AIサービスに接続できませんでした。少し時間をおいて再試行してください。'
                end

      {
        assistant_message: message,
        recommendations: recommendations,
        provider: 'rails-fallback',
        policy_run: {
          provider: 'rails-fallback',
          policy_version: 'rails-fallback',
          route: 'fallback',
          request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
          prompt_snapshot: {
            user_message: @user_message,
            refresh_only: @refresh_only,
            scope: context_value(:scope)
          },
          context_snapshot: {
            scope: context_value(:scope),
            candidate_group_event_count: Array(context_value(:candidate_group_events)).size,
            contact_count: Array(context_value(:contacts)).size,
            friend_count: Array(context_value(:friends)).size
          },
          result_metadata: {
            error_class: error.class.name,
            error_message: error.message,
            recommendation_count: recommendations.length,
            fallback: true
          }
        },
        tool_invocations: [
          {
            tool_name: 'rails_fallback_candidate_events',
            status: 'fallback',
            position: 1,
            input_payload: {
              candidate_group_event_count: Array(context_value(:candidate_group_events)).size
            },
            output_payload: {
              recommendation_count: recommendations.length
            },
            metadata: {
              error_class: error.class.name,
              error_message: error.message
            }
          }
        ]
      }
    end

    def normalize_policy_run(raw_policy_run, provider:, duration_ms:)
      raw = raw_policy_run.to_h.stringify_keys
      {
        provider: raw['provider'].presence || provider,
        policy_version: raw['policy_version'].presence || provider,
        route: raw['route'].presence || 'rules_engine',
        request_kind: raw['request_kind'].presence || (@refresh_only ? 'refresh_only' : 'chat_message'),
        duration_ms: integer_or_nil(raw['duration_ms']) || duration_ms,
        prompt_snapshot: normalize_hash(raw['prompt_snapshot']),
        context_snapshot: normalize_hash(raw['context_snapshot']),
        result_metadata: normalize_hash(raw['result_metadata'])
      }
    rescue StandardError
      {
        provider: provider,
        policy_version: provider,
        route: 'rules_engine',
        request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
        duration_ms: duration_ms,
        prompt_snapshot: {},
        context_snapshot: {},
        result_metadata: {}
      }
    end

    def normalize_tool_invocations(raw_tool_invocations)
      Array(raw_tool_invocations).each_with_index.map do |raw, index|
        attrs = raw.to_h.stringify_keys
        {
          tool_name: attrs['tool_name'].presence || attrs['name'].presence || "tool_#{index + 1}",
          status: attrs['status'].presence || 'success',
          position: integer_or_nil(attrs['position']) || index + 1,
          duration_ms: integer_or_nil(attrs['duration_ms']),
          input_payload: normalize_hash(attrs['input_payload'] || attrs['input']),
          output_payload: normalize_hash(attrs['output_payload'] || attrs['output']),
          metadata: normalize_hash(attrs['metadata'])
        }
      end
    rescue StandardError
      []
    end

    def normalize_japanese(value)
      value.to_s.unicode_normalize(:nfkc).downcase.strip
    rescue StandardError
      value.to_s.downcase.strip
    end

    def app_time_zone
      Time.zone || ActiveSupport::TimeZone['Asia/Tokyo']
    end

    def context_now
      raw = context_value(:now)
      parsed = raw.present? ? app_time_zone.parse(raw.to_s) : nil
      parsed || app_time_zone.now
    rescue StandardError
      app_time_zone.now
    end

    def context_value(key)
      @context[key] || @context[key.to_s]
    end

    def target_year_month(text, now)
      if text.include?('来月')
        target = now.to_date.next_month
        return [target.year, target.month]
      end

      return [now.year, now.month] if text.include?('今月')

      match = text.match(/(?<![0-9])(?<month>1[0-2]|0?[1-9])月/)
      return [nil, nil] unless match

      month = match[:month].to_i
      year = now.year
      year += 1 if month < now.month && !text.include?('今年')
      [year, month]
    end

    def target_weekdays(text)
      weekdays = []

      WEEKDAY_MAP.each do |token, weekday|
        next if token.length == 1

        weekdays << weekday if text.include?(token) && !weekdays.include?(weekday)
      end

      text.scan(/(?<![0-9])([月火水木金土日])(?=$|[\s　、,。と\/／・･にを])/).each do |match|
        weekday = WEEKDAY_MAP[match.first]
        weekdays << weekday if weekday && !weekdays.include?(weekday)
      end

      weekdays
    end

    def dates_for_month_weekdays(year, month, weekdays, today)
      date = Date.new(year, month, 1)
      last = date.next_month
      dates = []

      while date < last
        dates << date if date >= today && weekdays.include?(date.wday)
        date += 1
      end

      dates
    end

    def secretary_labels(value)
      case value
      when Hash
        value.transform_values { |child| secretary_labels(child) }
      when Array
        value.map { |child| secretary_labels(child) }
      when String
        value.gsub('AIエージェント', 'AI秘書')
      else
        value
      end
    end

    def normalize_hash(value)
      hash = value.to_h
      hash.respond_to?(:deep_stringify_keys) ? hash.deep_stringify_keys : hash
    rescue StandardError
      {}
    end

    def integer_or_nil(value)
      Integer(value)
    rescue StandardError
      nil
    end

    def elapsed_ms(started_at)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    end
  end
end
