# frozen_string_literal: true

module SecretaryCreation
  # The provider's existing parser remains the only natural-language interpreter.
  # A stricter creation gate requires explicit times instead of its UI defaults.
  class EventParser < Ai::Client
    def self.call(user:, messages:, now:)
      text = messages.first.to_s
      context = {
        scope: 'home', now: now.iso8601, timezone: 'Asia/Tokyo',
        user: { id: user.id, name: user.name }, group: nil,
        conversation: { id: nil, recent_messages: [] },
        personal_events: [], candidate_group_events: [], peer_events: [], friends: [], contacts: [],
        recent_group_messages: [], recent_direct_messages: [], user_places: [], user_travel_routes: [],
        ai_user_preferences: [], ranking_history: []
      }
      new(context: context, user_message: text).creation_candidate(messages)
    end

    def creation_candidate(messages)
      conversation = compose_conversation(messages)
      @user_message = text = conversation.fetch(:interpretation_text)
      if ambiguous_datetime?(text)
        return clarification('日付または時刻が複数の候補になっています。登録する日付と開始・終了時刻を1つに決めて教えてください。')
      end
      if event_mutation_or_reference_request?(text) || recurrence_request?(text) ||
          text.match?(/毎年|繰り返|共有|招待|割り当て|参加者|グループ|登録しない|保存しない/)
        return rejected('ここでは単発の自分用予定を1件登録できます。変更・削除・通知・共有・繰り返しはまだ対応していません。')
      end

      if invalid_explicit_date_match(text) || invalid_explicit_time_match(text) || invalid_explicit_time_range_match(text) || invalid_duration_match(text)
        return clarification('日付または時刻を確認してください。有効な開始・終了日時を指定してください。')
      end
      date = first_local_date_from_text(text)
      return clarification('予定を入れる日付を教えてください。') unless date
      all_day = explicit_all_day_request?(text)
      timing = parse_local_schedule_timing(text, default_duration: nil)
      unless all_day
        unless explicit_time_present?(text) && timing[:start_minute]
          return clarification('開始時刻と、終了時刻または所要時間をまとめて教えてください。例：「9時から10時」「9時から1時間」')
        end
        unless timing[:duration_explicit] || timing[:end_time_explicit]
          end_minute = bare_end_minute(conversation)
          if end_minute
            duration = end_minute - timing[:start_minute]
            return clarification('終了時刻は開始時刻より後にしてください。終了時刻または所要時間をもう一度教えてください。') unless duration.positive?

            @user_message = text = "#{conversation.fetch(:original_text)}\n#{duration}分"
            timing = parse_local_schedule_timing(text, default_duration: nil)
          end
        end
        return clarification('終了時刻または所要時間を教えてください。例：「10時まで」「1時間」') unless timing[:duration_explicit] || timing[:end_time_explicit]
      end

      # The existing UI parser expects 「来客を追加」; preserve the same intent
      # when the Home phrasing is 「来客を予定に入れて」 so control text is not
      # copied into the event title. Date/time parsing and stored history stay intact.
      @user_message = text.gsub(/を予定に(?=入れ|追加|登録)/, 'を')
      response = call
      candidates = response[:recommendations] || response['recommendations'] || []
      return clarification((response[:assistant_message] || response['assistant_message']).to_s.presence || '予定名と日時をもう一度教えてください。') if candidates.empty?
      return rejected('複数件をまとめて登録できません。予定を1件ずつ指定してください。') unless candidates.one?
      candidate = candidates.first.deep_stringify_keys
      payload = candidate.fetch('payload', {})
      bundled = payload['events']
      return rejected('複数件をまとめて登録できません。予定を1件ずつ指定してください。') if bundled && (!bundled.is_a?(Array) || bundled.length != 1 || !bundled.first.is_a?(Hash))
      payload = payload.merge(bundled.first).except('events') if bundled
      unsupported = candidate['kind'] != 'draft_event' || payload['recurrence_kind'].present? ||
        payload['participant_names'].present? || payload['contact_name'].present? || payload['participant_ids'].present? || payload['group_id'].present?
      return rejected('単発の自分用予定だけを登録できます。共有・参加者・繰り返しを除いて指定してください。') if unsupported

      start_at = Time.iso8601(payload['start_at'] || candidate['start_at']).in_time_zone('Asia/Tokyo')
      end_at = Time.iso8601(payload['end_at'] || candidate['end_at']).in_time_zone('Asia/Tokyo')
      expected_start = all_day ? Time.find_zone!('Asia/Tokyo').local(date.year, date.month, date.day) : explicit_start_datetime_from_text(text)
      expected_end = all_day ? expected_start + 1.day : expected_start + timing[:duration_minutes].to_i.minutes
      future = all_day ? date >= context_now.in_time_zone('Asia/Tokyo').to_date : start_at > context_now
      unless start_at == expected_start && end_at == expected_end && end_at > start_at && future
        return clarification('指定した日時をそのまま確認できませんでした。未来の日付と開始・終了時刻を、予定名と一緒に指定してください。')
      end
      if conversation.fetch(:partial_follow_up)
        title_source = conversation.fetch(:title_source).gsub(/を予定に(?=入れ|追加|登録)/, 'を')
        source_descriptor = local_event_descriptor(title_source)
      end
      title = canonical_storage_text(source_descriptor ? source_descriptor[:title] : payload['title'] || candidate['title'])
      location = canonical_storage_text(source_descriptor ? source_descriptor[:location] : payload['location'])
      return clarification('予定名を確認できませんでした。保存する予定名を教えてください。') if title.blank?

      details = {
        'kind' => 'event', 'title' => title,
        'description' => payload['description'].to_s, 'location' => location,
        'start_at' => start_at.iso8601, 'end_at' => end_at.iso8601,
        'all_day' => all_day, 'time_zone' => 'Asia/Tokyo'
      }
      { status: 'ready', question: nil, details: details }
    rescue ArgumentError, TypeError, KeyError, EncodingError
      clarification('予定の内容を確認できませんでした。予定名と開始・終了日時をもう一度教えてください。')
    end

    private

    def compose_conversation(messages)
      original = messages.first.to_s
      latest = normalize_clock_separator(messages.last.to_s)
      full_restatement = messages.length > 1 && first_local_date_from_text(latest) &&
        (explicit_all_day_request?(latest) || explicit_time_present?(latest))

      if full_restatement
        {
          original_text: latest,
          interpretation_text: latest,
          title_source: latest,
          partial_follow_up: false,
          answer: nil
        }
      elsif messages.length > 1
        {
          original_text: original,
          interpretation_text: "#{original}\n#{latest}",
          title_source: original,
          partial_follow_up: true,
          answer: latest
        }
      else
        normalized = normalize_clock_separator(original)
        {
          original_text: normalized,
          interpretation_text: normalized,
          title_source: original,
          partial_follow_up: false,
          answer: nil
        }
      end
    end

    def normalize_clock_separator(text)
      normalize_japanese_preserve_case(text).gsub(/(?<=\d)[;；](?=\d{2}(?:\D|\z))/, ':')
    end

    def bare_end_minute(conversation)
      answer = conversation[:answer]
      return nil unless answer
      return nil unless explicit_time_present?(conversation.fetch(:original_text))
      return nil if ambiguous_datetime?(answer) || invalid_explicit_time_match(answer)

      clocks = explicit_time_matches(answer)
      return nil unless clocks.one?
      return nil unless temporal_end_answer?(answer)

      clocks.first.fetch(:hour) * 60 + clocks.first.fetch(:minute)
    end

    def temporal_end_answer?(answer)
      normalize_japanese(answer).match?(
        /\A\s*(?:終了(?:時刻)?(?:は|:|：)?\s*)?(?:\d{1,2}(?::\d{2}|時(?:\d{1,2}分)?))\s*(?:まで)?\s*\z/
      )
    end

    def canonical_storage_text(value)
      text = value.to_s
      raise EncodingError unless [Encoding::UTF_8, Encoding::US_ASCII].include?(text.encoding) && text.valid_encoding?

      text.encode(Encoding::UTF_8).gsub(/[\p{Cc}\p{Space}]+/u, ' ').strip
    end

    def ambiguous_datetime?(text)
      normalized = normalize_japanese(text)
      return true if normalized.match?(/または|もしくは|どちら|いずれか|\bor\b/)
      date_or_clock = /(?:今日|明日|明後日|あさって|再来週|来週|[月火水木金土日]曜(?:日)?|\d{1,2}日|\d{1,2}[\/-]\d{1,2}|\d{1,2}時(?:\d{1,2}分)?|\d{1,2}:\d{2})/
      return true if normalized.match?(/#{date_or_clock}\s*か(?!ら)/)
      # Date ranges require a richer interval clarification contract. Do not let
      # the existing parser select only the first day and truncate the request.
      normalized.match?(/(?:今日|明日|明後日|\d{1,2}日)\s*(?:から|〜|~).*?(?:明日|明後日|\d{1,2}日)\s*まで/)
    end

    def clarification(question)
      { status: 'needs_clarification', question: question.first(1000), details: nil }
    end

    def rejected(question)
      { status: 'rejected', question: question, details: nil }
    end
  end
end
