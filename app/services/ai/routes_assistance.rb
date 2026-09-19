# frozen_string_literal: true

module Ai
  # Deterministic, read-only route candidates. A failed route never reaches the
  # generic AI fallback, where a guessed journey duration could look authoritative.
  module RoutesAssistance
    ROUTES_API_PROVIDER = 'rails-local-routes-api-v1'
    ROUTES_MODE_PATTERNS = {
      'TRANSIT' => /(?:電車|鉄道|公共交通|バス|新幹線)(?:で)?/,
      'DRIVE' => /(?:自動車|(?<!電)(?<!転)(?<!列)車|タクシー|運転)(?:で)?/,
      'WALK' => /(?:徒歩(?:で)?|歩いて)/
    }.freeze
    ROUTES_PLACE_PATTERN = /[\p{Han}\p{Hiragana}\p{Katakana}a-zA-Z0-9_\-・ー ]{1,80}?/

    private

    def local_routes_api_response(text)
      return nil unless routes_api_request?(text)
      # Existing explicit-duration and memory paths retain their established rules.
      return nil if extract_travel_route(text)[:travel_minutes].to_i.positive?

      source = normalize_japanese_preserve_case(normalize_schedule_language(@user_message))
      @routes_api_place_bindings = []
      if source.match?(/経由|立ち寄|途中|往復|帰り|その後|それから/) || remove_explicit_clock_phrases(source).scan(/から/).length > 1
        return routes_api_clarification('複数区間の移動は、区間ごとの出発地・目的地・交通手段・出発日時と、立ち寄り先の滞在時間を指定してください。全区間を確認できるまで候補は作成しません。')
      end
      if source.match?(/自転車|バイク|飛行機|船/) || routes_api_modes(source).length != 1
        return routes_api_clarification('交通手段を1つ指定してください。電車・バス・公共交通・車・徒歩の経路に対応しています。交通手段は推測しません。')
      end
      if source.include?('新幹線') || (source.match?(/電車|鉄道/) && source.include?('バス'))
        return routes_api_clarification('新幹線の限定指定や電車・バスを組み合わせた経路には対応していません。電車、バス、または手段を限定しない公共交通のいずれかで指定してください。')
      end

      origin, destination, route_text = routes_api_places(source)
      unless origin.present? && destination.present?
        return routes_api_clarification('出発地と目的地を指定してください。例:「明日10時に東京駅から大阪駅まで電車で移動」。現在地や自宅の住所は推測しません。')
      end
      appointment_place = extract_local_location(source)
      if appointment_place.present? && normalize_japanese(appointment_place) != normalize_japanese(destination)
        return routes_api_clarification('移動先と本予定の場所が異なります。各区間の出発地・目的地と予定時刻を指定してください。途中の移動を省略した候補は作成しません。')
      end
      resolved_origin = routes_api_resolve_place(origin)
      resolved_destination = routes_api_resolve_place(destination)
      unless resolved_origin && resolved_destination
        return routes_api_clarification('自宅・勤務先などの住所を保存するか、出発地と目的地を駅名・住所で指定してください。同じ名前の場所が複数ある場合も住所で指定してください。')
      end

      date = first_local_date_from_text(source)
      timing = parse_local_schedule_timing(routes_api_without_arrival_buffer(source), default_duration: 60)
      unless date && timing[:start_minute]
        return routes_api_clarification('経路を調べる日付と出発時刻を指定してください。固定予定に合わせる場合は、その予定の日付・開始時刻も必要です。')
      end
      if explicit_time_matches(source).length > 1 && explicit_time_range_matches(source).empty?
        return routes_api_clarification('複数の時刻があるため、どの時刻に出発するか、または何時の予定に到着したいかを1つずつ指定してください。')
      end
      requested_time = local_time_at_minute(date, timing[:start_minute])
      return routes_api_clarification('経路を調べる日時を確認してください。') unless requested_time
      return routes_api_clarification('指定日時が過去になります。未来の出発日時または予定日時を指定してください。') if requested_time < context_now

      main_source = routes_api_main_source(source, route_text, origin, destination)
      has_main_event = known_activity_title?(remove_date_time_phrases(main_source))
      if !has_main_event && main_source.gsub(/(?:候補|予定)(?:を)?(?:ください|下さい|お願い|作って|作成して|提案して)?|お願いします|ください|下さい|[\s、。，,.]/, '').present?
        return routes_api_clarification('移動だけの候補か、到着後の予定も含めるかを確認してください。到着後の予定がある場合は、予定名と開始・終了時刻を指定してください。')
      end
      if !has_main_event && timing[:end_minute]
        return routes_api_clarification('移動の終了時刻は経路APIの結果で決まります。出発日時、または到着希望日時のどちらか1つを指定してください。')
      end
      if main_source.match?(/(?:ランチ|昼食|食事)/) && main_source.match?(/会議|打ち合わせ|打合せ|面談|通院|病院/)
        return routes_api_clarification('食事と本予定を含む移動は、各目的地・滞在時間・交通手段を指定してください。途中の予定を省略した候補は作成しません。')
      end

      mode = routes_api_modes(source).first
      arrival_request = has_main_event || source.match?(/到着|着きたい|着く/)
      if arrival_request && mode != 'TRANSIT'
        return routes_api_clarification('車・徒歩の経路は出発日時を指定してください。到着指定で逆算できる交通手段は公共交通です。移動時間が分かる場合は「移動時間30分」のようにも指定できます。')
      end
      explicit_buffer = extract_arrival_buffer_minutes(source)
      return routes_api_clarification('到着前の余裕は0〜180分で指定してください。') unless explicit_buffer
      buffer_context = routes_api_buffer_context(main_source, origin, destination, source, mode, explicit_buffer, has_main_event)
      buffer = routes_api_effective_buffer(buffer_context)
      return routes_api_clarification('到着前の余裕は0〜180分で指定してください。') unless buffer
      target_time = has_main_event ? requested_time - buffer.minutes : requested_time

      main_event = routes_api_main_event(main_source, destination, date, timing, buffer) if has_main_event
      if has_main_event && !main_event
        return routes_api_clarification('本予定の名前と開始・終了時刻を確認してください。')
      end
      if main_event && routes_api_event_conflicts?(main_event)
        return routes_api_clarification('本予定が既存予定と重なります。予定時刻を調整してください。')
      end

      route_request = {
        origin: resolved_origin, destination: resolved_destination, mode: mode,
        transit_mode: mode == 'TRANSIT' ? routes_api_transit_mode(source) : nil,
        departure_time: arrival_request ? nil : target_time,
        arrival_time: arrival_request ? target_time : nil
      }.compact
      result = (@routes_provider || TravelRouting::GoogleRoutesProvider.new).call(**route_request)
      unless result.success?
        return routes_api_clarification('経路情報を取得できませんでした。時間をおいて再試行するか、移動時間を指定してください。推測した移動予定は作成していません。', code: result.code)
      end
      departure = parse_context_time(result.departure_time)
      arrival = parse_context_time(result.arrival_time)
      valid = departure && arrival && arrival > departure && result.duration_seconds.to_i.positive?
      valid &&= ((arrival - departure) - result.duration_seconds.to_f).abs <= 1
      valid &&= arrival_request ? arrival <= target_time : departure >= target_time
      unless valid
        return routes_api_clarification('指定日時に合う経路を確認できませんでした。出発日時または交通手段を変更してください。', code: 'invalid_response')
      end
      return routes_api_clarification('経路の出発時刻が過去になります。予定日時を変更してください。') if departure < context_now
      # Include waiting until the fixed appointment: another event in that gap
      # would make the combined journey + appointment candidate infeasible.
      conflict_end = main_event ? parse_context_time(main_event['end_at']) : arrival
      if conflicting_events(context_value(:personal_events), departure, conflict_end).any?
        return routes_api_clarification('移動時間または到着後の待ち時間が既存予定と重なります。出発日時・予定日時を調整してください。')
      end

      travel = routes_api_travel_event(origin, destination, departure, arrival, result, mode, buffer)
      reason = 'Google Mapsの経路情報から移動候補を作成しました。交通状況や運行状況により変わるため、出発前に再確認してください。'
      message = "#{origin}から#{destination}へ、#{departure.strftime('%-m/%-d %H:%M')}出発・#{arrival.strftime('%-m/%-d %H:%M')}到着の候補です。#{reason}"
      response = if main_event
                   build_local_bundle_response(
                     title: "移動込み: #{main_event['title']}", assistant_message: message,
                     reason: reason, events: [travel, main_event], provider: ROUTES_API_PROVIDER
                   )
                 else
                   build_local_candidates_response(
                     assistant_message: message, reason: reason, events: [travel], provider: ROUTES_API_PROVIDER
                   )
                 end
      response[:tool_invocations] = [routes_api_invocation('ok', mode)]
      response[:routes_provenance] = TravelRouting::RecommendationGuard::LOCAL_PROVENANCE
      response[:recommendations].first['payload']['events'] ||= [travel.deep_dup]
      response[:recommendations].first['payload']['route_attribution'] = 'Google Maps'
      response[:recommendations].first['payload']['routing'] = {
        'source' => 'google_routes',
        'request' => route_request.transform_keys(&:to_s).transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : value },
        'result' => %i[duration_seconds distance_meters walking_seconds departure_time arrival_time].to_h { |key| [key.to_s, result.public_send(key)] },
        'checked_at' => context_now.iso8601, 'expires_at' => (context_now + 15.minutes).iso8601,
        'arrival_buffer_minutes' => buffer, 'place_bindings' => @routes_api_place_bindings,
        'buffer_context' => buffer_context
      }
      response
    rescue StandardError
      # Do not leak transport exceptions, saved addresses, API keys or upstream
      # response bodies into the UI, logs or an LLM request.
      routes_api_clarification('経路情報を取得できませんでした。時間をおいて再試行するか、移動時間を指定してください。推測した移動予定は作成していません。', code: 'unavailable')
    end

    def routes_api_request?(text)
      return false if text.match?(/変更|ずらして|リスケ|延期|前倒し|削除|消して|キャンセル|取り消し|通知|リマインダー/)
      return false if recurrence_request?(text) || explicit_all_day_request?(text)
      return false if schedule_summary_request?(text) || schedule_organization_request?(text)
      movement = text.match?(/移動|経路|出発|到着|着きたい|着く/)
      route_context = text.include?('から') || routes_api_modes(text).any? || text.match?(/経路|移動時間|移動も/)
      (movement && route_context) || (text.include?('から') && routes_api_modes(text).any?)
    end

    def routes_api_modes(text)
      ROUTES_MODE_PATTERNS.filter_map { |mode, pattern| mode if text.match?(pattern) }
    end

    def routes_api_transit_mode(text)
      return 'RAIL' if text.match?(/電車|鉄道/)
      return 'BUS' if text.include?('バス')

      nil
    end

    def routes_api_places(source)
      without_time = remove_date_time_phrases(source)
      match = without_time.match(/(?<origin>#{ROUTES_PLACE_PATTERN})から(?<destination>#{ROUTES_PLACE_PATTERN})(?:まで|へ|に)(?=電車|鉄道|公共交通|バス|新幹線|自動車|車|タクシー|運転|徒歩|歩いて|移動|出発|到着|着|[、。，,.\s]|$)/)
      if match
        return [clean_travel_place(match[:origin]), clean_travel_place(match[:destination]), match[0]]
      end
      # A destination may be attached to the fixed appointment instead of the
      # route: "東京駅から電車で移動、明日15時に大阪駅で会議".
      origin_match = without_time.match(/(?<origin>#{ROUTES_PLACE_PATTERN})から(?=電車|鉄道|公共交通|バス|新幹線|車|自動車|徒歩|歩いて)/)
      [origin_match && clean_travel_place(origin_match[:origin]), extract_local_location(source), origin_match && origin_match[0]]
    end

    def routes_api_resolve_place(label)
      normalized = normalize_japanese(label)
      return nil if normalized.match?(/\A(?:現在地|ここ|そこ|あそこ|近く|いつもの場所)\z/)
      matches = Array(context_value(:user_places)).filter_map do |place|
        attrs = place.respond_to?(:to_h) ? place.to_h.symbolize_keys : {}
        next unless [attrs[:label], attrs[:place_name]].compact.any? { |name| normalize_japanese(name) == normalized }
        attrs
      end
      return nil if matches.length > 1
      if matches.one?
        @routes_api_place_bindings << matches.first.slice(:id, :place_name, :address_text, :label, :kind).stringify_keys
        return matches.first[:address_text].presence || matches.first[:place_name].presence
      end
      return nil if normalized.match?(/\A(?:自宅|家|勤務先|職場|会社|学校)\z/)

      label
    end

    def routes_api_main_source(source, route_text, origin, destination)
      value = remove_date_time_phrases(routes_api_without_arrival_buffer(source))
      value = value.sub(route_text, '') if route_text.present?
      value = remove_travel_assist_phrases(value, destination: destination, origin: origin)
      ROUTES_MODE_PATTERNS.each_value { |pattern| value = value.gsub(pattern, '') }
      value.gsub(/(?:移動時間|移動|経路)(?:も|を)?(?:調べて|教えて|入れて|含めて|考慮して|お願い|したい|する)?(?:ください)?/, '')
        .gsub(/(?:出発|到着|着きたい|着く)(?:したい|する)?/, '')
        .gsub(/[、。]/, ' ').strip
    end

    def routes_api_without_arrival_buffer(source)
      source.gsub(/\d{1,3}\s*分前(?:に)?(?:到着|着きたい|着く)/, '')
        .gsub(/到着(?:バッファ|余裕)?\s*\d{1,3}\s*分/, '')
    end

    def routes_api_buffer_context(main_source, origin, destination, source, mode, explicit_buffer, has_main_event)
      title = local_event_descriptor(main_source)[:activity_title]
      keys = has_main_event ? ["arrival_buffer.#{arrival_buffer_preference_key_for_label(title)}", 'arrival_buffer.default'].uniq : []
      saved_mode = case mode
                   when 'TRANSIT' then { 'RAIL' => 'train', 'BUS' => 'bus' }.fetch(routes_api_transit_mode(source), 'public_transport')
                   when 'DRIVE' then 'car'
                   when 'WALK' then 'walk'
                   end
      {
        'preference_keys' => keys, 'origin_name' => origin, 'destination_name' => destination,
        'transport_modes' => has_main_event ? [saved_mode] : [], 'explicit_minutes' => explicit_buffer
      }
    end

    def routes_api_effective_buffer(binding)
      values = [binding.fetch('explicit_minutes')]
      Array(context_value(:ai_user_preferences)).each do |preference|
        attrs = preference.respond_to?(:to_h) ? preference.to_h.symbolize_keys : {}
        values << attrs[:value] if binding.fetch('preference_keys').include?(attrs[:key].to_s)
      end
      Array(context_value(:user_travel_routes)).each do |route|
        attrs = route.respond_to?(:to_h) ? route.to_h.symbolize_keys : {}
        next unless normalize_place_name(attrs[:origin_name]) == normalize_place_name(binding.fetch('origin_name'))
        next unless normalize_place_name(attrs[:destination_name]) == normalize_place_name(binding.fetch('destination_name'))
        next unless binding.fetch('transport_modes').include?(attrs[:transport_mode].to_s)
        values << attrs[:arrival_buffer_minutes] unless attrs[:arrival_buffer_minutes].nil?
      end
      return nil unless values.all? { |value| value.to_s.match?(/\A\d+\z/) && value.to_i.between?(0, 180) }

      values.map(&:to_i).max
    end

    def routes_api_main_event(source, destination, date, timing, buffer)
      descriptor = local_event_descriptor(source)
      title = descriptor[:title]
      return nil if insufficient_activity_title?(title) || title == '予定'
      start_at = local_time_at_minute(date, timing[:start_minute])
      end_at = if timing[:end_minute]
                 local_time_at_minute(date, timing[:end_minute])
               else
                 start_at + timing[:duration_minutes].to_i.minutes
               end
      return nil unless start_at && end_at && end_at > start_at

      local_event_hash(title: title, start_at: start_at, end_at: end_at, all_day: false,
                       color: color_for_local_title(title), category: category_for_local_title(title),
                       intent: intent_for_local_title(title), schedule_profile: profile_for_local_title(title),
                       reason: '指定された日時・目的地の予定候補です。',
                       contact_name: descriptor[:contact_name], participant_names: descriptor[:participant_names],
                       location: destination, buffer_minutes: buffer)
    end

    def routes_api_event_conflicts?(event)
      conflicting_events(context_value(:personal_events), parse_context_time(event['start_at']), parse_context_time(event['end_at'])).any?
    end

    def routes_api_travel_event(origin, destination, departure, arrival, result, mode, buffer)
      event = local_event_hash(title: "移動: #{origin} → #{destination}", start_at: departure,
                               end_at: arrival, all_day: false, color: '#06b6d4', category: 'travel',
                               intent: 'travel', schedule_profile: 'travel',
                               reason: 'Google Mapsの経路情報に基づく移動候補です。', location: destination)
      event['description'] = "#{travel_label(origin: origin, destination: destination)} / Google Maps"
      event['travel_assist'] = {
        'origin' => origin, 'destination' => destination, 'source' => 'google_routes',
        'transport_mode' => mode, 'duration_seconds' => result.duration_seconds,
        'travel_minutes' => ((arrival - departure) / 60).ceil,
        'distance_meters' => result.distance_meters, 'walking_seconds' => result.walking_seconds,
        'arrival_buffer_minutes' => buffer, 'attribution' => 'Google Maps'
      }
      event
    end

    def routes_api_clarification(message, code: nil)
      {
        assistant_message: message, recommendations: [], provider: ROUTES_API_PROVIDER,
        policy_run: local_policy_run(ROUTES_API_PROVIDER),
        tool_invocations: code ? [routes_api_invocation(code)] : []
      }
    end

    def routes_api_invocation(code, mode = nil)
      { tool_name: 'google_routes.compute_routes', status: code.to_s == 'ok' ? 'success' : 'failed',
        position: 1, input_payload: { mode: mode }.compact,
        output_payload: { code: code.to_s }, metadata: { read_only: true } }
    end
  end
end
