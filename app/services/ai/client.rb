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


    def local_structured_schedule_response
      return nil unless context_value(:scope).to_s == 'home'
      return nil if @refresh_only

      text = normalize_japanese(@user_message)
      return nil if text.blank?

      local_date_range_response(text) ||
        local_weekly_recurrence_response(text) ||
        local_multi_event_response(text) ||
        local_exact_timed_event_response(text)
    end

    def local_multi_event_response(text)
      parsed = parse_explicit_event_items(text)
      return nil unless parsed.length >= 2

      events = parsed.map do |item|
        build_local_event_payload(
          title: item[:title],
          date: item[:date],
          text: item[:text],
          default_duration: default_duration_minutes_for_title(item[:title]),
          all_day: false
        )
      end.compact

      return nil unless events.length >= 2

      build_local_bundle_response(
        title: "予定まとめ（#{events.length}件）",
        assistant_message: "#{events.length}件の予定候補をまとめて作成しました。",
        reason: "複数の日付と予定名が含まれていたため、まとめて予定候補にしました。",
        events: events,
        provider: 'rails-local-multi-event-v1'
      )
    end

    def local_weekly_recurrence_response(text)
      return nil unless text.include?('毎週')

      weekdays = target_weekdays(text)
      return nil if weekdays.empty?

      now = context_now
      title = local_title_from_text(text)
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(title))

      events = []
      weekdays.each do |weekday|
        first_date = next_weekday_on_or_after(now.to_date, weekday)
        8.times do |index|
          date = first_date + (index * 7)
          events << build_local_event_payload(
            title: title,
            date: date,
            text: text,
            start_minute: start_minute,
            default_duration: duration,
            all_day: false
          )
        end
      end

      events.compact!
      return nil if events.empty?

      build_local_bundle_response(
        title: "#{title}（毎週）",
        assistant_message: "毎週の#{title}として、#{events.length}件の予定候補を作成しました。",
        reason: "毎週の繰り返し予定として候補をまとめました。",
        events: events.sort_by { |event| event['start_at'].to_s }.first(16),
        provider: 'rails-local-weekly-recurrence-v1'
      )
    end

    def local_date_range_response(text)
      match = text.match(/(?:(?<sy>\d{4})年)?(?<sm>1[0-2]|0?[1-9])(?:月|[\/-])(?<sd>3[01]|[12]\d|0?[1-9])日?\s*(?:から|〜|~|-)\s*(?:(?<ey>\d{4})年)?(?:(?<em>1[0-2]|0?[1-9])(?:月|[\/-]))?(?<ed>3[01]|[12]\d|0?[1-9])日?(?:まで)?(?<tail>[^、。]*)/)
      return nil unless match

      now = context_now
      start_date = local_date_from_parts(year: match[:sy], month: match[:sm], day: match[:sd], now: now)
      end_date = local_date_from_parts(year: match[:ey] || match[:sy], month: match[:em] || match[:sm], day: match[:ed], now: now)

      return nil unless start_date && end_date
      end_date += 1.year if end_date < start_date

      title = clean_local_title(match[:tail].presence || local_title_from_text(text))
      title = '旅行' if title.blank? && text.include?('旅行')
      title = '外出予定' if title.blank?

      start_at = app_time_zone.local(start_date.year, start_date.month, start_date.day, 0, 0, 0)
      end_exclusive = end_date + 1
      end_at = app_time_zone.local(end_exclusive.year, end_exclusive.month, end_exclusive.day, 0, 0, 0)

      event = local_event_hash(
        title: title,
        start_at: start_at,
        end_at: end_at,
        all_day: true,
        color: '#14b8a6',
        category: 'travel',
        intent: 'travel',
        schedule_profile: 'travel',
        reason: "#{start_date.strftime('%-m/%-d')}から#{end_date.strftime('%-m/%-d')}までの期間予定として候補を作成しました。"
      )

      build_local_bundle_response(
        title: title,
        assistant_message: "#{start_date.strftime('%-m/%-d')}から#{end_date.strftime('%-m/%-d')}までの#{title}として候補を作成しました。",
        reason: event['reason'],
        events: [event],
        provider: 'rails-local-date-range-v1'
      )
    end

    def local_exact_timed_event_response(text)
      date = first_local_date_from_text(text)
      return nil unless date

      start_minute, duration = parse_local_time_and_duration(text, default_duration: nil)
      return nil unless start_minute

      title = local_title_from_text(text)
      duration ||= default_duration_minutes_for_title(title)

      event = build_local_event_payload(
        title: title,
        date: date,
        text: text,
        start_minute: start_minute,
        default_duration: duration,
        all_day: false
      )
      return nil unless event

      build_local_bundle_response(
        title: title,
        assistant_message: "#{date.strftime('%-m/%-d')} #{minute_label(start_minute)}から#{duration}分の#{title}として候補を作成しました。",
        reason: "日付・開始時刻・所要時間が明示されていたため、指定どおりの予定候補にしました。",
        events: [event],
        provider: 'rails-local-exact-timed-event-v1'
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
            'payload' => {
              'title' => title,
              'description' => first['description'],
              'start_at' => first['start_at'],
              'end_at' => first['end_at'],
              'all_day' => first['all_day'],
              'color' => first['color'],
              'category' => first['category'],
              'intent' => first['intent'],
              'schedule_profile' => first['schedule_profile'],
              'events' => events
            }
          }
        ],
        provider: provider,
        policy_run: {
          provider: provider,
          policy_version: provider,
          route: 'rails_local_structured_parser',
          request_kind: @refresh_only ? 'refresh_only' : 'chat_message',
          prompt_snapshot: { user_message: @user_message, scope: context_value(:scope) },
          context_snapshot: { timezone: context_value(:timezone), now: context_value(:now) },
          result_metadata: { recommendation_count: 1, bundled_event_count: events.length }
        },
        tool_invocations: []
      }
    end

    def build_local_event_payload(title:, date:, text:, start_minute: nil, default_duration: 60, all_day: false)
      start_minute ||= parse_local_time_and_duration(text, default_duration: default_duration).first

      if all_day || start_minute.nil?
        start_at = app_time_zone.local(date.year, date.month, date.day, 0, 0, 0)
        end_at = start_at + 1.day
        all_day = true
      else
        duration = parse_local_time_and_duration(text, default_duration: default_duration).last || default_duration
        start_at = app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
        end_at = start_at + duration.minutes
        all_day = false
      end

      local_event_hash(
        title: title,
        start_at: start_at,
        end_at: end_at,
        all_day: all_day,
        color: color_for_local_title(title),
        category: category_for_local_title(title),
        intent: intent_for_local_title(title),
        schedule_profile: profile_for_local_title(title),
        reason: "指定内容に合わせて予定候補を作成しました。"
      )
    end

    def local_event_hash(title:, start_at:, end_at:, all_day:, color:, category:, intent:, schedule_profile:, reason:)
      {
        'title' => title,
        'description' => 'AI秘書提案の予定候補',
        'start_at' => start_at.iso8601,
        'end_at' => end_at.iso8601,
        'all_day' => all_day,
        'color' => color,
        'category' => category,
        'intent' => intent,
        'schedule_profile' => schedule_profile,
        'reason' => reason
      }
    end

    def parse_explicit_event_items(text)
      now = context_now
      rows = []

      text.scan(/(?:(?<year>\d{4})年)?(?<month>1[0-2]|0?[1-9])(?:月|[\/-])(?<day>3[01]|[12]\d|0?[1-9])日?\s*(?:に|は|で)?(?<tail>[^、。]+)/) do
        match = Regexp.last_match
        date = local_date_from_parts(year: match[:year], month: match[:month], day: match[:day], now: now)
        next unless date

        tail = match[:tail].to_s
        rows << { date: date, title: clean_local_title(tail), text: tail }
      end

      return rows if rows.length >= 2

      text.scan(/(?<!\d)(?<day>3[01]|[12]\d|0?[1-9])日\s*(?:に|は|で)?(?<tail>[^、。]+)/) do
        match = Regexp.last_match
        date = local_date_from_parts(year: nil, month: now.month, day: match[:day], now: now)
        next unless date

        tail = match[:tail].to_s
        rows << { date: date, title: clean_local_title(tail), text: tail }
      end

      rows.uniq { |row| [row[:date], row[:title]] }.select { |row| row[:title].present? }
    end

    def first_local_date_from_text(text)
      now = context_now

      match = text.match(/(?:(?<year>\d{4})年)?(?<month>1[0-2]|0?[1-9])(?:月|[\/-])(?<day>3[01]|[12]\d|0?[1-9])日?/)
      if match
        return local_date_from_parts(year: match[:year], month: match[:month], day: match[:day], now: now)
      end

      match = text.match(/(?<!\d)(?<day>3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/)
      if match
        return local_date_from_parts(year: nil, month: now.month, day: match[:day], now: now)
      end

      nil
    end

    def local_date_from_parts(year:, month:, day:, now:)
      return nil if day.blank?

      target_year = year.present? ? year.to_i : now.year
      target_month = month.present? ? month.to_i : now.month
      target_day = day.to_i

      date = Date.new(target_year, target_month, target_day)
      if year.blank? && date < now.to_date
        date = month.present? ? Date.new(target_year + 1, target_month, target_day) : date.next_month
      end
      date
    rescue StandardError
      nil
    end

    def parse_local_time_and_duration(text, default_duration:)
      normalized = normalize_japanese(text)
      normalized = normalize_period_words(normalized)

      start_minute = nil
      duration = nil

      if (match = normalized.match(/(?<hour>\d{1,2})[:：](?<minute>\d{2})\s*(?:から|開始|に|以降)?/))
        start_minute = clamp_hour(match[:hour].to_i) * 60 + clamp_minute(match[:minute].to_i)
      elsif (match = normalized.match(/(?<hour>\d{1,2})時(?:(?<minute>\d{1,2})分?|(?<half>半))?\s*(?:から|開始|に|以降)?/))
        start_minute = clamp_hour(match[:hour].to_i) * 60 + (match[:half] ? 30 : clamp_minute(match[:minute].to_i))
      end

      if (match = normalized.match(/(?:から|〜|~|-)\s*(?<value>\d{1,3}(?:\.\d+)?)(?<unit>時間|分)?(?![\d:：時])/))
        duration = duration_value_to_minutes(match[:value], match[:unit])
      elsif (match = normalized.match(/(?<value>\d{1,3}(?:\.\d+)?)\s*時間/))
        duration = duration_value_to_minutes(match[:value], '時間')
      elsif (match = normalized.match(/(?<value>\d{1,3})\s*分/))
        duration = duration_value_to_minutes(match[:value], '分')
      end

      [start_minute, duration || default_duration]
    end

    def normalize_period_words(text)
      text.gsub(/(午前|朝)\s*12時/, '0時')
          .gsub(/(午後|夕方|夜|今夜|今晩)\s*(\d{1,2})([:：]\d{2})/) { "#{period_hour($2.to_i)}#{$3}" }
          .gsub(/(午後|夕方|夜|今夜|今晩)\s*(\d{1,2})時/) { "#{period_hour($2.to_i)}時" }
          .gsub(/(午前|朝)\s*(\d{1,2})時/) { "#{$2.to_i}時" }
    end

    def period_hour(hour)
      return hour + 12 if (1..11).include?(hour)
      hour
    end

    def duration_value_to_minutes(value, unit)
      number = value.to_f
      if unit.to_s.include?('分')
        [[number.round, 15].max, 480].min
      elsif unit.to_s.include?('時間')
        [[(number * 60).round, 15].max, 480].min
      elsif number <= 12
        [[(number * 60).round, 15].max, 480].min
      else
        [[number.round, 15].max, 480].min
      end
    end

    def clamp_hour(value)
      [[value, 0].max, 23].min
    end

    def clamp_minute(value)
      [[value, 0].max, 59].min
    end

    def next_weekday_on_or_after(date, weekday)
      delta = (weekday - date.wday) % 7
      date + delta
    end

    def minute_label(minute)
      "#{minute / 60}:#{(minute % 60).to_s.rjust(2, '0')}"
    end

    def local_title_from_text(text)
      return '定例' if text.include?('定例')
      return '飲み会' if text.include?('飲み')
      return '旅行' if text.include?('旅行')
      return '会議' if text.include?('会議') || text.include?('ミーティング')
      return 'レビュー' if text.include?('レビュー')
      return '通院' if text.include?('通院') || text.include?('病院')
      return '予定'
    end

    def clean_local_title(value)
      title = normalize_japanese(value)
      title = title.gsub(/^(に|は|で|を)+/, '')
      title = title.gsub(/(を)?(入れて|入れる|追加して|追加|お願いします|お願い|ください|して)+$/, '')
      title = title.gsub(/^\s+|\s+$/, '')
      title = local_title_from_text(title) if title.blank? || title.length > 18
      title
    end

    def default_duration_minutes_for_title(title)
      case title
      when /飲み|食事|旅行/
        120
      when /定例|会議|調整|レビュー/
        60
      when /通院|病院/
        60
      else
        60
      end
    end

    def color_for_local_title(title)
      case title
      when /飲み|食事|旅行/
        '#f97316'
      else
        '#3b82f6'
      end
    end

    def category_for_local_title(title)
      case title
      when /飲み|旅行/
        'leisure'
      else
        'work'
      end
    end

    def intent_for_local_title(title)
      case title
      when /飲み|食事/
        'meal'
      when /旅行/
        'travel'
      when /定例|会議/
        'meeting'
      else
        'general'
      end
    end

    def profile_for_local_title(title)
      case title
      when /飲み|食事/
        'social'
      when /旅行/
        'travel'
      else
        'work'
      end
    end


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
