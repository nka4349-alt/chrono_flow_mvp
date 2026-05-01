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
