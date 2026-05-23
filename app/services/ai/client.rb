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
      return secretary_labels(apply_user_text_title_overrides(structured_response)) if structured_response

      secretary_labels(apply_user_text_title_overrides(request_remote))
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

      invalid_explicit_date_response(text) ||
        invalid_explicit_time_response(text) ||
        invalid_time_range_response(text) ||
        local_negative_reminder_response(text) ||
        invalid_duration_response(text) ||
        local_temporal_contradiction_response(text) ||
        local_schedule_summary_response(text) ||
        local_schedule_organization_response(text) ||
        local_existing_event_delete_erase_response(text) ||
        local_between_existing_events_response(text) ||
        local_phase45_ambiguous_schedule_clarification_response(text) ||
        local_ambiguous_schedule_clarification_response(text) ||
        local_recurrence_response(text) ||
        local_weekend_period_response(text) ||
        local_travel_time_assist_response(text) ||
        local_same_date_multi_explicit_time_response(text) ||
        local_same_date_multi_time_response(text) ||
        local_focus_work_response(text) ||
        local_open_slot_response(text) ||
        local_event_reminder_response(text) ||
        local_existing_event_change_response(text) ||
        past_datetime_response(text) ||
        past_explicit_datetime_response(text) ||
        local_explicit_event_conflict_response(text) ||
        local_single_explicit_event_response(text, require_explicit_time: true) ||
        local_availability_response(text) ||
        local_date_range_response(text) ||
        local_multi_event_response(text) ||
        local_single_explicit_event_response(text)
    end

    # 既存予定の変更・削除は、対象候補の検出まで。自動実行はしない。
    def local_same_date_multi_time_response(text)
      date = first_local_date_from_text(text)
      return nil unless date

      segments = same_date_time_segments(text)
      return nil unless segments.length >= 2

      events = segments.map do |segment|
        descriptor = local_event_descriptor(segment[:descriptor_text], fallback_title: segment[:activity_title])
        activity_title = segment[:activity_title].presence || descriptor[:activity_title]
        title = compose_local_event_title(activity_title, descriptor[:participant_names])

        start_at = app_time_zone.local(
          date.year,
          date.month,
          date.day,
          segment[:start_minute] / 60,
          segment[:start_minute] % 60,
          0
        )
        end_at = start_at + segment[:duration_minutes].minutes

        local_event_hash(
          title: title,
          start_at: start_at,
          end_at: end_at,
          all_day: false,
          color: color_for_local_title(title),
          category: category_for_local_title(title),
          intent: intent_for_local_title(title),
          schedule_profile: profile_for_local_title(title),
          reason: '同じ日付内の複数時間指定を読み取り、予定候補を作成しました。',
          contact_name: descriptor[:contact_name],
          participant_names: descriptor[:participant_names],
          location: descriptor[:location],
          buffer_minutes: descriptor[:buffer_minutes]
        )
      end.compact

      return nil unless events.length >= 2

      build_local_bundle_response(
        title: "予定まとめ（#{events.length}件）",
        assistant_message: "#{date.strftime('%-m/%-d')}の複数時間指定を読み取り、#{events.length}件の予定候補を作成しました。",
        reason: '同じ日付の中に複数の時間帯が含まれていたため、別々の予定候補にしました。',
        events: events,
        provider: 'rails-local-same-day-multi-time-v1'
      )
    end

    def same_date_time_segments(text)
      normalized = normalize_japanese(text)
      ranges = collect_same_date_time_ranges(normalized)
      return [] if ranges.length < 2

      ranges.each_with_index.map do |range, index|
        next_range = ranges[index + 1]
        tail = normalized[range[:end_index]...(next_range ? next_range[:start_index] : normalized.length)].to_s
        activity_title = same_date_activity_title(range[:raw], tail)
        descriptor_text = [range[:raw], tail, activity_title].compact.join(' ')

        {
          start_minute: range[:start_minute],
          duration_minutes: range[:duration_minutes],
          activity_title: activity_title,
          descriptor_text: descriptor_text
        }
      end
    end

    def collect_same_date_time_ranges(text)
      normalized = normalize_period_words(normalize_japanese(text))
      ranges = []

      same_date_time_patterns.each do |kind, pattern|
        normalized.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          range = same_date_range_from_match(kind, match)
          ranges << range if range
        end
      end

      selected = []
      ranges.sort_by { |range| [range[:start_index], range[:priority], -range[:end_index]] }.each do |range|
        next if selected.any? { |existing| same_date_range_overlap?(existing, range) }

        selected << range
      end

      selected.sort_by { |range| range[:start_index] }
    end

    def same_date_time_patterns
      [
        [
          :colon_range,
          /(?:(?<start_period>午前|午後|夕方|放課後|夜|今夜|今晩)\s*)?(?<start_hour>\d{1,2})[:：](?<start_minute>\d{2})\s*(?:から|〜|~|-)\s*(?:(?<end_period>午前|午後|夕方|放課後|夜|今夜|今晩)\s*)?(?<end_hour>\d{1,2})[:：](?<end_minute>\d{2})\s*(?:まで)?/
        ],
        [
          :jp_range,
          /(?:(?<start_period>午前|午後|夕方|放課後|夜|今夜|今晩)\s*)?(?<start_hour>\d{1,2})時(?:(?<start_minute>\d{1,2})分?|(?<start_half>半))?\s*(?:から|〜|~|-)\s*(?:(?<end_period>午前|午後|夕方|放課後|夜|今夜|今晩)\s*)?(?<end_hour>\d{1,2})時(?:(?<end_minute>\d{1,2})分?|(?<end_half>半))?\s*(?:まで)?/
        ],
        [
          :colon_duration,
          /(?:(?<start_period>午前|午後|夕方|放課後|夜|今夜|今晩)\s*)?(?<start_hour>\d{1,2})[:：](?<start_minute>\d{2})\s*(?:から|〜|~|-)\s*(?<duration_value>\d{1,3}(?:\.\d+)?)(?<duration_unit>時間|分)?(?![\d:：時])/
        ],
        [
          :jp_duration,
          /(?:(?<start_period>午前|午後|夕方|放課後|夜|今夜|今晩)\s*)?(?<start_hour>\d{1,2})時(?:(?<start_minute>\d{1,2})分?|(?<start_half>半))?\s*(?:から|〜|~|-)\s*(?<duration_value>\d{1,3}(?:\.\d+)?)(?<duration_unit>時間|分)?(?![\d:：時])/
        ]
      ]
    end

    def same_date_range_from_match(kind, match)
      start_minute = same_date_time_part_to_minute(
        match[:start_hour],
        match.names.include?('start_minute') ? match[:start_minute] : nil,
        match.names.include?('start_half') ? match[:start_half] : nil,
        match.names.include?('start_period') ? match[:start_period] : nil
      )

      duration_minutes =
        case kind
        when :colon_range, :jp_range
          end_minute = same_date_time_part_to_minute(
            match[:end_hour],
            match.names.include?('end_minute') ? match[:end_minute] : nil,
            match.names.include?('end_half') ? match[:end_half] : nil,
            match.names.include?('end_period') ? match[:end_period] : nil
          )

          if end_minute <= start_minute
            if start_minute >= 12 * 60 && end_minute + 12 * 60 > start_minute
              end_minute += 12 * 60
            else
              end_minute += 24 * 60
            end
          end

          end_minute - start_minute
        else
          duration_value_to_minutes(match[:duration_value], match[:duration_unit])
        end

      return nil if duration_minutes.blank? || duration_minutes <= 0

      {
        raw: match[0],
        start_index: match.begin(0),
        end_index: match.end(0),
        start_minute: start_minute,
        duration_minutes: [[duration_minutes, 5].max, 480].min,
        priority: kind.to_s.include?('range') ? 0 : 1
      }
    end

    def same_date_time_part_to_minute(hour_value, minute_value = nil, half_value = nil, period_value = nil)
      hour = clamp_hour(hour_value.to_i)
      period = normalize_japanese(period_value)

      if period.match?(/午後|夕方|放課後|夜|今夜|今晩/)
        hour = period_hour(hour)
      elsif period.match?(/午前|朝/) && hour == 12
        hour = 0
      end

      minute = half_value.present? ? 30 : clamp_minute(minute_value.to_i)
      hour * 60 + minute
    end

    def same_date_range_overlap?(left, right)
      left[:start_index] < right[:end_index] && right[:start_index] < left[:end_index]
    end

    def same_date_activity_title(raw_range, tail)
      title = normalize_japanese(tail)
      title = title.gsub(/^\s*(の|に|は|で|を|と|、|。)+/, '')
      title = title.gsub(/\s*(と|、|。|;|；)\s*$/, '')
      title = clean_activity_title(title)
      title = title.gsub(/^\s*(の|に|は|で|を|と)+/, '')
      title = title.gsub(/\s*(と|、|。)\s*$/, '')
      title = title.strip

      if title.blank? || title == '予定' || request_phrase_only?(title) || title.length > 18
        title = local_title_from_text("#{raw_range} #{tail}")
      end

      title
    end


    def invalid_explicit_time_response(text)
      invalid_time = invalid_explicit_time_match(text)
      return nil unless invalid_time

      raw = invalid_time[:raw].to_s

      {
        assistant_message: "「#{raw}」は通常の開始時刻としては無効です。23:00などへ自動変換せず、確認が必要です。翌1:00の意味なら「翌日1時」または具体的な日付で入力し直してください。",
        recommendations: [],
        provider: 'rails-local-time-validation-v1',
        policy_run: local_policy_run('rails-local-time-validation-v1', { invalid_time: raw }),
        tool_invocations: []
      }
    end

    def invalid_explicit_date_response(text)
      invalid_date = invalid_explicit_date_match(text)
      return nil unless invalid_date

      raw = invalid_date[:raw].to_s

      {
        assistant_message: "「#{raw}」は存在しない日付です。別の日付へ自動補正せず、候補は作成しません。正しい日付を入力し直してください。",
        recommendations: [],
        provider: 'rails-local-date-validation-v1',
        policy_run: local_policy_run('rails-local-date-validation-v1', { invalid_date: raw }),
        tool_invocations: []
      }
    end

    def invalid_time_range_response(text)
      invalid_range = invalid_explicit_time_range_match(text)
      return nil unless invalid_range

      raw = invalid_range[:raw].to_s

      {
        assistant_message: "「#{raw}」は終了時刻が開始時刻より前になっています。長時間予定や翌日またぎとして自動変換せず、確認が必要です。終了時刻または「翌日」を含めて入力し直してください。",
        recommendations: [],
        provider: 'rails-local-time-range-validation-v1',
        policy_run: local_policy_run('rails-local-time-range-validation-v1', { invalid_range: raw }),
        tool_invocations: []
      }
    end

    def invalid_duration_response(text)
      invalid_duration = invalid_duration_match(text)
      return nil unless invalid_duration

      {
        assistant_message: '所要時間が0分以下のため、予定候補は作成しません。15分、30分など正の時間で指定してください。',
        recommendations: [],
        provider: 'rails-local-duration-validation-v1',
        policy_run: local_policy_run('rails-local-duration-validation-v1', { invalid_duration: invalid_duration[:raw] }),
        tool_invocations: []
      }
    end

    def local_negative_reminder_response(text)
      normalized = normalize_japanese(text)
      return nil unless reminder_request?(normalized)

      invalid = negative_reminder_offset_match(normalized)
      return nil unless invalid

      reminder_clarification_response("#{invalid}は指定できません。10分前、30分前、1時間前など正の時間で指定してください。", 0)
    end

    def local_temporal_contradiction_response(text)
      normalized = normalize_japanese(text)
      return nil if event_mutation_or_reference_request?(normalized)

      if explicit_all_day_request?(normalized) && explicit_time_present?(normalized)
        raw_time = explicit_time_matches(normalized).first
        time_label = raw_time ? raw_time[:raw].to_s : '時刻'
        return {
          assistant_message: "「終日」と「#{time_label}から」が同時に指定されています。終日予定にしますか？ それとも#{time_label}開始にしますか？ どちらにしますか？",
          recommendations: [],
          provider: 'rails-local-contradiction-all-day-time-v1',
          policy_run: local_policy_run('rails-local-contradiction-all-day-time-v1'),
          tool_invocations: []
        }
      end

      if (mismatch = explicit_date_weekday_mismatch(normalized))
        return {
          assistant_message: "#{mismatch[:date_label]}は#{mismatch[:actual_weekday]}で、指定された#{mismatch[:requested_weekday]}ではありません。正しい日付か曜日を確認してください。",
          recommendations: [],
          provider: 'rails-local-contradiction-date-weekday-v1',
          policy_run: local_policy_run('rails-local-contradiction-date-weekday-v1', mismatch),
          tool_invocations: []
        }
      end

      if morning_night_conflict_request?(normalized)
        return {
          assistant_message: '「朝」と「夜」が同時に指定されています。朝と夜のどちらに入れるか、または2件に分けるかを指定してください。',
          recommendations: [],
          provider: 'rails-local-contradiction-morning-night-v1',
          policy_run: local_policy_run('rails-local-contradiction-morning-night-v1'),
          tool_invocations: []
        }
      end

      nil
    end

    def local_phase45_ambiguous_schedule_clarification_response(text)
      normalized = normalize_japanese(text)
      return nil if event_mutation_or_reference_request?(normalized)
      return nil if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return nil if recurrence_request?(normalized)

      if vague_open_slot_without_details?(normalized)
        return {
          assistant_message: '空き時間の条件が不足しています。何を、どれくらいの時間、どの時間帯に入れたいかを指定してください。',
          recommendations: [],
          provider: 'rails-local-phase45-ambiguous-open-slot-v1',
          policy_run: local_policy_run('rails-local-phase45-ambiguous-open-slot-v1'),
          tool_invocations: []
        }
      end

      if date_only_schedule_request?(normalized)
        return {
          assistant_message: '予定の内容と時間が不足しています。何を、何時ごろ、どれくらい入れますか？',
          recommendations: [],
          provider: 'rails-local-phase45-ambiguous-date-only-v1',
          policy_run: local_policy_run('rails-local-phase45-ambiguous-date-only-v1'),
          tool_invocations: []
        }
      end

      if date_person_only_schedule_request?(normalized)
        person = clean_activity_title(remove_date_time_phrases(normalized)).presence || '相手'
        return {
          assistant_message: "#{person}との予定として受け取りましたが、内容と時間が不足しています。打ち合わせ、電話などの内容と、何時ごろかを指定してください。",
          recommendations: [],
          provider: 'rails-local-phase45-ambiguous-person-date-v1',
          policy_run: local_policy_run('rails-local-phase45-ambiguous-person-date-v1'),
          tool_invocations: []
        }
      end

      nil
    end

    def local_weekend_period_response(text)
      normalized = normalize_japanese(text)
      return nil unless weekend_period_request?(normalized)
      return nil if event_mutation_or_reference_request?(normalized)

      title_source = remove_weekend_period_phrases(text)
      descriptor = local_event_descriptor(title_source.presence || text)
      title = clean_activity_title(title_source.presence || descriptor[:activity_title].presence || descriptor[:title])
      if insufficient_activity_title?(title) || title == '予定'
        return {
          assistant_message: '土日の予定内容を教えてください。例:「土日で旅行」「来週末に帰省」のように入力してください。',
          recommendations: [],
          provider: 'rails-local-weekend-period-clarification-v1',
          policy_run: local_policy_run('rails-local-weekend-period-clarification-v1'),
          tool_invocations: []
        }
      end

      start_date = weekend_start_date_for_text(normalized)
      return nil unless start_date

      inclusive_end = start_date + 1
      start_at = app_time_zone.local(start_date.year, start_date.month, start_date.day, 0, 0, 0)
      exclusive_end = start_date + 2
      end_at = app_time_zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day, 0, 0, 0)

      event = local_event_hash(
        title: title,
        start_at: start_at,
        end_at: end_at,
        all_day: true,
        color: color_for_local_title(title),
        category: category_for_local_title(title),
        intent: intent_for_local_title(title),
        schedule_profile: profile_for_local_title(title),
        reason: "#{start_date.strftime('%-m/%-d')}から#{inclusive_end.strftime('%-m/%-d')}までの週末期間予定として候補を作成しました。",
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes]
      )

      build_local_bundle_response(
        title: title,
        assistant_message: "#{start_date.strftime('%-m/%-d')}から#{inclusive_end.strftime('%-m/%-d')}までの#{title}として終日予定候補を作成しました。",
        reason: event['reason'],
        events: [event],
        provider: 'rails-local-weekend-period-v1'
      )
    end


    def local_travel_time_assist_response(text)
      normalized = normalize_japanese(text)
      return nil unless travel_time_assist_request?(normalized)

      date = first_local_date_from_text(text)
      start_minute, event_duration = parse_local_time_and_duration(text, default_duration: 60)
      return nil unless date && start_minute

      travel_route = extract_travel_route(text)
      destination = clean_travel_place(travel_route[:destination].presence || extract_local_location(text))
      travel_minutes = travel_route[:travel_minutes]
      arrival_buffer_minutes = extract_arrival_buffer_minutes(text)

      if destination.blank? && travel_minutes.to_i.positive?
        return {
          assistant_message: '移動時間を予定に入れるには目的地が必要です。例:「自宅から大阪駅まで30分、明日10時に会議」のように指定してください。',
          recommendations: [],
          provider: 'rails-local-travel-destination-clarification-v1',
          policy_run: local_policy_run('rails-local-travel-destination-clarification-v1'),
          tool_invocations: []
        }
      end

      title_source = remove_travel_assist_phrases(text, destination: destination, origin: travel_route[:origin])
      descriptor = local_event_descriptor(title_source.presence || text)
      title = travel_assist_main_title(title_source, descriptor)
      return nil if insufficient_activity_title?(title) || title == '予定'

      # Phase 5-A: 移動時間の「30分」を本予定の所要時間として誤用しない。
      # 例: 「明日10時に大阪駅で会議、移動時間30分」は会議60分 + 移動30分。
      _schedule_start_minute, schedule_duration = parse_local_time_and_duration(title_source, default_duration: default_duration_minutes_for_title(title))
      event_duration = schedule_duration.presence || default_duration_minutes_for_title(title)

      event_start = app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
      event_end = event_start + (event_duration.presence || default_duration_minutes_for_title(title)).minutes

      main_conflicts = conflicting_events(context_value(:personal_events), event_start, event_end)
      if main_conflicts.any?
        conflict_title = event_title(main_conflicts.first)
        return {
          assistant_message: "#{event_start.strftime('%H:%M')}-#{event_end.strftime('%H:%M')}は既存予定「#{conflict_title}」と重なります。移動時間を入れる前に、会議時刻を変更するか既存予定を調整してください。",
          recommendations: [],
          provider: 'rails-local-travel-main-conflict-v1',
          policy_run: local_policy_run('rails-local-travel-main-conflict-v1', { conflict_title: conflict_title }),
          tool_invocations: []
        }
      end

      main_event = local_event_hash(
        title: title,
        start_at: event_start,
        end_at: event_end,
        all_day: false,
        color: color_for_local_title(title),
        category: category_for_local_title(title),
        intent: intent_for_local_title(title),
        schedule_profile: profile_for_local_title(title),
        reason: travel_minutes.to_i.positive? ? '場所と移動時間を考慮して予定候補を作成しました。' : '場所付き予定として候補を作成しました。',
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: destination,
        buffer_minutes: arrival_buffer_minutes.presence || descriptor[:buffer_minutes]
      )
      main_event['description'] = travel_assist_main_description(destination: destination, arrival_buffer_minutes: arrival_buffer_minutes)
      main_event['travel_assist'] = {
        'destination' => destination,
        'origin' => travel_route[:origin],
        'travel_minutes' => travel_minutes,
        'arrival_buffer_minutes' => arrival_buffer_minutes,
        'phase' => '5a'
      }.compact

      unless travel_minutes.to_i.positive?
        return build_local_candidates_response(
          assistant_message: "#{event_start.strftime('%H:%M')}に#{destination}で#{title}ですね。移動時間も予定に入れますか？ 出発地、移動時間、何分前に着きたいかを指定してください。例:「自宅から#{destination}まで30分、15分前に到着」。",
          reason: '場所付き予定として候補を作成し、移動時間追加に必要な情報を確認しています。',
          events: [main_event],
          provider: 'rails-local-travel-assist-location-v1'
        )
      end

      travel_end = event_start - arrival_buffer_minutes.to_i.minutes
      travel_start = travel_end - travel_minutes.to_i.minutes
      if travel_start < context_now
        return {
          assistant_message: "移動予定の開始時刻 #{travel_start.strftime('%-m/%-d %H:%M')} が過去になります。移動時間または予定時刻を見直してください。",
          recommendations: [],
          provider: 'rails-local-travel-past-start-v1',
          policy_run: local_policy_run('rails-local-travel-past-start-v1', { travel_start_at: travel_start.iso8601 }),
          tool_invocations: []
        }
      end

      travel_conflicts = conflicting_events(context_value(:personal_events), travel_start, travel_end)
      if travel_conflicts.any?
        conflict_title = event_title(travel_conflicts.first)
        return {
          assistant_message: "移動時間を入れると #{travel_start.strftime('%H:%M')}-#{travel_end.strftime('%H:%M')} が既存予定「#{conflict_title}」と重なります。会議時刻を変更するか、移動予定を調整してください。",
          recommendations: [],
          provider: 'rails-local-travel-conflict-v1',
          policy_run: local_policy_run('rails-local-travel-conflict-v1', { conflict_title: conflict_title }),
          tool_invocations: []
        }
      end

      travel_event = travel_event_hash(
        origin: travel_route[:origin],
        destination: destination,
        start_at: travel_start,
        end_at: travel_end,
        travel_minutes: travel_minutes,
        arrival_buffer_minutes: arrival_buffer_minutes
      )

      build_local_bundle_response(
        title: "移動込み: #{title}",
        assistant_message: "#{destination}での#{title}に合わせて、移動予定と本予定の2件を候補にしました。#{travel_label(origin: travel_route[:origin], destination: destination)} #{travel_start.strftime('%H:%M')}-#{travel_end.strftime('%H:%M')}、#{title} #{event_start.strftime('%H:%M')}-#{event_end.strftime('%H:%M')}です。",
        reason: '明示された移動時間を使い、移動予定と本予定をまとめて作成しました。',
        events: [travel_event, main_event],
        provider: 'rails-local-travel-assist-bundle-v1'
      )
    end

    def local_same_date_multi_explicit_time_response(text)
      normalized = normalize_japanese(text)
      return nil unless multi_intent_schedule_request?(normalized)
      return nil if event_mutation_or_reference_request?(normalized)

      clauses = split_event_clauses(text)
      return nil unless clauses.length >= 2

      shared_date = first_local_date_from_text(text)
      parsed = clauses.map { |clause| parse_multi_explicit_event_clause(clause, shared_date) }
      schedule_like = parsed.select { |item| item[:time_present] || item[:title].present? }
      return nil unless schedule_like.length >= 2

      timed_items = schedule_like.select { |item| item[:time_present] }
      if timed_items.length < 2 && timed_items.any? { |item| insufficient_activity_title?(item[:title]) || item[:title] == '予定' }
        return nil
      end

      incomplete = schedule_like.find { |item| item[:date].blank? || item[:start_minute].blank? || insufficient_activity_title?(item[:title]) || item[:title] == '予定' }
      if incomplete
        missing_title = incomplete[:title].presence || clean_activity_title(remove_date_time_phrases(incomplete[:clause])).presence || '予定'
        return {
          assistant_message: "#{missing_title}の時間が不足しています。何時に入れるかを指定してください。複数予定は、各予定に日付・時刻・内容を付けて入力してください。",
          recommendations: [],
          provider: 'rails-local-multi-explicit-clarification-v1',
          policy_run: local_policy_run('rails-local-multi-explicit-clarification-v1', { missing_clause: incomplete[:clause] }),
          tool_invocations: []
        }
      end

      events = schedule_like.map do |item|
        build_local_event_payload(
          title: item[:title],
          date: item[:date],
          text: item[:clause],
          start_minute: item[:start_minute],
          duration_minutes: item[:duration_minutes],
          default_duration: item[:duration_minutes] || 60,
          contact_name: item[:contact_name],
          participant_names: item[:participant_names],
          location: item[:location],
          buffer_minutes: item[:buffer_minutes],
          all_day: false
        )
      end.compact

      return nil unless events.length >= 2

      build_local_candidates_response(
        assistant_message: "以下#{events.length}件の予定候補を作成しました。",
        reason: '同じ文の中に複数の予定指定があったため、別々の予定候補に分解しました。',
        events: events,
        provider: 'rails-local-multi-explicit-events-v1'
      )
    end

    def local_explicit_event_conflict_response(text)
      normalized = normalize_japanese(text)
      return nil unless explicit_timed_schedule_add_request?(normalized)

      descriptor = local_event_descriptor(text)
      title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
      return nil if insufficient_activity_title?(title) || title == '予定'

      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(title))
      return nil unless start_minute && duration&.positive?

      date = first_local_date_from_text(text)
      return nil unless date

      start_at = app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
      end_at = start_at + duration.minutes
      conflicts = conflicting_events(context_value(:personal_events), start_at, end_at)
      return nil if conflicts.empty?

      conflict = conflicts.first
      conflict_title = event_title(conflict)
      conflict_message = "#{start_at.strftime('%H:%M')}-#{end_at.strftime('%H:%M')}は既存予定「#{conflict_title}」と重なります。"
      alternative = next_available_event_after_conflict(
        date: date,
        duration: duration,
        conflicts: conflicts,
        title: title,
        descriptor: descriptor
      )

      if alternative
        alt_start = parse_context_time(alternative['start_at'])
        alt_end = parse_context_time(alternative['end_at'])
        alternative['description'] = conflict_message
        build_local_candidates_response(
          assistant_message: "#{conflict_message}別候補として#{alt_start.strftime('%H:%M')}-#{alt_end.strftime('%H:%M')}はどうですか？",
          reason: "指定時刻が既存予定「#{conflict_title}」と重なるため、同じ日の空き時間を代替候補として出しました。",
          events: [alternative],
          provider: 'rails-local-explicit-conflict-alternative-v1'
        )
      else
        {
          assistant_message: "#{conflict_message}同じ日に代替候補を見つけられませんでした。別の時間を指定してください。",
          recommendations: [],
          provider: 'rails-local-explicit-conflict-no-slot-v1',
          policy_run: local_policy_run('rails-local-explicit-conflict-no-slot-v1', { conflict_count: conflicts.length }),
          tool_invocations: []
        }
      end
    end

    def past_explicit_datetime_response(text)
      start_at = explicit_start_datetime_from_text(text)
      return nil unless start_at && start_at < context_now

      {
        assistant_message: "#{start_at.strftime('%-m/%-d %H:%M')}はすでに過去です。未来の日時を指定してください。",
        recommendations: [],
        provider: 'rails-local-past-explicit-datetime-v1',
        policy_run: local_policy_run('rails-local-past-explicit-datetime-v1', { requested_start_at: start_at.iso8601 }),
        tool_invocations: []
      }
    end

    def local_between_existing_events_response(text)
      normalized = normalize_japanese(text)
      return nil unless between_existing_events_request?(normalized)

      {
        assistant_message: '予定と予定の間に入れる依頼として受け取りましたが、参照している予定を特定できませんでした。候補は作成しません。対象の予定名、または日時を指定してください。',
        recommendations: [],
        provider: 'rails-local-between-events-clarification-v1',
        policy_run: local_policy_run('rails-local-between-events-clarification-v1'),
        tool_invocations: []
      }
    end

    def local_ambiguous_schedule_clarification_response(text)
      normalized = normalize_japanese(text)
      return nil unless ambiguous_schedule_request?(normalized)

      {
        assistant_message: '予定候補を作るには情報が足りません。何を、いつ、どのくらい入れたいかを指定してください。例:「明日の午後に30分、休憩を入れて」。',
        recommendations: [],
        provider: 'rails-local-ambiguous-schedule-clarification-v1',
        policy_run: local_policy_run('rails-local-ambiguous-schedule-clarification-v1'),
        tool_invocations: []
      }
    end

    def past_datetime_response(text)
      normalized = normalize_japanese(text)
      return nil unless past_datetime_request?(normalized)

      {
        assistant_message: '過去の日時への予定追加として受け取りました。過去日時には候補を作成しません。必要なら未来の日時を指定してください。',
        recommendations: [],
        provider: 'rails-local-past-date-validation-v1',
        policy_run: local_policy_run('rails-local-past-date-validation-v1'),
        tool_invocations: []
      }
    end

    def local_schedule_summary_response(text)
      normalized = normalize_japanese(text)
      return nil unless schedule_summary_request?(normalized)

      period_label, range_start, range_end = schedule_summary_range(normalized)
      visible_events = personal_events_between_dates(range_start, range_end).sort_by do |event|
        event_time_for_sort(event) || app_time_zone.local(range_end.year, range_end.month, range_end.day, 23, 59, 0)
      end

      message = if normalized.match?(/忙しい|多い|混んで|詰ま/)
                  busy_days_message(period_label, visible_events, range_start, range_end)
                else
                  schedule_summary_message(period_label, visible_events, range_start, range_end, include_attention: normalized.match?(/注意|ポイント|気をつけ|確認/))
                end

      {
        assistant_message: message,
        recommendations: [],
        provider: 'rails-local-schedule-summary-v1',
        policy_run: local_policy_run('rails-local-schedule-summary-v1', {
          period: period_label,
          visible_event_count: visible_events.length,
          range_start: range_start.iso8601,
          range_end: range_end.iso8601
        }),
        tool_invocations: []
      }
    end

    def local_schedule_organization_response(text)
      normalized = normalize_japanese(text)
      return nil unless schedule_organization_request?(normalized)

      period_label, range_start, range_end = schedule_organization_range(normalized)
      visible_events = personal_events_between_dates(range_start, range_end)
      count_message = visible_events.any? ? "現在見えている#{period_label}の予定は#{visible_events.length}件です。" : "#{period_label}の予定整理として受け取りました。"

      {
        assistant_message: "#{count_message} 新しい予定候補は作らず、棚卸し・優先度付け・移動候補の整理として扱います。固定予定、締切が近い予定、動かせる予定の3つに分けて見直してください。移動したい予定名を指定すると、移動先候補を出します。",
        recommendations: [],
        provider: 'rails-local-schedule-organization-v1',
        policy_run: local_policy_run('rails-local-schedule-organization-v1', { period: period_label, visible_event_count: visible_events.length }),
        tool_invocations: []
      }
    end

    def local_focus_work_response(text)
      normalized = normalize_japanese(text)
      return nil unless focus_work_request?(normalized)

      parsed_start_minute, parsed_duration = parse_local_time_and_duration(normalized, default_duration: 90)
      duration = parsed_duration || 90
      title = focus_work_title_from_text(@user_message.presence || text)
      dates = candidate_dates_for_request(normalized)
      return nil if dates.empty?

      window_start, window_end = if parsed_start_minute
                                   [parsed_start_minute, parsed_start_minute + duration]
                                 else
                                   preferred_minute_window(normalized)
                                 end

      events = []
      dates.each do |date|
        minute = window_start
        while minute + duration <= window_end
          start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
          end_at = start_at + duration.minutes

          unless conflicts_with_events?(context_value(:personal_events), start_at, end_at)
            events << local_event_hash(
              title: title,
              start_at: start_at,
              end_at: end_at,
              all_day: false,
              color: color_for_local_title(title),
              category: category_for_local_title(title),
              intent: 'focus_work',
              schedule_profile: 'focus_work',
              reason: '会議や関係者調整ではなく、作業時間として候補を出しました。'
            )
            break if events.length >= 3
          end

          minute += parsed_start_minute ? duration : 30
        end
        break if events.length >= 3
      end

      if events.empty?
        return {
          assistant_message: '集中作業の時間として受け取りましたが、条件に合う空き枠を見つけられませんでした。曜日・時間帯・所要時間のどれかを指定してください。',
          recommendations: [],
          provider: 'rails-local-focus-work-v1',
          policy_run: local_policy_run('rails-local-focus-work-v1', { recommendation_count: 0, duration_minutes: duration }),
          tool_invocations: []
        }
      end

      build_local_candidates_response(
        assistant_message: "#{title}の時間として、予定が重なりにくい#{duration}分枠を#{events.length}件出しました。",
        reason: '作業・集中系の予定として扱い、会議・関係者調整には変換していません。',
        events: events,
        provider: 'rails-local-focus-work-v1'
      )
    end

    def local_existing_event_delete_erase_response(text)
      return nil unless existing_event_delete_request?(text)

      matches = matched_existing_events(text).first(6)
      action_label = '削除'

      if matches.empty?
        return {
          assistant_message: "#{action_label}指示として受け取りましたが、対象予定を特定できませんでした。予定名、日付、時刻をもう少し具体的に指定してください。",
          recommendations: [],
          provider: 'rails-local-existing-event-delete-guard-v2',
          policy_run: local_policy_run('rails-local-existing-event-delete-guard-v2', { guarded_action: action_label, matched_count: 0 }),
          tool_invocations: []
        }
      end

      if matches.length > 1
        rows = matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")
        return {
          assistant_message: "#{action_label}対象と思われる予定が複数あります。安全のため自動#{action_label}はしません。対象を特定できるように、日時やタイトルを追加してください。\n#{rows}",
          recommendations: [],
          provider: 'rails-local-existing-event-delete-guard-v2',
          policy_run: local_policy_run('rails-local-existing-event-delete-guard-v2', { guarded_action: action_label, matched_count: matches.length }),
          tool_invocations: []
        }
      end

      target = matches.first
      attrs = target.to_h
      source_event_id = attrs[:id] || attrs['id']
      return nil if source_event_id.blank?

      title = attrs[:title] || attrs['title'] || '予定'
      payload = {
        'event_action' => 'delete',
        'source_event_id' => source_event_id,
        'title' => title,
        'description' => "#{format_event_for_message(target)} を削除します。"
      }

      {
        assistant_message: "#{format_event_for_message(target)} を削除候補として用意しました。実行前に確認してください。",
        recommendations: [
          {
            'kind' => 'event_delete',
            'title' => "#{title}を削除",
            'description' => payload['description'],
            'reason' => '既存予定の削除は、ユーザー確認後だけ実行します。',
            'start_at' => attrs[:start_at] || attrs['start_at'],
            'end_at' => attrs[:end_at] || attrs['end_at'],
            'all_day' => attrs[:all_day] || attrs['all_day'],
            'source_event_id' => source_event_id,
            'payload' => payload
          }
        ],
        provider: 'rails-local-existing-event-delete-v1',
        policy_run: local_policy_run('rails-local-existing-event-delete-v1', { source_event_id: source_event_id }),
        tool_invocations: []
      }
    end

    def existing_event_delete_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/削除|消して|消す|消したい|消去|なくして|取り消して|キャンセルして|キャンセル/)
      return false if normalized.match?(/追加|入れて|登録|作って|作成|通知|リマインダー|変更|移動|ずらして/)

      true
    end

    def existing_event_title_query_from_text(text)
      source = normalize_japanese_preserve_case(remove_participant_phrases(remove_date_time_phrases(text)))
      source = source.gsub(/(?:を)?(?:削除|消して|消す|消したい|消去|なくして|取り消して|キャンセルして|キャンセル).*$/i, '')
      source = source.gsub(/(?:を)?(?:変更|移動|ずらして|リスケ|延期|前倒し).*$/i, '')
      source = source.gsub(/(?:の)?(?:\d+|[一二三四五六七八九十]+)\s*時間前に?(?:通知|リマインダー).*$/i, '')
      source = source.gsub(/(?:の)?(?:時間|間)前に?(?:通知|リマインダー).*$/i, '')
      source = source.gsub(/(?:の)?(?:\d+|[一二三四五六七八九十]+)\s*分前に?(?:通知|リマインダー).*$/i, '')
      source = source.gsub(/(?:の)?(?:前|まえ)に?(?:通知|リマインダー|知らせて|アラート).*$/i, '')
      source = source.gsub(/\s*(を|に|は|で|と|の)\s*$/, '')
      title = clean_activity_title(source)
      normalized_title = normalize_japanese(title)
      return nil if normalized_title.blank?
      return nil if normalized_title.match?(/\A(?:予定|削除|変更|通知|リマインダー|確認|チェック)\z/)

      normalized_title
    end

    def local_event_reminder_response(text)
      normalized = normalize_japanese(text)
      return nil unless reminder_request?(normalized)

      matches = matched_existing_events(text).first(6)
      return reminder_clarification_response('リマインダーを設定する予定を特定できませんでした。予定名または日時を指定してください。', matches.length) if matches.empty?
      return reminder_clarification_response("リマインダー候補が複数あります。どの予定か分かるように日時やタイトルを追加してください。\n#{matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")}", matches.length) if matches.length > 1
      return reminder_clarification_response('会議の何分前に通知しますか？ 例: 10分前、30分前、1時間前', matches.length) unless explicit_reminder_offset_present?(normalized)

      target = matches.first
      attrs = target.to_h
      start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])
      return reminder_clarification_response('対象予定の開始時刻を読み取れませんでした。予定を開いて確認してください。', 1) unless start_at

      minutes_before = reminder_minutes_before(normalized)
      all_day = ActiveModel::Type::Boolean.new.cast(attrs[:all_day] || attrs['all_day'])
      base_time = all_day ? app_time_zone.local(start_at.year, start_at.month, start_at.day, 9, 0, 0) : start_at
      remind_at = base_time - minutes_before.minutes
      event_title = attrs[:title] || attrs['title'] || '予定'

      payload = {
        'event_action' => 'reminder',
        'source_event_id' => attrs[:id] || attrs['id'],
        'minutes_before' => minutes_before,
        'remind_at' => remind_at.iso8601,
        'target_title' => event_title,
        'title' => "#{event_title}のリマインダー",
        'description' => "#{format_event_for_message(target)} の#{minutes_before}分前に通知します。"
      }

      {
        assistant_message: "#{format_event_for_message(target)} の#{minutes_before}分前にリマインダー候補を作成しました。実行前に確認してください。",
        recommendations: [
          {
            'kind' => 'event_reminder',
            'title' => payload['title'],
            'description' => payload['description'],
            'reason' => '対象予定を特定し、指定されたタイミングのリマインダー候補を作成しました。',
            'start_at' => remind_at.iso8601,
            'end_at' => (remind_at + 1.minute).iso8601,
            'all_day' => false,
            'source_event_id' => payload['source_event_id'],
            'payload' => payload
          }
        ],
        provider: 'rails-local-event-reminder-v1',
        policy_run: local_policy_run('rails-local-event-reminder-v1', { source_event_id: payload['source_event_id'], minutes_before: minutes_before }),
        tool_invocations: []
      }
    end

    # 既存予定の変更・削除は、候補提示とユーザー確認後の実行に限定する。
    def local_existing_event_change_response(text)
      action =
        if text.match?(/削除|消して|キャンセル|取り消し/)
          'delete'
        elsif text.match?(/変更|移動|ずらして|リスケ|延期|前倒し/)
          'update'
        end
      return nil unless action

      matches = matched_existing_events(text).first(6)
      action_label = action == 'delete' ? '削除' : '変更'

      if matches.empty?
        return {
          assistant_message: "#{action_label}指示として受け取りましたが、対象予定を特定できませんでした。予定名、日付、時刻をもう少し具体的に指定してください。",
          recommendations: [],
          provider: 'rails-local-existing-event-guard-v6',
          policy_run: local_policy_run('rails-local-existing-event-guard-v6', { guarded_action: action_label, matched_count: 0 }),
          tool_invocations: []
        }
      end

      if matches.length > 1
        rows = matches.map { |event| "・#{format_event_for_message(event)}" }.join("\n")
        return {
          assistant_message: "#{action_label}対象と思われる予定が複数あります。安全のため自動#{action_label}はしません。対象を特定できるように、日時やタイトルを追加してください。\n#{rows}",
          recommendations: [],
          provider: 'rails-local-existing-event-guard-v6',
          policy_run: local_policy_run('rails-local-existing-event-guard-v6', { guarded_action: action_label, matched_count: matches.length }),
          tool_invocations: []
        }
      end

      target = matches.first
      attrs = target.to_h
      source_event_id = attrs[:id] || attrs['id']
      return nil if source_event_id.blank?

      if action == 'delete'
        payload = {
          'event_action' => 'delete',
          'source_event_id' => source_event_id,
          'title' => attrs[:title] || attrs['title'],
          'description' => "#{format_event_for_message(target)} を削除します。"
        }

        return {
          assistant_message: "#{format_event_for_message(target)} を削除候補として用意しました。実行前に確認してください。",
          recommendations: [
            {
              'kind' => 'event_delete',
              'title' => "#{attrs[:title] || attrs['title'] || '予定'}を削除",
              'description' => payload['description'],
              'reason' => '既存予定の削除は、ユーザー確認後だけ実行します。',
              'start_at' => attrs[:start_at] || attrs['start_at'],
              'end_at' => attrs[:end_at] || attrs['end_at'],
              'all_day' => attrs[:all_day] || attrs['all_day'],
              'source_event_id' => source_event_id,
              'payload' => payload
            }
          ],
          provider: 'rails-local-existing-event-delete-v1',
          policy_run: local_policy_run('rails-local-existing-event-delete-v1', { source_event_id: source_event_id }),
          tool_invocations: []
        }
      end

      update_payload = existing_event_update_payload(target, text)
      unless update_payload
        return {
          assistant_message: "#{format_event_for_message(target)} の変更指示として受け取りましたが、変更後の日時を特定できませんでした。例:「明日の会議を16時に変更」のように入力してください。",
          recommendations: [],
          provider: 'rails-local-existing-event-update-clarification-v1',
          policy_run: local_policy_run('rails-local-existing-event-update-clarification-v1', { source_event_id: source_event_id }),
          tool_invocations: []
        }
      end

      payload = {
        'event_action' => 'update',
        'source_event_id' => source_event_id,
        'title' => attrs[:title] || attrs['title'],
        'description' => "変更前: #{format_event_for_message(target)}\n変更後: #{format_datetime_range_for_message(update_payload['start_at'], update_payload['end_at'], update_payload['all_day'])} #{attrs[:title] || attrs['title']}",
        'updates' => update_payload
      }

      {
        assistant_message: "#{format_event_for_message(target)} の変更候補を作成しました。実行前に確認してください。",
        recommendations: [
          {
            'kind' => 'event_update',
            'title' => "#{attrs[:title] || attrs['title'] || '予定'}を変更",
            'description' => payload['description'],
            'reason' => '既存予定の変更は、ユーザー確認後だけ実行します。',
            'start_at' => update_payload['start_at'],
            'end_at' => update_payload['end_at'],
            'all_day' => update_payload['all_day'],
            'source_event_id' => source_event_id,
            'payload' => payload
          }
        ],
        provider: 'rails-local-existing-event-update-v1',
        policy_run: local_policy_run('rails-local-existing-event-update-v1', { source_event_id: source_event_id }),
        tool_invocations: []
      }
    end

    def local_open_slot_response(text)
      normalized = normalize_japanese(text)
      return nil unless open_slot_request?(normalized)

      descriptor = local_event_descriptor(text)
      duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title])).last
      duration ||= default_duration_minutes_for_title(descriptor[:activity_title])
      title = descriptor[:activity_title].presence || local_title_from_text(text)
      title = clean_activity_title(title)
      dates = candidate_dates_for_request(text)
      return nil if dates.empty?

      window_start, window_end = preferred_minute_window(text)
      candidates = []

      dates.each do |date|
        minute = window_start
        while minute + duration <= window_end
          start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
          end_at = start_at + duration.minutes

          unless conflicts_with_events?(context_value(:personal_events), start_at, end_at)
            candidates << local_event_hash(
              title: title,
              start_at: start_at,
              end_at: end_at,
              all_day: false,
              color: color_for_local_title(title),
              category: category_for_local_title(title),
              intent: intent_for_local_title(title),
              schedule_profile: profile_for_local_title(title),
              reason: '既存予定と重なりにくい空き時間として候補を出しました。',
              contact_name: descriptor[:contact_name],
              participant_names: descriptor[:participant_names],
              location: descriptor[:location],
              buffer_minutes: descriptor[:buffer_minutes]
            )
            break if candidates.length >= 3
          end

          minute += 30
        end
        break if candidates.length >= 3
      end

      if candidates.empty?
        return {
          assistant_message: "#{title}の空き時間を探しましたが、条件に合う#{duration}分枠を見つけられませんでした。曜日・時間帯・所要時間のどれかを変えてください。",
          recommendations: [],
          provider: 'rails-local-open-slot-v1',
          policy_run: local_policy_run('rails-local-open-slot-v1', { recommendation_count: 0, duration_minutes: duration }),
          tool_invocations: []
        }
      end

      build_local_candidates_response(
        assistant_message: "#{title}の空き時間として、#{duration}分枠を#{candidates.length}件出しました。",
        reason: '既存予定と重ならない空き枠を優先しました。',
        events: candidates,
        provider: 'rails-local-open-slot-v1'
      )
    end

    def local_availability_response(text)
      return nil unless text.match?(/空き|空いて|都合|(?<!打ち)合わせ|候補|いつ|できれば|無理なら/)

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

    def local_single_explicit_event_response(text, require_explicit_time: false)
      return nil if normalize_japanese(text).match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)

      descriptor = local_event_descriptor(text)
      display_title = clean_activity_title(descriptor[:title])
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
      has_time_hint = explicit_time_present?(text) || period_window_hint?(text)
      all_day_requested = explicit_all_day_request?(text)
      return nil if require_explicit_time && !has_time_hint

      start_minute ||= default_start_minute_for_text(text, descriptor[:activity_title]) if has_time_hint && !all_day_requested
      date = first_local_date_from_text(text)
      date ||= inferred_date_for_time_only(start_minute) if has_time_hint && !all_day_requested
      return nil unless date

      start_minute ||= default_start_minute_for_text(text, descriptor[:activity_title]) unless all_day_requested

      event = build_local_event_payload(
        title: display_title,
        date: date,
        text: text,
        start_minute: start_minute,
        duration_minutes: duration,
        default_duration: default_duration_minutes_for_title(descriptor[:activity_title]),
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes],
        all_day: all_day_requested
      )

      assistant_message = if all_day_requested
                            "#{date.strftime('%-m/%-d')} 終日の#{display_title}として候補を作成しました。"
                          else
                            "#{date.strftime('%-m/%-d')} #{minute_label(start_minute)}から#{duration}分の#{display_title}として候補を作成しました。"
                          end

      build_local_bundle_response(
        title: display_title,
        assistant_message: assistant_message,
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
      return nil unless text.match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)

      local_daily_recurrence_response(text) ||
        local_monthly_nth_weekday_response(text) ||
        local_monthly_day_response(text) ||
        local_weekly_or_biweekly_response(text)
    end

    def local_daily_recurrence_response(text)
      return nil unless text.match?(/毎日|毎朝|毎晩/)

      descriptor = local_event_descriptor(text, fallback_title: '日課')
      start_minute, duration = parse_local_time_and_duration(text, default_duration: default_duration_minutes_for_title(descriptor[:activity_title]))
      start_minute ||= default_start_minute_for_text(text, descriptor[:activity_title])

explicit_first_date = first_local_date_from_text(text)
first_date = explicit_first_date || context_now.to_date

if explicit_first_date.nil? && start_minute
  candidate_start = app_time_zone.local(first_date.year, first_date.month, first_date.day, start_minute / 60, start_minute % 60, 0)
  first_date += 1 if candidate_start < context_now
end

events = 8.times.map do |i|
        build_local_event_payload(
          title: descriptor[:title],
          date: first_date + i,
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
        title: "#{descriptor[:title]}（毎日）",
        assistant_message: "毎日の#{descriptor[:title]}として、#{events.length}件分の繰り返し候補を1枚のカードにまとめました。追加すると各日に予定を作成します。",
        reason: '毎日の繰り返し予定として候補をまとめました。',
        events: events,
        provider: 'rails-local-daily-recurrence-v1',
        recurrence_kind: 'daily',
        recurrence_label: '毎日'
      )
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
        first_start = app_time_zone.local(first.year, first.month, first.day, start_minute / 60, start_minute % 60, 0)
        first += interval * 7 if first_start <= now

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
        assistant_message: "#{label}の#{descriptor[:title]}として、#{events.length}件分の繰り返し候補を1枚のカードにまとめました。追加すると各日に予定を作成します。",
        reason: "#{label}の繰り返し予定として候補をまとめました。",
        events: events.sort_by { |event| event['start_at'].to_s }.first(16),
        provider: 'rails-local-weekly-recurrence-v5',
        recurrence_kind: interval == 2 ? 'biweekly' : 'weekly',
        recurrence_label: label
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

    def build_local_bundle_response(title:, assistant_message:, reason:, events:, provider:, recurrence_kind: nil, recurrence_label: nil)
      first = events.first
      display_title = clean_activity_title(title)
      payload = first.merge('events' => events)
      if recurrence_kind.present?
        payload['recurrence_kind'] = recurrence_kind
        payload['recurrence_label'] = recurrence_label if recurrence_label.present?
        payload['target_dates'] = events.map { |event| Time.iso8601(event['start_at']).to_date.iso8601 rescue nil }.compact.uniq
      end

      {
        assistant_message: assistant_message,
        recommendations: [
          {
            'kind' => 'draft_event',
            'title' => display_title,
            'description' => first['description'],
            'reason' => reason,
            'start_at' => first['start_at'],
            'end_at' => first['end_at'],
            'all_day' => first['all_day'],
            'payload' => payload
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
            'title' => clean_activity_title(event['title']),
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

    def inferred_date_for_time_only(start_minute)
      return nil unless start_minute

      now = context_now
      candidate = app_time_zone.local(now.year, now.month, now.day, start_minute / 60, start_minute % 60, 0)
      candidate >= now ? now.to_date : now.to_date + 1
    end

    def build_local_event_payload(title:, date:, text:, start_minute: nil, duration_minutes: nil, default_duration: 60, contact_name: nil, participant_names: [], location: nil, buffer_minutes: nil, all_day: false)
      final_title = title.presence || local_event_descriptor(text)[:title]
      final_title = clean_activity_title(final_title)
      all_day_requested = ActiveModel::Type::Boolean.new.cast(all_day) || explicit_all_day_request?(text)
      start_minute ||= parse_local_time_and_duration(text, default_duration: default_duration).first
      start_minute ||= default_start_minute_for_text(text, final_title) unless all_day_requested

      if all_day_requested
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
          start_minute: start_minute || default_start_minute_for_text(clause, descriptor[:activity_title]),
          duration_minutes: duration || default_duration_minutes_for_title(descriptor[:activity_title]),
          text: clause
        }
      end
    end

    def split_event_clauses(text)
      normalize_japanese(text).split(/(?:、|。|,|;|；|そして|それから)/).map(&:strip).reject(&:blank?)
    end

    def candidate_dates_for_request(text)
      normalized = normalize_japanese(text)
      now = context_now
      weekdays = target_weekdays(normalized)

      if normalized.include?('再来週') || normalized.include?('翌週')
        start = now.to_date + ((8 - now.wday) % 7) + 7
        return weekdays.map { |weekday| start + ((weekday - start.wday) % 7) }.sort if weekdays.any?
        return (0..4).map { |i| start + i }
      end

      if normalized.include?('来週')
        start = now.to_date + ((8 - now.wday) % 7)
        return weekdays.map { |weekday| start + ((weekday - start.wday) % 7) }.sort if weekdays.any?
        return (0..4).map { |i| start + i }
      end

      if (date = first_local_date_from_text(text))
        return [date]
      end

      if weekdays.any?
        return weekdays.map { |weekday| next_weekday_on_or_after(now.to_date, weekday) }.sort
      end

      (0..10).map { |i| now.to_date + i }.select { |d| d.wday.between?(1, 5) }.first(7)
    end

    def first_local_date_from_text(text)
      now = context_now
      normalized = normalize_japanese(text)
      if (date = relative_day_count_date(normalized, now))
        return date
      end

      if (date = relative_final_weekday_date(normalized, now))
        return date
      end


      return now.to_date if normalized.include?('今日') || normalized.include?('きょう')
      return now.to_date + 1 if normalized.include?('明日') || normalized.include?('あした')
      return now.to_date + 2 if normalized.include?('明後日') || normalized.include?('あさって')

      if (date = relative_nth_weekday_date(normalized, now))
        return date
      end

      if (date = relative_weekday_date(normalized, now))
        return date
      end

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
      normalized.scan(/(?<name>[^\s、。\/\d]+?(?:さん|くん|君|ちゃん)?|[a-zA-Z][a-zA-Z0-9_\-]{0,20})(?:と|との)(?=会議|定例|打ち合わせ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|チャット|会う|遊ぶ|相談|予定)/) do
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
      explicit_title = explicit_activity_title_from_user_text(text)
      return explicit_title if explicit_title.present?

      subject_title = subject_study_activity_title_from_text(text)
      return subject_title if subject_title.present?

      cleaned = clean_activity_title(remove_participant_phrases(remove_date_time_phrases(text)))
      return cleaned if cleaned.present? && cleaned.length <= 24 && !request_phrase_only?(cleaned) && !insufficient_activity_title?(cleaned)

      fallback_title.presence || local_title_from_text(text)
    end

    def explicit_activity_title_from_user_text(text)
      source = remove_participant_phrases(remove_date_time_phrases(text))
      title = clean_activity_title(source)
      return nil if insufficient_activity_title?(title)

      title
    end

    def insufficient_activity_title?(title)
      normalized = normalize_japanese(title)
      return true if normalized.blank?
      return true if normalized.match?(/\A(?:予定|空いてるところ|空き|ところ|さん|くん|ちゃん)\z/)
      return true if time_of_day_only_title?(normalized)
      return true if normalized.match?(/\A.+(?:さん|くん|ちゃん)\z/) && !normalized.match?(/会議|打ち合わせ|打合せ|ミーティング|面談|相談|電話|作業|学習|勉強|復習|予習|レビュー|確認/)

      false
    end

    def time_of_day_only_title?(title)
      normalize_japanese(title).match?(/\A(?:朝|朝イチ|朝一|午前|午前中|午後|昼|お昼|正午|夕方|放課後|夜|よる|今夜|今晩|深夜|未明)\z/)
    end

    def should_override_ai_title?(current_title, candidate_title)
      return false if candidate_title.blank? || insufficient_activity_title?(candidate_title)

      current = normalize_japanese(current_title)
      candidate = normalize_japanese(candidate_title)
      return true if current.blank?
      return true if generic_study_title?(current_title)
      return true if current == candidate
      return true if current.include?(candidate) || candidate.include?(current)
      return true if candidate_title.match?(/[A-Z]/) && current == normalize_japanese(candidate_title)

      false
    end

    def subject_study_activity_title_from_text(text)
      source = normalize_japanese_preserve_case(remove_date_time_phrases(text))

      match = source.match(/(?<title>[一-龥ぁ-んァ-ヶA-Za-z0-9_\-]+の(?:復習|予習|宿題|課題|勉強|学習|練習|確認|レビュー))/)
      return nil unless match

      title = clean_activity_title(match[:title])
      return nil if title.blank? || title == '予定'

      title
    end

    def preserve_user_title_case_in_object!(object, title)
      return object if title.blank?

      normalized_title = normalize_japanese(title)

      case object
      when Hash
        object.keys.each do |key|
          object[key] = preserve_user_title_case_in_object!(object[key], title)
        end
        object
      when Array
        object.map! { |item| preserve_user_title_case_in_object!(item, title) }
      when String
        preserve_user_title_case_in_string(object, title, normalized_title)
      else
        object
      end
    end

    def preserve_user_title_case_in_string(value, title, normalized_title = nil)
      original = value.to_s
      normalized = normalized_title.presence || normalize_japanese(title)
      return original if normalized.blank?

      original.gsub(normalized, title)
    end

    def skip_user_text_title_override?(response)
      return false unless response.respond_to?(:to_h)

      hash = response.to_h
      provider = (hash[:provider] || hash['provider']).to_s
      return true if provider.match?(/\Arails-local-(focus-work|existing-event-delete|existing-event-update|event-reminder|travel-assist)/)

      recommendation_list = Array(hash[:recommendations] || hash['recommendations'])
      recommendation_list.any? do |recommendation|
        next false unless recommendation.respond_to?(:to_h)

        kind = recommendation[:kind] || recommendation['kind']
        kind.to_s.match?(/\Aevent_(delete|update|reminder)\z/)
      end
    end

    def apply_user_text_title_overrides(response)
      return response if skip_user_text_title_override?(response)

      candidate_title = explicit_activity_title_from_user_text(@user_message)
      subject_title = subject_study_activity_title_from_text(@user_message)
      override_title = candidate_title.presence || subject_title
      return response if override_title.blank?
      return response unless response.respond_to?(:to_h)

      hash = response
      recommendations = hash[:recommendations] || hash['recommendations']
      recommendation_list = Array(recommendations)
      return response if recommendation_list.length > 1
      return response if recommendation_list.any? do |recommendation|
        next false unless recommendation.respond_to?(:to_h)

        payload = recommendation[:payload] || recommendation['payload']
        events = payload.respond_to?(:to_h) ? (payload[:events] || payload['events']) : nil
        Array(events).length > 1
      end

      recommendation_list.each do |recommendation|
        next unless recommendation.respond_to?(:to_h)

        current_title = recommendation[:title] || recommendation['title']
        payload = recommendation[:payload] || recommendation['payload']
        payload_title = payload.respond_to?(:to_h) ? (payload[:title] || payload['title']) : nil

        if should_override_ai_title?(current_title, override_title) || should_override_ai_title?(payload_title, override_title)
          write_hash_title(recommendation, override_title)
          write_hash_title(payload, override_title) if payload.respond_to?(:to_h)
        end
      end

      preserve_user_title_case_in_object!(hash, override_title)
      hash
    end

    def generic_study_title?(value)
      normalize_japanese(value).match?(/\A(?:復習|予習|宿題|課題|勉強|学習|練習|確認|レビュー|予定)\z/)
    end

    def write_hash_title(hash, title)
      return unless hash.respond_to?(:[]=)

      wrote = false
      if hash.respond_to?(:key?) && hash.key?('title')
        hash['title'] = title
        wrote = true
      end
      if hash.respond_to?(:key?) && hash.key?(:title)
        hash[:title] = title
        wrote = true
      end
      hash['title'] = title unless wrote
    end

    def remove_participant_phrases(text)
      preserved = normalize_japanese_preserve_case(text)
      known_contact_names.each do |name|
        normalized_name = normalize_japanese_preserve_case(name)
        next if normalized_name.blank?
        preserved = preserved.gsub(/#{Regexp.escape(normalized_name)}(?:さん|くん|君|ちゃん)?(?:と|との)/i, '')
      end
      preserved.gsub(/[^\s、。\/\d]+?(?:さん|くん|君|ちゃん)?(?:と|との)(?=会議|定例|打ち合わせ|打合せ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|チャット|会う|遊ぶ|相談|予定)/, '')
    end

    def remove_date_time_phrases(text)
      normalize_japanese_preserve_case(text)
        .gsub(/(?:(?:\d{4})年)?(?:1[0-2]|0?[1-9])(?:月|[\/\-])(?:3[01]|[12]\d|0?[1-9])日?/, '')
        .gsub(/(?<!\d)(?:3[01]|[12]\d|0?[1-9])日(?![曜間後前本以内])/, '')
        .gsub(/(?:\d+|[一二三四五六七八九十]+)(?:日|にち)後/, '')
        .gsub(/(?:再来月|来月|今月)の?最終[月火水木金土日](?:曜|曜日)?/, '')
        .gsub(/(?:(?:来月|翌月|今月)の?)?第[1-5一二三四五][月火水木金土日](?:曜|曜日)?/, '')
        .gsub(/(?:再来週|来週|翌週|今週|次の)?\s*[月火水木金土日](?:曜|曜日)/, '')
        .gsub(/(?:再来週末|来週末|今週末|週末|土日)(?:で|に|から|まで)?/i, '')
        .gsub(/(今日|きょう|明日|あした|明後日|あさって|昨日|きのう|一昨日|おととい|再来週|来週|翌週|今週|再来月|来月|翌月|今月|月末|来月頭|月初|頭|gw中|gw明け|連休明け)/i, '')
        .gsub(/(終日|一日中|1日中|丸一日|まる一日|全日|all\s*day)(?:で|に|の)?/i, '')
        .gsub(/(?:am|pm|午前|午後|朝イチ|朝一|午前中|朝|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)?\s*(?:\d{1,2}|[一二三四五六七八九十]+)[:：]\d{2}\s*(?:から|〜|~|-)\s*(?:am|pm|午前|午後|朝イチ|朝一|午前中|朝|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)?\s*(?:\d{1,2}|[一二三四五六七八九十]+)[:：]\d{2}(?:まで)?/i, '')
        .gsub(/(?:am|pm|午前|午後|朝イチ|朝一|午前中|朝|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)?\s*(?:\d{1,2}|[一二三四五六七八九十]+)(?:時|じ)(?:(?:\d{1,2}|[一二三四五六七八九十]+)分?|半)?\s*(?:から|〜|~|-)\s*(?:am|pm|午前|午後|朝イチ|朝一|午前中|朝|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)?\s*(?:\d{1,2}|[一二三四五六七八九十]+)(?:時|じ)(?:(?:\d{1,2}|[一二三四五六七八九十]+)分?|半)?(?:まで)?/i, '')
        .gsub(/(?:am|pm|午前|午後|朝イチ|朝一|午前中|朝|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)?\s*(?:\d{1,2}|[一二三四五六七八九十]+)[:：]\d{2}(?:\s*(?:から|以降|まで|〜|~|-)\s*-?\d{1,3}(?:\.\d+)?(?:時間\s*半|時間|分)?|\s*(?:から|以降|まで|に|開始)?)?/i, '')
        .gsub(/(?:am|pm|午前|午後|朝イチ|朝一|午前中|朝|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)?\s*(?:\d{1,2}|[一二三四五六七八九十]+)(?:時|じ)(?:(?:\d{1,2}|[一二三四五六七八九十]+)分?|半)?(?:\s*(?:から|以降|まで|〜|~|-)\s*-?\d{1,3}(?:\.\d+)?(?:時間\s*半|時間|分)?|\s*(?:から|以降|まで|に|開始)?)?/i, '')
        .gsub(/(?:から|〜|~|-)\s*-?\d{1,3}(?:\.\d+)?\s*時間\s*半/i, '')
        .gsub(/(?:から|〜|~|-)\s*-?\d{1,3}(?:\.\d+)?\s*時間/i, '')
        .gsub(/(?:から|〜|~|-)\s*-?\d{1,3}\s*分/i, '')
        .gsub(/-?\d{1,3}(?:\.\d+)?\s*時間\s*半/i, '')
        .gsub(/-?\d{1,3}(?:\.\d+)?\s*時間/i, '')
        .gsub(/-?\d{1,3}\s*分/i, '')
        .gsub(/(?:am|pm|朝イチ|朝一|午前中|午前|午後|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)?/i, '')
        .gsub(/朝\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)/, '')
    end

    def strip_request_action_suffix(value)
      value.to_s
        .gsub(/\s*(?:を)?(?:入れてください|入れて|入れる|いれてください|いれて|いれる|入れといて|いれといて|入れたい|いれたい|追加してください|追加して|追加|登録してください|登録して|登録|作ってください|作って|作る|確保してください|確保して|確保|お願いします|お願い|してください|して)\s*\z/i, '')
        .gsub(/\s*(?:予定)?(?:入れて|いれて|入れる|いれる)\s*\z/i, '')
    end

    def clean_activity_title(value)
      title = normalize_japanese_preserve_case(value).strip
      title = title.gsub(/(終日|一日中|1日中|丸一日|まる一日|全日|all\s*day)(?:で|に|の)?/i, '')
      title = title.gsub(/\A[\s、。,.，．・:：;；]+/, '')
      title = title.gsub(/\A(?:時|じ|分|間|半)(?:に|から|で)?/, '')
      title = title.gsub(/\A半(?=会議|打ち合わせ|打合せ|ミーティング|作業|学習|勉強|確認|レビュー|電話)/, '')
      title = title.gsub(/\A(?:から|まで|以降|の間|間で|間に)+/, '')
      title = title.gsub(/\A(?:am|pm|朝イチ|朝一|午前中|午前|午後|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午)\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)?/i, '')
      title = title.gsub(/\A朝\s*(?:から|以降|まで|の間|間で|に|で|頃|ごろ)/, '')
      title = title.gsub(/\A(?:朝イチ|朝一|午前中|午前|午後|夕方|放課後|深夜|未明|夜|よる|今夜|今晩|昼|お昼|正午|朝)\z/, '')
      title = title.gsub(/^(に|は|で|を|と|の|から|間|半)+/, '')
      title = title.gsub(/\s*(を)?(入れてください|入れて|入れる|追加してください|追加して|追加|登録してください|登録して|登録|作ってください|作って|作る|確保してください|確保して|確保|お願いします|お願い|してください|して)\s*$/, '')
      title = title.gsub(/\s*(?:したい|やりたい)\s*$/, '')
      title = title.gsub(/\s*の(?:時間|予定)\s*$/, '')
      title = title.gsub(/\A(?:だけ|少しだけ|ちょっとだけ)\s*/, '')
      title = strip_request_action_suffix(title)
      title = title.gsub(/\s*(を|に|は|で|と|の)\s*$/, '')
      title = title.gsub(/\A[\s、。,.，．・:：;；]+|[\s、。,.，．・:：;；]+\z/, '').strip
      title.present? ? title : '予定'
    end

    def request_phrase_only?(value)
      normalize_japanese(value).match?(/\A(入れて|追加|お願い|お願いします|ください|して|作って|作る|確保して|確保)+\z/)
    end

    def clean_local_title(value)
      title = clean_activity_title(value)
      title.blank? || title.length > 18 || request_phrase_only?(title) ? local_title_from_text(title) : title
    end

    def local_title_from_text(text)
      normalized = normalize_japanese(text)
      return focus_work_title_from_text(normalized) if focus_work_request?(normalized)
      return 'ストレッチ' if normalized.match?(/ストレッチ|体操/)
      return '休憩' if normalized.include?('休憩')
      return 'チャット' if normalized.include?('チャット')
      return '電話' if normalized.match?(/電話|tel|コール|call/)
      return '会う予定' if normalized.match?(/会う|会って|遊ぶ/)
      return '学校の準備' if normalized.include?('学校の準備')
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

    def schedule_summary_request?(text)
      normalized = normalize_japanese(text)
      return false if schedule_organization_request?(normalized)
      return false if normalized.match?(/(?:入れて|追加|登録|作って|変更|削除|消して|通知|リマインダー)/)

      explicit_summary =
        normalized.match?(/(?:今日|明日|明後日|今週|来週).*(?:まとめ|要約|何がある|教えて|注意点|忙しい日|多い日|詰まっている日|空き状況)/) ||
        normalized.match?(/(?:予定|スケジュール).*(?:まとめ|要約|確認|チェック|教えて|何がある|注意|忙しい|多い|詰ま|空き状況)/) ||
        normalized.match?(/(?:今日|明日|今週|来週)何がある|忙しい日/)

      explicit_summary.present?
    end

    def schedule_summary_range(text)
      now = context_now
      normalized = normalize_japanese(text)

      if normalized.include?('明日') || normalized.include?('あした')
        date = now.to_date + 1
        return ['明日', date, date]
      end

      if normalized.include?('明後日') || normalized.include?('あさって')
        date = now.to_date + 2
        return ['明後日', date, date]
      end

      if normalized.include?('来週')
        start_date = beginning_of_week(now.to_date) + 7
        return ['来週', start_date, start_date + 6]
      end

      if normalized.include?('今週') || normalized.include?('忙しい日')
        start_date = beginning_of_week(now.to_date)
        return ['今週', start_date, start_date + 6]
      end

      if (date = first_local_date_from_text(text))
        return [date == now.to_date ? '今日' : date.strftime('%-m/%-d'), date, date]
      end

      ['今日', now.to_date, now.to_date]
    end

    def schedule_summary_message(period_label, events, range_start, range_end, include_attention: false)
      if events.empty?
        return "#{period_label}の予定はありません。"
      end

      lines = []
      lines << "#{period_label}の予定は#{events.length}件あります。"
      lines << ''
      grouped = events.group_by { |event| event_date_for_group(event) || range_start }
      grouped.sort_by { |date, _| date }.each do |date, rows|
        lines << date.strftime('%-m/%-d') if range_start != range_end
        rows.sort_by { |event| event_time_for_sort(event) || app_time_zone.local(date.year, date.month, date.day, 23, 59, 0) }.each do |event|
          lines << "- #{format_event_for_summary(event)}"
        end
      end

      attention = schedule_attention_line(events, include_attention: include_attention)
      lines << '' << attention if attention.present?
      lines.join("\n")
    end

    def busy_days_message(period_label, events, range_start, range_end)
      if events.empty?
        return "#{period_label}の予定はありません。忙しい日はありません。"
      end

      counts = events.group_by { |event| event_date_for_group(event) || range_start }.transform_values(&:length)
      max_count = counts.values.max || 0
      busy = counts.select { |_date, count| count == max_count && count.positive? }.keys.sort
      lines = []
      lines << "#{period_label}で一番忙しい日は#{busy.map { |date| date.strftime('%-m/%-d') }.join('、')}です。"
      lines << "予定数は#{max_count}件です。"
      lines << ''
      counts.sort_by { |date, _count| date }.each do |date, count|
        lines << "- #{date.strftime('%-m/%-d')}: #{count}件"
      end
      lines.join("\n")
    end

    def schedule_attention_line(events, include_attention: false)
      all_day_count = events.count { |event| ActiveModel::Type::Boolean.new.cast(event.to_h[:all_day] || event.to_h['all_day']) }
      timed_count = events.length - all_day_count
      return "終日予定が#{all_day_count}件あります。時間付き予定の前後に余裕を確認してください。" if all_day_count.positive? && timed_count.positive?
      return '予定が多めです。移動や準備時間を確保してください。' if events.length >= 4
      return '注意点は大きくありません。必要なら空き時間候補も出せます。' if include_attention

      nil
    end

    def format_event_for_summary(event)
      attrs = event.to_h
      title = attrs[:title] || attrs['title'] || '予定'
      all_day = ActiveModel::Type::Boolean.new.cast(attrs[:all_day] || attrs['all_day'])
      return "終日: #{title}" if all_day

      start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])
      end_at = parse_context_time(attrs[:end_at] || attrs['end_at'])
      return title.to_s unless start_at && end_at

      "#{start_at.strftime('%H:%M')} - #{end_at.strftime('%H:%M')} #{title}"
    end

    def event_date_for_group(event)
      attrs = event.to_h
      parse_context_time(attrs[:start_at] || attrs['start_at'])&.to_date
    end

    def event_time_for_sort(event)
      attrs = event.to_h
      parse_context_time(attrs[:start_at] || attrs['start_at'])
    end

    def personal_events_between_dates(range_start, range_end)
      start_time = app_time_zone.local(range_start.year, range_start.month, range_start.day, 0, 0, 0)
      end_time = app_time_zone.local(range_end.year, range_end.month, range_end.day, 23, 59, 59)

      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)
        attrs = event.to_h
        start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])
        end_at = parse_context_time(attrs[:end_at] || attrs['end_at'])
        start_at && end_at && end_at > start_time && start_at <= end_time
      end
    end

    def open_slot_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/空き|空いて|空い?ている|空いてる|空き時間|空いている時間/)
      return false if normalized.match?(/まとめ|要約|確認|忙しい日/)
      true
    end

    def reminder_request?(text)
      normalize_japanese(text).match?(/リマインダー|通知|知らせて|アラート|remind/i)
    end

    def reminder_minutes_before(text)
      normalized = normalize_japanese(text)
      return Regexp.last_match[:value].to_i * 60 if normalized.match(/(?<value>\d{1,2})\s*時間前/)
      return Regexp.last_match[:value].to_i if normalized.match(/(?<value>\d{1,3})\s*分前/)
      return 60 if normalized.match?(/1時間前|一時間前/)
      return 15 if normalized.match?(/少し前/)
      30
    end

    def reminder_clarification_response(message, matched_count)
      {
        assistant_message: message,
        recommendations: [],
        provider: 'rails-local-event-reminder-clarification-v1',
        policy_run: local_policy_run('rails-local-event-reminder-clarification-v1', { matched_count: matched_count }),
        tool_invocations: []
      }
    end

    def existing_event_update_payload(event, text)
      attrs = event.to_h
      current_start = parse_context_time(attrs[:start_at] || attrs['start_at'])
      current_end = parse_context_time(attrs[:end_at] || attrs['end_at'])
      return nil unless current_start && current_end

      start_minute, parsed_duration = parse_local_time_and_duration(text, default_duration: ((current_end - current_start) / 60).round)
      new_date = first_local_date_from_text(text) || current_start.to_date
      return nil unless new_date || start_minute

      all_day = ActiveModel::Type::Boolean.new.cast(attrs[:all_day] || attrs['all_day'])
      duration = parsed_duration || ((current_end - current_start) / 60).round

      if all_day && start_minute.blank?
        start_at = app_time_zone.local(new_date.year, new_date.month, new_date.day, 0, 0, 0)
        end_at = start_at + [(current_end.to_date - current_start.to_date).to_i, 1].max.days
        return {
          'start_at' => start_at.iso8601,
          'end_at' => end_at.iso8601,
          'all_day' => true
        }
      end

      start_minute ||= current_start.hour * 60 + current_start.min
      start_at = app_time_zone.local(new_date.year, new_date.month, new_date.day, start_minute / 60, start_minute % 60, 0)
      end_at = start_at + duration.minutes
      {
        'start_at' => start_at.iso8601,
        'end_at' => end_at.iso8601,
        'all_day' => false
      }
    end

    def format_datetime_range_for_message(start_value, end_value, all_day)
      start_at = parse_context_time(start_value)
      end_at = parse_context_time(end_value)
      return '' unless start_at && end_at

      if ActiveModel::Type::Boolean.new.cast(all_day)
        inclusive_end = (end_at.to_date - 1)
        return start_at.strftime('%-m/%-d 終日') if inclusive_end <= start_at.to_date
        return "#{start_at.strftime('%-m/%-d')}〜#{inclusive_end.strftime('%-m/%-d')} 終日"
      end

      "#{start_at.strftime('%-m/%-d %H:%M')} - #{end_at.strftime('%H:%M')}"
    end

    def parse_context_time(value)
      return nil if value.blank?
      app_time_zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def schedule_organization_request?(text)
      normalize_japanese(text).match?(/(?:(?:予定|スケジュール).*(?:多すぎ|多い|詰ま|パンパン|整理|見直|棚卸|減ら|削り|移動))|(?:整理したい|見直したい|棚卸ししたい)/)
    end

    def schedule_organization_range(text)
      now = context_now.to_date

      if normalize_japanese(text).include?('来週')
        start_date = now + ((8 - now.wday) % 7)
        return ['来週', start_date, start_date + 6]
      end

      if normalize_japanese(text).include?('今週')
        start_date = now - ((now.wday + 6) % 7)
        return ['今週', start_date, start_date + 6]
      end

      ['直近1週間', now, now + 6]
    end

    def personal_events_between_dates(start_date, end_date)
      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)

        attrs = event.to_h
        start_at = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
        start_at && start_at.to_date >= start_date && start_at.to_date <= end_date
      end
    end

    def focus_work_request?(text)
      normalize_japanese(text).match?(/集中作業|集中して|深い作業|ディープワーク|focus|作業時間|作業の時間|資料作成|資料を作|メモ整理|レビュー時間|課題時間|課題|宿題|復習|勉強|学習/)
    end

    def focus_work_title_from_text(text)
      preserved_subject_title = subject_study_activity_title_from_text(text)
      return preserved_subject_title if preserved_subject_title.present? && preserved_subject_title.match?(/[A-Z]/)

      normalized = normalize_japanese(text)
      return '資料作成' if normalized.match?(/資料作成|資料を作/)
      return 'メモ整理' if normalized.include?('メモ整理')
      return 'レビュー時間' if normalized.include?('レビュー時間')
      return '課題時間' if normalized.match?(/課題|宿題/)
      return '復習' if normalized.include?('復習')
      return '勉強' if normalized.match?(/勉強|学習/)

      '集中作業'
    end

    def event_mutation_or_reference_request?(text)
      normalized = normalize_japanese(text)
      existing_event_delete_request?(normalized) ||
        reminder_request?(normalized) ||
        normalized.match?(/変更|移動|ずらして|リスケ|延期|前倒し|削除|消して|消す|消したい|キャンセル|取り消し|通知|リマインダー/)
    end

    def recurrence_request?(text)
      normalize_japanese(text).match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)
    end

    def negative_reminder_offset_match(text)
      normalized = normalize_japanese(text)
      match = normalized.match(/[-−]\s*(?<value>\d{1,3}(?:\.\d+)?)\s*(?<unit>分|時間)\s*前/)
      return nil unless match

      "-#{match[:value]}#{match[:unit]}前"
    end

    def explicit_reminder_offset_present?(text)
      normalized = normalize_japanese(text)
      normalized.match?(/(?<![-−])\d{1,3}\s*分前/) ||
        normalized.match?(/(?<![-−])\d{1,2}\s*時間前/) ||
        normalized.match?(/一時間前|少し前/)
    end

    def explicit_date_weekday_mismatch(text)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<year>\d{4})年(?<month>1[0-2]|0?[1-9])月(?<day>3[01]|[12]\d|0?[1-9])日?\s*(?:は|に)?\s*(?<weekday>[月火水木金土日])(?:曜|曜日)?/)
      return nil unless match

      date = Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
      requested = WEEKDAY_MAP[match[:weekday]]
      return nil if requested.nil? || date.wday == requested

      {
        date_label: date.strftime('%Y年%-m月%-d日'),
        requested_weekday: WEEKDAY_LABELS[requested],
        actual_weekday: WEEKDAY_LABELS[date.wday]
      }
    rescue StandardError
      nil
    end

    def morning_night_conflict_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/朝\s*夜|朝夜|夜\s*朝|夜朝/)
      return false if event_mutation_or_reference_request?(normalized)

      first_local_date_from_text(normalized).present? || normalized.match?(/入れて|追加|登録|作って|予定|勉強|学習|会議|作業/)
    end

    def vague_open_slot_without_details?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/空いてるところ|空いているところ|空き時間|空き|空いて/)
      return false if focus_work_request?(normalized)
      return false if explicit_time_present?(normalized)
      return false if explicit_duration_minutes(normalized).present?

      title = clean_activity_title(remove_date_time_phrases(normalized).gsub(/(?:の)?(?:空いてるところ|空いているところ|空き時間|空き|空いて)(?:で|に)?/, ''))
      title.blank? || title == '予定' || insufficient_activity_title?(title)
    end

    def date_only_schedule_request?(text)
      normalized = normalize_japanese(text)
      return false unless first_local_date_from_text(normalized)
      return false if explicit_time_present?(normalized) || period_window_hint?(normalized)
      return false if explicit_duration_minutes(normalized).present?

      title = clean_activity_title(remove_date_time_phrases(normalized))
      title.blank? || title == '予定' || request_phrase_only?(title)
    end

    def date_person_only_schedule_request?(text)
      normalized = normalize_japanese(text)
      return false unless first_local_date_from_text(normalized)
      return false if explicit_time_present?(normalized) || period_window_hint?(normalized) || explicit_all_day_request?(normalized)

      rest = clean_activity_title(remove_date_time_phrases(normalized))
      return false if known_activity_title?(rest)
      return false if location_or_movement_activity_title?(rest)

      rest.match?(/\A[一-龥ぁ-んァ-ヶA-Za-z0-9_\-]{1,18}(?:さん|くん|君|ちゃん)?\z/)
    end

    def location_or_movement_activity_title?(title)
      normalized = normalize_japanese(title)
      normalized.match?(/(?:に|へ)(?:行く|行き|向かう|移動|帰る|帰省|戻る)|(?:帰る|帰省|戻る)\z/)
    end

    def known_activity_title?(title)
      normalize_japanese(title).match?(/会議|打ち合わせ|打合せ|ミーティング|電話|作業|資料|メモ|確認|レビュー|飲み|食事|旅行|帰省|休み|休暇|勉強|学習|課題|チャット|営業|定例|会う|面談|相談/)
    end

    def weekend_period_request?(text)
      normalize_japanese(text).match?(/土日|週末/)
    end

    def remove_weekend_period_phrases(text)
      normalize_japanese_preserve_case(text)
        .gsub(/(?:再来週末|来週末|今週末|週末|土日)(?:で|に|から|まで)?/, '')
        .gsub(/\A\s*(?:の|を|に|で)\s*/, '')
        .strip
    end

    def weekend_start_date_for_text(text)
      normalized = normalize_japanese(text)
      today = context_now.to_date
      saturday = next_weekday_on_or_after(today, 6)
      saturday += 14 if normalized.include?('再来週末')
      saturday += 7 if normalized.include?('来週末') && !normalized.include?('再来週末')
      saturday
    end

    def multi_intent_schedule_request?(text)
      normalized = normalize_japanese(text)
      clauses = split_event_clauses(normalized)
      return false unless clauses.length >= 2
      return false unless clauses.any? { |clause| explicit_time_present?(clause) }
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)

      normalized.match?(/、|。|,|;|；|そして|それから/)
    end

    def parse_multi_explicit_event_clause(clause, shared_date)
      descriptor = local_event_descriptor(clause)
      title = clean_activity_title(descriptor[:activity_title].presence || descriptor[:title])
      explicit_duration = explicit_duration_minutes(clause)
      start_minute, parsed_duration = parse_local_time_and_duration(clause, default_duration: 60)
      {
        clause: clause,
        date: first_local_date_from_text(clause) || shared_date,
        title: title,
        start_minute: start_minute,
        duration_minutes: explicit_duration.presence || parsed_duration.presence || 60,
        time_present: explicit_time_present?(clause),
        contact_name: descriptor[:contact_name],
        participant_names: descriptor[:participant_names],
        location: descriptor[:location],
        buffer_minutes: descriptor[:buffer_minutes]
      }
    end

    def explicit_timed_schedule_add_request?(text)
      normalized = normalize_japanese(text)
      return false if event_mutation_or_reference_request?(normalized)
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return false if explicit_all_day_request?(normalized)
      return false if multi_intent_schedule_request?(normalized)

      first_local_date_from_text(normalized).present? && explicit_time_present?(normalized)
    end

    def conflicting_events(events, start_at, end_at)
      Array(events).select do |event|
        s, e = event_time_range(event)
        s && e && e > start_at && s < end_at
      end
    end

    def event_time_range(event)
      return [nil, nil] unless event.respond_to?(:to_h)

      attrs = event.to_h
      s = parse_context_time(attrs[:start_at] || attrs['start_at'])
      e = parse_context_time(attrs[:end_at] || attrs['end_at'])
      [s, e]
    end

    def event_title(event)
      attrs = event.respond_to?(:to_h) ? event.to_h : {}
      attrs[:title] || attrs['title'] || '予定'
    end

    def next_available_event_after_conflict(date:, duration:, conflicts:, title:, descriptor:)
      latest_end = conflicts.filter_map { |event| event_time_range(event).last }.max
      return nil unless latest_end && latest_end.to_date == date

      minute = round_up_to_interval(latest_end.hour * 60 + latest_end.min, 30)
      minute = [minute, 6 * 60].max
      latest_start = 22 * 60 - duration

      while minute <= latest_start
        start_at = app_time_zone.local(date.year, date.month, date.day, minute / 60, minute % 60, 0)
        end_at = start_at + duration.minutes
        if start_at > context_now && !conflicts_with_events?(context_value(:personal_events), start_at, end_at)
          return local_event_hash(
            title: title,
            start_at: start_at,
            end_at: end_at,
            all_day: false,
            color: color_for_local_title(title),
            category: category_for_local_title(title),
            intent: intent_for_local_title(title),
            schedule_profile: profile_for_local_title(title),
            reason: '指定時刻が既存予定と重なったため、同じ日の代替候補を作成しました。',
            contact_name: descriptor[:contact_name],
            participant_names: descriptor[:participant_names],
            location: descriptor[:location],
            buffer_minutes: descriptor[:buffer_minutes]
          )
        end
        minute += 30
      end

      nil
    end

    def round_up_to_interval(minute, interval)
      ((minute.to_i + interval - 1) / interval) * interval
    end

    def between_existing_events_request?(text)
      normalized = normalize_japanese(text)
      normalized.match?(/予定.+と.+予定.+の間/) ||
        normalized.match?(/(?:予定|イベント|会議|授業|部活).+の間に.*休憩/) ||
        normalized.match?(/休憩.*(?:予定|イベント|会議|授業|部活).+間/) ||
        normalized.match?(/.+と.+の間に.*休憩/)
    end

    def ambiguous_schedule_request?(text)
      normalized = normalize_japanese(text)
      return false if schedule_organization_request?(normalized)
      return false if between_existing_events_request?(normalized)
      return false if normalized.match?(/空き|空いて|忙しくない|都合|候補|いつ|できれば|無理なら/)
      return false if normalized.match?(/毎日|毎朝|毎晩|毎週|隔週|毎月/)

      return true if normalized.match?(/\A(?:打ち合わせ|打合せ|会議|ミーティング|調整|相談)\z/)
      return true if normalized.match?(/\A.{1,18}さんと(?:調整して|相談して|打ち合わせ|打合せ)\z/) && !explicit_time_present?(normalized) && first_local_date_from_text(normalized).nil?
      return true if normalized.match?(/\A(?:午前|午後|夕方|放課後|夜|昼)(?:から|〜|~|-).*(?:の間|間で)\z/)

      return false if explicit_time_present?(normalized)
      return false if first_local_date_from_text(normalized)
      return false if target_weekdays(normalized).any?
      return false if normalized.match?(/\d+\s*(?:分|時間)|午前|午後|朝|昼|夕方|放課後|夜|今夜|今晩|深夜|未明/)

      normalized.match?(/\A\s*(?:予定を入れたい|予定を入れて|予定を作りたい|いい感じに調整して|調整して)\s*\z/) ||
        normalized.match?(/友(?:達|人).*予定.*(?:いい感じ|調整)/) ||
        normalized.match?(/何か.*予定|予定.*何か/)
    end

    def past_datetime_request?(text)
      normalized = normalize_japanese(text)
      return false unless normalized.match?(/昨日|きのう|一昨日|おととい|先週/)
      return false if normalized.match?(/削除|消して|キャンセル|取り消し|変更|移動|ずらして|リスケ|整理|見直/)

      normalized.match?(/入れて|入れる|作って|作る|追加|登録|確保|予定/)
    end

    def invalid_explicit_date_match(text)
      normalized = normalize_japanese(text)
      now = context_now

      normalized.to_enum(:scan, /(?:(?<year>\d{4})年)?(?<month>\d{1,2})(?:月|[\/.\-．])(?<day>\d{1,2})日?/).each do
        match = Regexp.last_match
        next if date_match_fragment_of_time_range?(normalized, match)

        month = match[:month].to_i
        day = match[:day].to_i
        year = match[:year].present? ? match[:year].to_i : now.year
        next if month.between?(1, 12) && Date.valid_date?(year, month, day)

        return { raw: match[0], year: year, month: month, day: day }
      end

      nil
    end

    def date_match_fragment_of_time_range?(text, match)
      raw = match[0].to_s
      return false unless raw.match?(/[\-~〜]/)

      before = text[[match.begin(0) - 3, 0].max...match.begin(0)].to_s
      after = text[match.end(0)...[match.end(0) + 3, text.length].min].to_s
      before.match?(/[:：]\d{0,2}\z/) || after.match?(/\A[:：]\d{0,2}/)
    end

    def invalid_duration_match(text)
      normalized = normalize_japanese(text)
      patterns = [
        /(?:から|〜|~)\s*[-−]\s*\d{1,3}(?:\.\d+)?\s*(?:分|時間)?/,
        /(?:から|〜|~|-)\s*0+(?:\.0+)?\s*(?:分|時間)?(?![\d:：時])/,
        /(?<!\d)0\s*(?:分|時間)(?!後)/
      ]

      patterns.each do |pattern|
        match = normalized.match(pattern)
        return { raw: match[0] } if match
      end

      nil
    end

    def explicit_start_datetime_from_text(text)
      date = first_local_date_from_text(text)
      return nil unless date

      start_minute = parse_local_time_and_duration(text, default_duration: 30).first
      return nil unless start_minute

      app_time_zone.local(date.year, date.month, date.day, start_minute / 60, start_minute % 60, 0)
    end

    def invalid_explicit_time_match(text)
      explicit_time_matches(text).find { |match| !valid_clock_time?(match[:hour], match[:minute]) }
    end

    def explicit_time_present?(text)
      explicit_time_matches(text).any?
    end

    def explicit_time_matches(text)
      normalized = normalize_period_words(normalize_japanese(text))
      matches = []

      normalized.to_enum(:scan, /(?<!\d)(?<hour>\d{1,2})[:：](?<minute>\d{2})(?!\d)/).each do
        match = Regexp.last_match
        matches << { raw: match[0], hour: match[:hour].to_i, minute: match[:minute].to_i, start_index: match.begin(0) }
      end

      normalized.to_enum(:scan, /(?<!\d)(?<hour>\d{1,2})時(?!間)(?:(?<minute>\d{1,2})分?|(?<half>半))?/).each do
        match = Regexp.last_match
        matches << {
          raw: match[0],
          hour: match[:hour].to_i,
          minute: match[:half] ? 30 : match[:minute].to_i,
          start_index: match.begin(0)
        }
      end

      matches.sort_by { |match| match[:start_index] }
    end

    def valid_clock_time?(hour, minute)
      hour.to_i.between?(0, 23) && minute.to_i.between?(0, 59)
    end

    def invalid_explicit_time_range_match(text)
      normalized = normalize_period_words(normalize_japanese(text))
      return nil if normalized.match?(/翌日|翌朝|日またぎ/)

      explicit_time_range_matches(normalized).find do |range|
        range[:start_minute] && range[:end_minute] && range[:end_minute] <= range[:start_minute]
      end
    end

    def explicit_time_range_matches(text)
      normalized = normalize_japanese(text)
      ranges = []

      normalized.to_enum(:scan, /(?<start_hour>\d{1,2})[:：](?<start_minute>\d{2})\s*(?:から|〜|~|-)\s*(?<end_hour>\d{1,2})[:：](?<end_minute>\d{2})\s*(?:まで)?/).each do
        match = Regexp.last_match
        ranges << build_time_range_match(match[0], match[:start_hour], match[:start_minute], nil, match[:end_hour], match[:end_minute], nil)
      end

      normalized.to_enum(:scan, /(?<start_hour>\d{1,2})時(?!間)(?:(?<start_minute>\d{1,2})分?|(?<start_half>半))?\s*(?:から|〜|~|-)\s*(?<end_hour>\d{1,2})時(?!間)(?:(?<end_minute>\d{1,2})分?|(?<end_half>半))?\s*(?:まで)?/).each do
        match = Regexp.last_match
        ranges << build_time_range_match(match[0], match[:start_hour], match[:start_minute], match[:start_half], match[:end_hour], match[:end_minute], match[:end_half])
      end

      ranges.compact
    end

    def build_time_range_match(raw, start_hour, start_minute, start_half, end_hour, end_minute, end_half)
      s_hour = start_hour.to_i
      s_minute = start_half ? 30 : start_minute.to_i
      e_hour = end_hour.to_i
      e_minute = end_half ? 30 : end_minute.to_i
      return nil unless valid_clock_time?(s_hour, s_minute) && valid_clock_time?(e_hour, e_minute)

      { raw: raw, start_minute: s_hour * 60 + s_minute, end_minute: e_hour * 60 + e_minute }
    end

    def parse_local_time_and_duration(text, default_duration:)
      normalized = normalize_japanese(text)
      if (range = explicit_time_range_matches(normalize_period_words(normalized)).first)
        return [range[:start_minute], range[:end_minute] - range[:start_minute]]
      end

      duration = explicit_duration_minutes(normalized)
      duration = default_duration if duration.blank?

      start_minute = explicit_start_minute_from_text(normalized)
      [start_minute, duration]
    end

    def explicit_duration_minutes(text)
      normalized = normalize_japanese(text)
      return -1 if normalized.match?(/-\s*\d+(?:\.\d+)?\s*(?:分|時間)/)

      if (match = normalized.match(/(?<!-)(?<hours>\d+(?:\.\d+)?)\s*時間\s*半/))
        return (match[:hours].to_f * 60).to_i + 30
      end

      if (match = normalized.match(/(?<!-)(?<hours>\d+(?:\.\d+)?)\s*時間\s*(?<minutes>\d+)\s*分/))
        return (match[:hours].to_f * 60).to_i + match[:minutes].to_i
      end

      if (match = normalized.match(/(?<!-)(?<hours>\d+(?:\.\d+)?)\s*時間/))
        return (match[:hours].to_f * 60).to_i
      end

      if (match = normalized.match(/(?<!-)(?<minutes>\d+)\s*分/))
        return match[:minutes].to_i
      end

      nil
    end

    def explicit_start_minute_from_text(text)
      normalized = normalize_period_words(normalize_japanese(text))
      normalized = normalized.gsub(/([一二三四五六七八九十]+)(?=(?:時|じ))/) { japanese_integer(Regexp.last_match(1)) || Regexp.last_match(1) }

      if (match = normalized.match(/(?<period>am|pm|午前|午後|朝|午前中|夜|よる|今夜|今晩|夕方|昼|お昼)?\s*(?<hour>\d{1,2})[:：](?<minute>\d{1,2})/))
        return minute_from_hour_parts(match[:hour], match[:minute], match[:period])
      end

      if (match = normalized.match(/(?<period>am|pm|午前|午後|朝|午前中|夜|よる|今夜|今晩|夕方|昼|お昼)?\s*(?<hour>\d{1,2})\s*(?:時|じ)(?<half>半)?(?:\s*(?<minute>\d{1,2})\s*分?)?/))
        minute = match[:half].present? ? 30 : match[:minute]
        return minute_from_hour_parts(match[:hour], minute, match[:period])
      end

      return 12 * 60 if normalized.match?(/正午/)

      nil
    end

    def minute_from_hour_parts(hour_value, minute_value = nil, period = nil)
      hour = hour_value.to_i
      minute = minute_value.present? ? minute_value.to_i : 0
      return nil unless minute.between?(0, 59)

      hour = adjust_hour_for_period(hour, period)
      return nil unless hour.between?(0, 23)

      hour * 60 + minute
    end

    def adjust_hour_for_period(hour, period)
      normalized_period = normalize_japanese(period)

      case normalized_period
      when 'pm', '午後'
        hour += 12 if hour.between?(1, 11)
      when 'am', '午前', '朝', '午前中'
        hour = 0 if hour == 12 && normalized_period.in?(%w[am 午前])
      when '夜', 'よる', '今夜', '今晩'
        hour += 12 if hour.between?(1, 11)
      when '夕方'
        hour += 12 if hour.between?(1, 6)
      when '昼', 'お昼'
        hour += 12 if hour.between?(1, 5)
      end

      hour
    end

    def normalize_period_words(text)
      normalize_japanese(text)
        .gsub(/(午前|朝)\s*12時/, '0時')
        .gsub(/(深夜|未明)\s*(\d{1,2})([:：]\d{2})/) { "#{deep_night_hour(Regexp.last_match[2].to_i)}#{Regexp.last_match[3]}" }
        .gsub(/(深夜|未明)\s*(\d{1,2})時/) { "#{deep_night_hour(Regexp.last_match[2].to_i)}時" }
        .gsub(/(午後|夕方|放課後|夜|今夜|今晩)\s*(\d{1,2})([:：]\d{2})/) { "#{period_hour(Regexp.last_match[2].to_i)}#{Regexp.last_match[3]}" }
        .gsub(/(午後|夕方|放課後|夜|今夜|今晩)\s*(\d{1,2})時/) { "#{period_hour(Regexp.last_match[2].to_i)}時" }
        .gsub(/(午前|朝)\s*(\d{1,2})時/) { "#{Regexp.last_match[2].to_i}時" }
    end

    def preferred_minute_window(text)
      normalized = normalize_period_words(normalize_japanese(text))
      return [13 * 60, 18 * 60] if normalized.include?('午後')
      return [12 * 60, 14 * 60] if normalized.match?(/昼|正午/)
      return [9 * 60, 12 * 60] if normalized.match?(/午前|朝/)
      return [17 * 60, 20 * 60] if normalized.match?(/夕方|放課後/)
      return [1 * 60, 4 * 60] if normalized.match?(/深夜|未明/)
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

    def participant_name_tokens_from_text(text)
      source = normalize_japanese_preserve_case(remove_date_time_phrases(text))
      source
        .scan(/([一-龥ぁ-んァ-ヶA-Za-z0-9_\-]+?)(?:さん|くん|君|ちゃん)?(?:と|との)(?=会議|定例|打ち合わせ|打合せ|ミーティング|飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー|旅行|通院|病院|レビュー|チャット|会う|遊ぶ|相談|予定)/)
        .flatten
        .map { |name| clean_activity_title(name) }
        .reject(&:blank?)
    end

    def matched_existing_events(text)
      date = first_local_date_from_text(text)
      title = local_title_from_text(text)
      descriptor = local_event_descriptor(text)
      names = (Array(descriptor[:participant_names]) + participant_name_tokens_from_text(text))
              .map { |name| normalize_japanese(name) }
              .reject(&:blank?)
              .uniq
      normalized_title = normalize_japanese(title)
      normalized_request = normalize_japanese(text)
      normalized_query_title = existing_event_title_query_from_text(text)

      Array(context_value(:personal_events)).select do |event|
        next false unless event.respond_to?(:to_h)

        attrs = event.to_h
        event_title = attrs[:title] || attrs['title']
        normalized_event_title = normalize_japanese(event_title)
        start_at = parse_context_time(attrs[:start_at] || attrs['start_at'])

        title_match =
          if normalized_query_title.present?
            normalized_event_title.include?(normalized_query_title) ||
              normalized_query_title.include?(normalized_event_title)
          else
            activity_match = existing_event_activity_match?(normalized_event_title, normalized_request)
            normalized_title.blank? || normalized_event_title.include?(normalized_title) || activity_match
          end

        name_match = names.empty? || names.any? { |name| normalized_event_title.include?(name) }
        date_match = date.blank? || (start_at && start_at.to_date == date)

        title_match && name_match && date_match
      end
    end

    def existing_event_activity_match?(event_title, request_text)
      request_tokens = existing_event_activity_tokens(request_text)
      event_tokens = existing_event_activity_tokens(event_title)
      (request_tokens & event_tokens).any?
    end

    def existing_event_activity_tokens(text)
      normalized = normalize_japanese(text)
      tokens = []
      tokens << 'meeting' if normalized.match?(/会議|ミーティング/)
      tokens << 'discussion' if normalized.match?(/打ち合わせ|打合せ/)
      tokens << 'regular_meeting' if normalized.match?(/定例/)
      tokens << 'consultation' if normalized.match?(/相談/)
      tokens << 'phone' if normalized.match?(/電話|tel|コール|call/)
      tokens << 'meal' if normalized.match?(/飲み会|飲み|食事|ご飯|ごはん|ランチ|ディナー/)
      tokens << 'trip' if normalized.match?(/旅行/)
      tokens << 'review' if normalized.match?(/レビュー/)
      tokens << 'hospital' if normalized.match?(/通院|病院/)
      tokens << 'chat' if normalized.match?(/チャット/)
      tokens << 'meetup' if normalized.match?(/会う|遊ぶ/)
      tokens
    end

    def format_event_for_message(event)
      attrs = event.to_h
      start_at = app_time_zone.parse((attrs[:start_at] || attrs['start_at']).to_s) rescue nil
      title = attrs[:title] || attrs['title']
      start_at ? "#{start_at.strftime('%-m/%-d %H:%M')} #{title}" : title.to_s
    end


    def travel_time_assist_request?(text)
      normalized = normalize_japanese(text)
      return false if existing_event_delete_request?(normalized) || reminder_request?(normalized)
      return false if normalized.match?(/変更|ずらして|リスケ|延期|前倒し|削除|消して|消す|消したい|キャンセル|取り消し|通知|リマインダー/)
      return false if recurrence_request?(normalized)
      return false if schedule_summary_request?(normalized) || schedule_organization_request?(normalized)
      return false if explicit_all_day_request?(normalized)

      date = first_local_date_from_text(normalized)
      start_minute, = parse_local_time_and_duration(normalized, default_duration: 60)
      return false unless date && start_minute

      route = extract_travel_route(normalized)
      destination = route[:destination].presence || extract_local_location(normalized)
      has_travel_details = route[:travel_minutes].to_i.positive? || normalized.match?(/移動時間|移動に|移動も|到着|着きたい|出発/)
      has_location_schedule = destination.present? && normalized.match?(/で(?=会議|定例|打ち合わせ|ミーティング|飲み会|食事|通院|レビュー|予定|面談|商談)/)
      return false if multi_intent_schedule_request?(normalized) && !has_travel_details

      has_travel_details || has_location_schedule
    end

    def extract_travel_route(text)
      normalized = normalize_japanese_preserve_case(text)
      compact = normalized.gsub(/[、。]/, ' ')
      result = { origin: nil, destination: nil, travel_minutes: nil }

      if (match = compact.match(/(?<origin>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})から(?<destination>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})まで(?:の)?(?:移動(?:時間)?は?|所要時間は?)?\s*(?<minutes>\d{1,3})\s*分/))
        result[:origin] = clean_travel_place(match[:origin])
        result[:destination] = clean_travel_place(match[:destination])
        result[:travel_minutes] = bounded_minutes(match[:minutes], min: 5, max: 240)
        return result
      end

      if (match = compact.match(/(?<origin>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})から(?<destination>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,30})(?:へ|に|まで)/))
        result[:origin] = clean_travel_place(match[:origin])
        result[:destination] = clean_travel_place(match[:destination])
      end

      result[:travel_minutes] ||= extract_travel_minutes(compact)
      result
    end

    def extract_travel_minutes(text)
      normalized = normalize_japanese(text)
      if (match = normalized.match(/移動(?:時間)?(?:は|に|で)?\s*(?<minutes>\d{1,3})\s*分/))
        return bounded_minutes(match[:minutes], min: 5, max: 240)
      end
      if (match = normalized.match(/(?<minutes>\d{1,3})\s*分\s*(?:移動|かかる|見て|みて)/))
        return bounded_minutes(match[:minutes], min: 5, max: 240)
      end
      nil
    end

    def extract_arrival_buffer_minutes(text)
      normalized = normalize_japanese(text)
      if (match = normalized.match(/(?<minutes>\d{1,3})\s*分前(?:に)?(?:到着|着きたい|着く)/))
        return bounded_minutes(match[:minutes], min: 0, max: 180)
      end
      if (match = normalized.match(/到着(?:バッファ|余裕)?\s*(?<minutes>\d{1,3})\s*分/))
        return bounded_minutes(match[:minutes], min: 0, max: 180)
      end
      0
    end

    def bounded_minutes(value, min:, max:)
      minutes = value.to_i
      return nil if minutes < min || minutes > max
      minutes
    end

    def clean_travel_place(value)
      raw = normalize_japanese_preserve_case(value)
      cleaned = remove_date_time_phrases(raw)
        .gsub(/\A(?:明日|あした|今日|きょう|来週|今週|再来週|に|で|を|と|の|から|まで|へ)+/, '')
        .gsub(/(?:に|で|を|と|の|から|まで|へ)\z/, '')
        .strip
      cleaned.presence
    end

    def remove_travel_assist_phrases(text, destination:, origin: nil)
      value = normalize_japanese_preserve_case(text)
      [origin, destination].compact.each do |place|
        escaped = Regexp.escape(place.to_s)
        value = value.gsub(/#{escaped}(?:で|に|へ|まで|から)?/, '')
      end
      value
        .gsub(/移動(?:時間)?(?:は|に|で)?\s*\d{1,3}\s*分/, '')
        .gsub(/\d{1,3}\s*分\s*(?:移動|かかる|見て|みて)/, '')
        .gsub(/\d{1,3}\s*分前(?:に)?(?:到着|着きたい|着く)/, '')
        .gsub(/到着(?:バッファ|余裕)?\s*\d{1,3}\s*分/, '')
        .gsub(/(?:から|まで|へ|に)\s*/, ' ')
        .strip
    end

    def travel_assist_main_title(title_source, descriptor)
      title = clean_activity_title(remove_date_time_phrases(title_source))
      title = descriptor[:activity_title].presence || descriptor[:title] if insufficient_activity_title?(title) || title == '予定'
      clean_activity_title(title)
    end

    def travel_assist_main_description(destination:, arrival_buffer_minutes:)
      parts = ['AI秘書提案の予定候補']
      parts << "目的地: #{destination}" if destination.present?
      parts << "到着バッファ: #{arrival_buffer_minutes}分" if arrival_buffer_minutes.to_i.positive?
      parts.join(' / ')
    end

    def travel_event_hash(origin:, destination:, start_at:, end_at:, travel_minutes:, arrival_buffer_minutes:)
      title = origin.present? ? "移動: #{origin} → #{destination}" : "移動: #{destination}へ"
      payload = local_event_hash(
        title: title,
        start_at: start_at,
        end_at: end_at,
        all_day: false,
        color: '#06b6d4',
        category: 'personal',
        intent: 'travel',
        schedule_profile: 'travel',
        reason: '本予定に間に合うよう、明示された移動時間から逆算しました。',
        location: destination,
        buffer_minutes: arrival_buffer_minutes
      )
      payload['description'] = travel_label(origin: origin, destination: destination)
      payload['travel_assist'] = {
        'origin' => origin,
        'destination' => destination,
        'travel_minutes' => travel_minutes,
        'arrival_buffer_minutes' => arrival_buffer_minutes,
        'phase' => '5a'
      }.compact
      payload
    end

    def travel_label(origin:, destination:)
      origin.present? ? "#{origin}から#{destination}へ移動" : "#{destination}へ移動"
    end

    def extract_local_location(text)
      m = normalize_japanese(text).match(/(?<location>[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-]{1,20})で(?=会議|定例|打ち合わせ|ミーティング|飲み会|食事|旅行|通院|レビュー|予定)/)
      return nil unless m
      clean_travel_place(m[:location])
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

    def deep_night_hour(hour)
      hour == 12 ? 0 : hour
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
      return nil if minutes <= 0

      [[minutes, 5].max, 480].min
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

    def beginning_of_week(date)
      date - ((date.wday + 6) % 7)
    end

    def relative_day_count_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<count>\d+|一|二|三|四|五|六|七|八|九|十|十一|十二|十三|十四|十五|十六|十七|十八|十九|二十)(?:日|にち)後/)
      return nil unless match

      count = japanese_integer(match[:count])
      return nil unless count&.positive?

      now.to_date + count
    end

    def relative_final_weekday_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<rel>再来月|来月|今月)の?最終(?<weekday>[月火水木金土日])(?:曜|曜日)?/)
      return nil unless match

      month_offset = case match[:rel]
                     when '再来月' then 2
                     when '来月' then 1
                     else 0
                     end
      target_month = now.to_date >> month_offset
      last_day = target_month.end_of_month
      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless weekday

      last_day - ((last_day.wday - weekday) % 7)
    end

    def japanese_integer(value)
      raw = value.to_s
      return raw.to_i if raw.match?(/\A\d+\z/)

      digits = {
        '〇' => 0, '零' => 0,
        '一' => 1, '二' => 2, '三' => 3, '四' => 4, '五' => 5,
        '六' => 6, '七' => 7, '八' => 8, '九' => 9
      }
      return digits[raw] if digits.key?(raw)
      return 10 if raw == '十'

      if raw.include?('十')
        head, tail = raw.split('十', 2)
        tens = head.blank? ? 1 : digits[head]
        ones = tail.blank? ? 0 : digits[tail]
        return nil if tens.nil? || ones.nil?

        tens * 10 + ones
      end
    end

    def relative_weekday_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?<rel>再来週|来週|翌週|今週)?\s*(?<weekday>[月火水木金土日])(?:曜|曜日)/)
      return nil unless match

      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless weekday

      date = case match[:rel].to_s
             when '再来週'
               week_start = beginning_of_week(now.to_date) + 14
               week_start + ((weekday - week_start.wday) % 7)
             when '来週', '翌週'
               week_start = beginning_of_week(now.to_date) + 7
               week_start + ((weekday - week_start.wday) % 7)
             when '今週'
               week_start = beginning_of_week(now.to_date)
               week_start + ((weekday - week_start.wday) % 7)
             else
               next_weekday_on_or_after(now.to_date, weekday)
             end

      match[:rel].to_s == '今週' && date < now.to_date ? date + 7 : date
    end

    def relative_nth_weekday_date(text, now)
      normalized = normalize_japanese(text)
      match = normalized.match(/(?:(?<rel>来月|翌月|今月)の?)?第(?<ordinal>[1-5一二三四五])(?<weekday>[月火水木金土日])(?:曜|曜日)?/)
      return nil unless match

      ordinal = japanese_ordinal_to_i(match[:ordinal])
      weekday = WEEKDAY_MAP[match[:weekday]]
      return nil unless ordinal && weekday

      year = now.year
      month = now.month
      if match[:rel].to_s.match?(/来月|翌月/)
        year, month = add_months(year, month, 1)
      end

      date = nth_weekday_date(year, month, weekday, ordinal)
      if date && match[:rel].blank? && date < now.to_date
        year, month = add_months(year, month, 1)
        date = nth_weekday_date(year, month, weekday, ordinal)
      end
      date
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

    def explicit_all_day_request?(text)
      normalize_japanese(text).match?(/終日|一日中|1日中|丸一日|まる一日|全日|all\s*day/i)
    end

    def default_start_minute_for_text(text, title)
      return preferred_minute_window(text).first if period_window_hint?(text)

      default_start_minute_for_title(title)
    end

    def period_window_hint?(text)
      normalize_japanese(text).match?(/午後|午前|朝イチ|朝一|朝|昼|正午|夕方|放課後|深夜|未明|夜|今夜|今晩/)
    end

    def default_start_minute_for_title(title)
      return 10 * 60 if title.to_s.match?(/集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間|課題時間|課題|宿題|復習|勉強|学習/)
      return 7 * 60 if title.to_s.match?(/ストレッチ|体操/)

      title.to_s.match?(/飲み|食事|ランチ|ディナー/) ? 18 * 60 : 9 * 60
    end

    def default_duration_minutes_for_title(title)
      case title
      when /飲み|食事/ then 120
      when /旅行/ then 240
      when /ストレッチ|体操|休憩/ then 10
      when /電話|チャット/ then 30
      when /集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間|課題時間|課題|宿題|復習|勉強|学習/ then 90
      when /定例|会議|調整|レビュー/ then 60
      else 60
      end
    end

    def color_for_local_title(title)
      title.to_s.match?(/飲み|食事|旅行|会う|チャット|休憩|ストレッチ/) ? '#f97316' : '#3b82f6'
    end

    def category_for_local_title(title)
      return 'leisure' if title.to_s.match?(/飲み|食事|旅行|会う|チャット|休憩|ストレッチ/)
      return 'study' if title.to_s.match?(/学校|課題|宿題|復習|勉強|学習/)

      'work'
    end

    def intent_for_local_title(title)
      case title
      when /飲み|食事/ then 'meal'
      when /旅行/ then 'travel'
      when /会う|チャット/ then 'social'
      when /休憩/ then 'break'
      when /ストレッチ|体操/ then 'routine'
      when /学校|課題|宿題|復習|勉強|学習/ then 'study'
      when /集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間/ then 'focus_work'
      when /定例|会議/ then 'meeting'
      else 'general'
      end
    end

    def profile_for_local_title(title)
      return 'social' if title.to_s.match?(/飲み|食事|会う|チャット/)
      return 'travel' if title.to_s.match?(/旅行/)
      return 'routine' if title.to_s.match?(/ストレッチ|体操/)
      return 'study' if title.to_s.match?(/学校|課題|宿題|復習|勉強|学習/)
      return 'focus_work' if title.to_s.match?(/集中作業|深い作業|作業時間|作業の時間|資料作成|メモ整理|レビュー時間/)

      'work'
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

    def normalize_japanese_preserve_case(value)
      value.to_s.unicode_normalize(:nfkc).strip
    rescue StandardError
      value.to_s.strip
    end

    def app_time_zone
      # Local structured AI parsing must use the user's/context timezone.
      # In Render, Rails Time.zone may be UTC; if we use UTC here, "15:00" appears as next-day 00:00 in Japan.
      raw_timezone = context_value(:timezone).to_s.strip
      zone = raw_timezone.present? ? Time.find_zone(raw_timezone) : nil

      raw_env_timezone = ENV['APP_TIMEZONE'].to_s.strip
      zone ||= raw_env_timezone.present? ? Time.find_zone(raw_env_timezone) : nil

      current_zone = Time.zone
      if zone.nil? && current_zone && !%w[UTC Etc/UTC].include?(current_zone.tzinfo.name)
        zone = current_zone
      end

      zone || Time.find_zone('Asia/Tokyo') || ActiveSupport::TimeZone['Asia/Tokyo']
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
      normalized = normalize_japanese(text)
      weekdays = []

      WEEKDAY_MAP.each do |token, weekday|
        next if token.length == 1

        weekdays << weekday if normalized.include?(token) && !weekdays.include?(weekday)
      end

      normalized.scan(/(?:毎週|隔週)\s*([月火水木金土日](?:[・･、,\/／と]?\s*[月火水木金土日])*)/) do |match|
        match.first.scan(/[月火水木金土日]/).each do |char|
          weekday = WEEKDAY_MAP[char]
          weekdays << weekday if weekday && !weekdays.include?(weekday)
        end
      end

      normalized.scan(/(?<![0-9])([月火水木金土日])(?=$|[\s　、,。と\/／・･にを])/).each do |match|
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
