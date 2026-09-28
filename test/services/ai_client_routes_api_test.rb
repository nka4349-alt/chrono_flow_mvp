# frozen_string_literal: true

require 'test_helper'

class AiClientRoutesApiTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home', timezone: 'Asia/Tokyo', now: '2026-05-18T08:00:00+09:00',
    personal_events: [], peer_events: [], contacts: [], friends: [], user_places: []
  }.freeze
  Result = Struct.new(:code, :duration_seconds, :distance_meters, :walking_seconds,
                      :departure_time, :arrival_time, :attribution, keyword_init: true) do
    def success?
      code == 'ok'
    end
  end

  PRODUCTION_WRAPPER_INTENT_CASES = [
    {
      id: 'P-WALK-W1',
      input: '予定を整理したいので相談です。2026年9月25日の10時に東京駅から有楽町駅まで徒歩で移動。経路を確認して候補を出してください。',
      mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-25T10:00:00+09:00'
    },
    {
      id: 'P-WALK-W2',
      input: "カレンダーの移動予定を確認しています。\n2026年9月25日の10時に東京駅から有楽町駅まで徒歩で移動。\nまずは予定候補だけ作って、まだ保存しないでください。",
      mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-25T10:00:00+09:00'
    },
    {
      id: 'P-WALK-W3',
      input: "2026年9月25日の移動について確認をお願いします。\n2026年9月25日の10時に東京駅から有楽町駅まで徒歩で移動\n既存予定と重ならないかも確認してください。",
      mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-25T10:00:00+09:00'
    },
    {
      id: 'P-WALK-COMPACT',
      input: '2026年9月25日10時に東京駅から有楽町駅まで徒歩で移動したいので候補をお願いします',
      mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-25T10:00:00+09:00'
    },
    {
      id: 'P-DRIVE-W1',
      input: '予定を整理したいので相談です。2026年9月26日の13時に東京駅から有楽町駅まで車で移動。経路を確認して候補を出してください。',
      mode: 'DRIVE', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-26T13:00:00+09:00'
    },
    {
      id: 'P-DRIVE-W2',
      input: "カレンダーの移動予定を確認しています。\n2026年9月26日の13時に東京駅から有楽町駅まで車で移動。\nまずは予定候補だけ作って、まだ保存しないでください。",
      mode: 'DRIVE', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-26T13:00:00+09:00'
    },
    {
      id: 'P-DRIVE-W3',
      input: "2026年9月26日の移動について確認をお願いします。\n2026年9月26日の13時に東京駅から有楽町駅まで車で移動\n既存予定と重ならないかも確認してください。",
      mode: 'DRIVE', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-26T13:00:00+09:00'
    },
    {
      id: 'P-DRIVE-COMPACT',
      input: '2026年9月26日13時に東京駅から有楽町駅まで車で移動したいので候補をお願いします',
      mode: 'DRIVE', origin: '東京駅', destination: '有楽町駅', departure_time: '2026-09-26T13:00:00+09:00'
    },
    {
      id: 'P-TRANSIT-W0',
      input: '2026年9月27日の10時に東京駅から上野駅まで公共交通機関で移動',
      mode: 'TRANSIT', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
    },
    {
      id: 'P-TRANSIT-COMPACT',
      input: '2026年9月27日10時に東京駅から上野駅まで公共交通機関で移動したいので候補をお願いします',
      mode: 'TRANSIT', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
    }
  ].freeze

  CONDITIONAL_TRANSIT_WRAPPER_CASES = [
    {
      id: 'P-TRANSIT-W1',
      input: '予定を整理したいので相談です。2026年9月27日の10時に東京駅から上野駅まで公共交通機関で移動。経路を確認して候補を出してください。',
      mode: 'TRANSIT', transit_mode: nil, origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
    },
    {
      id: 'P-TRANSIT-W2',
      input: "カレンダーの移動予定を確認しています。\n2026年9月27日の10時に東京駅から上野駅まで公共交通機関で移動。\nまずは予定候補だけ作って、まだ保存しないでください。",
      mode: 'TRANSIT', transit_mode: nil, origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
    },
    {
      id: 'P-TRANSIT-W3',
      input: "2026年9月27日の移動について確認をお願いします。\n2026年9月27日の10時に東京駅から上野駅まで公共交通機関で移動\n既存予定と重ならないかも確認してください。",
      mode: 'TRANSIT', transit_mode: nil, origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
    },
    {
      id: 'P-RAIL-W1',
      input: '予定を整理したいので相談です。2026年9月27日の13時に東京駅から上野駅まで電車で移動。経路を確認して候補を出してください。',
      mode: 'TRANSIT', transit_mode: 'RAIL', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T13:00:00+09:00'
    },
    {
      id: 'P-RAIL-W2',
      input: "カレンダーの移動予定を確認しています。\n2026年9月27日の13時に東京駅から上野駅まで電車で移動。\nまずは予定候補だけ作って、まだ保存しないでください。",
      mode: 'TRANSIT', transit_mode: 'RAIL', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T13:00:00+09:00'
    },
    {
      id: 'P-RAIL-W3',
      input: "2026年9月27日の移動について確認をお願いします。\n2026年9月27日の13時に東京駅から上野駅まで電車で移動\n既存予定と重ならないかも確認してください。",
      mode: 'TRANSIT', transit_mode: 'RAIL', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T13:00:00+09:00'
    }
  ].freeze
  ROUTE_PROPOSAL_WRITE_PATTERN = /\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"?(?:events|event_participants|event_reminders|notifications|ai_recommendation_feedbacks)\b/i

  class Provider
    attr_reader :calls

    def initialize(&block)
      @calls = []
      @block = block
    end

    def call(**request)
      @calls << request
      return @block.call(request) if @block

      departure = request[:departure_time] || request.fetch(:arrival_time) - 30.minutes
      arrival = request[:arrival_time] || departure + 30.minutes
      Result.new(code: 'ok', duration_seconds: 1800, distance_meters: 10_000,
                 walking_seconds: 300, departure_time: departure.iso8601,
                 arrival_time: arrival.iso8601, attribution: 'Google Maps')
    end
  end

  def response(message, context: {}, provider: Provider.new)
    @provider = provider
    requested_times = @requested_times = []
    client = Ai::Client.new(context: BASE_CONTEXT.merge(context), user_message: message, routes_provider: provider)
    client.define_singleton_method(:local_time_at_minute) do |date, minute|
      super(date, minute).tap { |value| requested_times << value }
    end
    client.define_singleton_method(:request_remote) { raise Exception, 'Routes test reached generic AI fallback' }
    writes = []
    observer = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      writes << sql if sql.match?(ROUTE_PROPOSAL_WRITE_PATTERN)
    end
    result = ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') do
      client.call
    end
    assert_empty writes, writes.join("\n")
    result
  end

  def candidate(result)
    assert_equal 'rails-local-routes-api-v1', result.fetch(:provider)
    assert_equal 1, result.fetch(:recommendations).size
    result.fetch(:recommendations).first.fetch('payload')
  end

  def assert_clarifies(result, text)
    assert_equal 'rails-local-routes-api-v1', result.fetch(:provider)
    assert_empty result.fetch(:recommendations)
    assert_includes result.fetch(:assistant_message), text
  end

  def assert_departure_route_case(test_case, result = nil)
    case_id = test_case.fetch(:id)
    result ||= response(test_case.fetch(:input), context: { now: test_case.fetch(:now, '2026-09-23T13:15:00+09:00') })
    assert_equal 'rails-local-routes-api-v1', result[:provider], case_id
    assert_equal 1, Array(result[:recommendations]).length, case_id
    assert_equal 1, @provider.calls.length, case_id

    request = @provider.calls.first || {}
    assert_equal test_case.fetch(:mode), request[:mode], case_id
    assert_equal test_case.fetch(:origin), request[:origin], case_id
    assert_equal test_case.fetch(:destination), request[:destination], case_id
    assert_equal test_case.fetch(:departure_time), request[:departure_time]&.iso8601, case_id
    refute request.key?(:arrival_time), case_id
    if test_case[:transit_mode]
      assert_equal test_case[:transit_mode], request[:transit_mode], case_id
    else
      refute request.key?(:transit_mode), case_id
    end

    payload = result.fetch(:recommendations).first.fetch('payload')
    assert_equal 1, payload.fetch('events').length, case_id
    assert_equal 'Google Maps', payload.fetch('route_attribution'), case_id
    event = payload.fetch('events').first
    expected_title = "移動: #{test_case.fetch(:origin)} → #{test_case.fetch(:destination)}"
    assert_equal expected_title, result.fetch(:recommendations).first.fetch('title'), case_id
    assert_equal expected_title, event.fetch('title'), case_id
    assert_equal test_case.fetch(:departure_time), event.fetch('start_at'), case_id
    assert_equal (Time.iso8601(test_case.fetch(:departure_time)) + 30.minutes).iso8601, event.fetch('end_at'), case_id
    assert_equal test_case.fetch(:destination), event.fetch('location'), case_id
    assert_equal 1800, event.fetch('travel_assist').fetch('duration_seconds'), case_id
    assert_equal 1, result.fetch(:tool_invocations).length, case_id
    invocation = result.fetch(:tool_invocations).first
    assert_equal 'google_routes.compute_routes', invocation.fetch(:tool_name), case_id
    assert_equal 'success', invocation.fetch(:status), case_id
    assert_equal true, invocation.fetch(:metadata).fetch(:read_only), case_id
    result
  end

  test 'production wrapper and intent cases remain departure only route requests' do
    writes = []
    observer = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      writes << sql if sql.match?(ROUTE_PROPOSAL_WRITE_PATTERN)
    end

    ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') do
      assert_no_difference 'Event.count' do
        PRODUCTION_WRAPPER_INTENT_CASES.each do |test_case|
          assert_departure_route_case(test_case)
        end
      end
    end

    assert_empty writes, writes.join("\n")
  end

  test 'conditional transit wrapper cases keep parser departure semantics' do
    CONDITIONAL_TRANSIT_WRAPPER_CASES.each { |test_case| assert_departure_route_case(test_case) }
  end


  test 'internal route diagnostic never enters public or model visible payloads' do
    real_provider = TravelRouting::GoogleRoutesProvider
    %w[fallback_present geocoding_missing transit_vehicle_unknown].each do |reason|
      value = real_provider::Result.new(code: 'invalid_response', diagnostic_reason: reason)
      result = response(CONDITIONAL_TRANSIT_WRAPPER_CASES.last.fetch(:input),
                        context: { now: '2026-09-23T13:15:00+09:00' }, provider: Provider.new { value })
      assert_clarifies result, '経路情報を取得できませんでした'
      assert_equal 1, @provider.calls.length
      assert_equal({ code: 'invalid_response' }, result.fetch(:tool_invocations).first.fetch(:output_payload))
      refute_includes result.to_json, reason
      refute_includes result.to_json, 'diagnostic'
    end
    value = real_provider::Result.new(code: 'ok', diagnostic_reason: 'ok', duration_seconds: 1800,
      distance_meters: 6000, walking_seconds: 0, departure_time: '2026-09-27T01:00:00Z',
      arrival_time: '2026-09-27T01:30:00Z', attribution: 'Google Maps')
    result = response(CONDITIONAL_TRANSIT_WRAPPER_CASES.first.fetch(:input),
                      context: { now: '2026-09-23T13:15:00+09:00' }, provider: Provider.new { value })
    assert_equal 1, result.fetch(:recommendations).length
    refute_includes result.to_json, 'diagnostic'
    assert_equal({ code: 'ok' }, result.fetch(:tool_invocations).first.fetch(:output_payload))
  end

  test 'synthetic wrapper variants cover honorific punctuation and rail compact input' do
    cases = [
      {
        id: 'SYN-GENERIC-TRANSIT-HONORIFIC',
        input: '恐れ入りますが、予定を整理したいので相談です。2026年9月27日10時に東京駅から上野駅まで公共交通機関で移動。候補をお願いいたします。',
        mode: 'TRANSIT', transit_mode: nil, origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
      },
      {
        id: 'SYN-RAIL-SAVE-FORBIDDEN-PUNCTUATION',
        input: "お手数ですが、カレンダーの移動予定を確認しています！\n2026年9月27日 13時に東京駅から上野駅まで電車で移動！\nまずは予定候補だけを作って、まだ保存しないで下さい。",
        mode: 'TRANSIT', transit_mode: 'RAIL', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T13:00:00+09:00'
      },
      {
        id: 'SYN-RAIL-COMPACT',
        input: '2026年9月27日13時に東京駅から上野駅まで電車で移動したいので候補をお願いします',
        mode: 'TRANSIT', transit_mode: 'RAIL', origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T13:00:00+09:00'
      },
      {
        id: 'SYN-UNRELATED-COURTESY-CLAUSES',
        input: "恐れ入りますが。\n2026年9月27日10時に東京駅から上野駅まで公共交通機関で移動。\nよろしくお願いいたします。",
        mode: 'TRANSIT', transit_mode: nil, origin: '東京駅', destination: '上野駅', departure_time: '2026-09-27T10:00:00+09:00'
      },
      {
        id: 'SYN-PLACE-NAME-WITH-SCHEDULE-WORD',
        input: '2026年9月27日13時に東京駅から予定会館まで電車で移動',
        mode: 'TRANSIT', transit_mode: 'RAIL', origin: '東京駅', destination: '予定会館', departure_time: '2026-09-27T13:00:00+09:00'
      }
    ]
    cases.each { |test_case| assert_departure_route_case(test_case) }
  end

  test 'wrapper and mode words inside real appointment titles are preserved' do
    {
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に「公共交通確認会議」' => '「公共交通確認会議」',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に「予定を整理したいので相談です。経路を確認して候補を出してください」' => '「予定を整理したいので相談です。経路を確認して候補を出してください」',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に「バス事業会議」' => '「バス事業会議」',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に「新幹線プロジェクト会議」' => '「新幹線プロジェクト会議」',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に（バイク事業会議）' => '(バイク事業会議)',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に車レビュー確認会議' => '車レビュー確認会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に船レビュー会議' => '船レビュー会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に候補レビュー会議' => '候補レビュー会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に予定施設レビュー会議' => '予定施設レビュー会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に保存確認会議' => '保存確認会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時にCF.APIレビュー会議' => 'CF.APIレビュー会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に第2候補確認会議' => '第2候補確認会議',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に（保存API確認会議）' => '(保存API確認会議)',
      '東京駅から大阪駅まで電車で移動、2026年9月27日の15時に「その後の確認会議」' => '「その後の確認会議」'
    }.each do |input, expected_title|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_equal 1, Array(result[:recommendations]).length, input
      payload = candidate(result)
      assert_equal 2, payload.fetch('events').length
      assert_equal expected_title, payload.fetch('events').last.fetch('title')
      assert_equal 'TRANSIT', @provider.calls.first.fetch(:mode)
      assert_equal 'RAIL', @provider.calls.first.fetch(:transit_mode)
      assert @provider.calls.first.key?(:arrival_time)
      refute @provider.calls.first.key?(:departure_time)
    end
  end

  test 'a real consultation after a wrapper remains an arrival appointment' do
    input = '予定を整理したいので相談です。東京駅から大阪駅まで電車で移動。2026年9月27日の15時に相談です。15分前に到着してください。'
    payload = candidate(response(input, context: { now: '2026-09-23T13:15:00+09:00' }))
    travel, appointment = payload.fetch('events')
    assert_equal 2, payload.fetch('events').length
    assert_equal '相談です', appointment.fetch('title')
    assert_equal '2026-09-27T15:00:00+09:00', appointment.fetch('start_at')
    assert_equal '2026-09-27T16:00:00+09:00', appointment.fetch('end_at')
    assert_equal '2026-09-27T14:15:00+09:00', travel.fetch('start_at')
    assert_equal '2026-09-27T14:45:00+09:00', travel.fetch('end_at')
    assert_equal Time.iso8601('2026-09-27T14:45:00+09:00'), @provider.calls.first.fetch(:arrival_time)
    refute @provider.calls.first.key?(:departure_time)
  end

  test 'mode wording with de no remains a supported route phrase' do
    payload = candidate(response('東京駅から大阪駅まで電車での移動、2026年9月27日の15時に会議',
                                 context: { now: '2026-09-23T13:15:00+09:00' }))
    assert_equal 2, payload.fetch('events').length
    assert_equal 'TRANSIT', @provider.calls.first.fetch(:mode)
    assert_equal 'RAIL', @provider.calls.first.fetch(:transit_mode)
  end

  test 'approved negative controls remain fail closed before provider dispatch' do
    {
      '2026年9月29日の10時に東京駅から有楽町駅まで徒歩か車で移動' => '交通手段を1つ',
      '東京駅から大阪駅まで電車か車を使って移動、2026年9月27日の15時に会議' => '交通手段を1つ',
      '東京駅から大阪駅まで電車と新幹線を使って移動、2026年9月27日の15時に会議' => '対応していません',
      '明日、東京駅から有楽町駅まで車で移動' => '出発時刻',
      '2026年9月29日の16時に東京駅から有楽町駅へ徒歩で行って、その後上野駅へ電車で移動' => '複数区間'
    }.each do |input, message|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_clarifies result, message
      assert_empty @provider.calls
    end
  end

  test 'production N-006 explicit duration is one departure travel event' do
    input = '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分'
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
    assert_empty @provider.calls
    assert_equal 1, result.fetch(:recommendations).length, result[:assistant_message]
    payload = result.fetch(:recommendations).first.fetch('payload')
    events = payload.fetch('events', [payload])
    assert_equal 1, events.length
    event = events.first
    assert_equal '移動: 東京駅 → 有楽町駅', event.fetch('title')
    assert_equal '2026-09-30T10:00:00+09:00', event.fetch('start_at')
    assert_equal '2026-09-30T10:20:00+09:00', event.fetch('end_at')
    assert_equal 'travel', event.fetch('intent')
    assert_equal '有楽町駅', event.fetch('location')
    assert_equal '東京駅', event.fetch('travel_assist').fetch('origin')
    assert_equal '有楽町駅', event.fetch('travel_assist').fetch('destination')
    assert_equal 'WALK', event.fetch('travel_assist').fetch('transport_mode')
    assert_equal 20, event.fetch('travel_assist').fetch('travel_minutes')
    assert_empty result.fetch(:tool_invocations)
    refute_includes result.to_json, 'Google Maps'
    refute payload.key?('route_attribution')
    refute event.fetch('travel_assist').key?('routing')
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)
    assert_equal 20, client.send(:extract_travel_route, input)[:travel_minutes]
  end

  def assert_explicit_departure(input, minutes: 20, mode: 'WALK', start_at: '2026-09-30T10:00:00+09:00', context: {})
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' }.merge(context))
    assert_empty @provider.calls, input
    assert_equal 1, result.fetch(:recommendations).length, "#{input}: #{result[:assistant_message]}"
    payload = result.fetch(:recommendations).first.fetch('payload')
    events = payload.fetch('events', [payload])
    assert_equal 1, events.length, input
    event = events.first
    assert_equal '移動: 東京駅 → 有楽町駅', event.fetch('title'), input
    assert_equal start_at, event.fetch('start_at'), input
    assert_equal (Time.iso8601(start_at) + minutes.minutes).iso8601, event.fetch('end_at'), input
    assert_equal minutes, event.fetch('travel_assist').fetch('travel_minutes'), input
    assert_equal mode, event.fetch('travel_assist')['transport_mode'], input if mode
    assert_empty result.fetch(:tool_invocations), input
    refute_includes result.to_json, 'Google Maps', input
    refute payload.key?('route_attribution'), input
  end

  test 'explicit duration preserves forms bounds spaces and cumulative date wrappers' do
    [
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、移動時間20分',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で20分移動',
      "2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、\n所要時間 は 20 分",
      '２０２６年９月３０日の１０時に東京駅から有楽町駅まで徒歩で移動、所要時間は２０分',
      "今日はカレンダーの整理をしています。天気の話ではありません。\n2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分。\n移動予定だけを候補にしてください。"
    ].each { |input| assert_explicit_departure(input) }
    assert_explicit_departure('2026年9月30日の10時に東京駅から有楽町駅まで所要時間は20分', mode: nil)
    [5, 240].each do |minutes|
      assert_explicit_departure("2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は#{minutes}分", minutes: minutes)
    end
    assert_explicit_departure('2026年9月30日の23時に東京駅から有楽町駅まで車で移動、所要時間は120分',
                              minutes: 120, mode: 'DRIVE', start_at: '2026-09-30T23:00:00+09:00')
  end

  test 'explicit duration rejects invalid complete tokens without provider fallback' do
    ['0', '-20', "−\n20", '241', '1020', '10020', '4', '20.5', '+20'].each do |value|
      ["所要時間は#{value}分", "移動時間#{value}分", "#{value}分移動"].each do |suffix|
        input = "2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、#{suffix}"
        result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
        assert_empty result.fetch(:recommendations), input
        assert_empty @provider.calls, input
      end
    end
    [
      '2026年9月30日の10時60分に東京駅から有楽町駅まで徒歩で移動、所要時間は20分',
      '2026年9月30日の10:60に東京駅から有楽町駅まで徒歩で移動、所要時間は20分',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分、移動時間30分'
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result.fetch(:recommendations), input
      assert_empty @provider.calls, input
    end
  end

  test 'explicit duration preserves real meeting duration and separate arrival buffer' do
    input = '東京駅から有楽町駅まで徒歩で移動、所要時間は20分、2026年9月30日の10時に会議を45分、15分前に到着'
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
    assert_empty @provider.calls
    assert_equal 1, result.fetch(:recommendations).length, result[:assistant_message]
    travel, meeting = result.fetch(:recommendations).first.fetch('payload').fetch('events')
    assert_equal '2026-09-30T09:25:00+09:00', travel.fetch('start_at')
    assert_equal '2026-09-30T09:45:00+09:00', travel.fetch('end_at')
    assert_equal 20, travel.fetch('travel_assist').fetch('travel_minutes')
    assert_equal 15, travel.fetch('travel_assist').fetch('arrival_buffer_minutes')
    assert_equal '会議', meeting.fetch('title')
    assert_equal '2026-09-30T10:00:00+09:00', meeting.fetch('start_at')
    assert_equal '2026-09-30T10:45:00+09:00', meeting.fetch('end_at')
    refute_includes result.to_json, 'Google Maps'
  end

  test 'explicit duration does not borrow meeting quoted or buffer minutes' do
    [
      '東京駅から有楽町駅まで電車で移動、明日10時に会議、所要時間は20分',
      '東京駅から有楽町駅まで電車で移動、明日10時に会議の所要時間20分',
      '東京駅から有楽町駅まで電車で移動、明日10時に「20分会議」を45分、15分前に到着'
    ].each do |input|
      result = response(input)
      payload = candidate(result)
      assert_equal 1, @provider.calls.length, input
      assert_equal 30, payload.fetch('events').first.fetch('travel_assist').fetch('travel_minutes'), input
      assert_equal 2, payload.fetch('events').length, input
      unless input.include?('「20分会議」')
        meeting = payload.fetch('events').last
        assert_equal 20 * 60, Time.iso8601(meeting.fetch('end_at')) - Time.iso8601(meeting.fetch('start_at')), input
      end
    end
    result = response('明日10時に会議、所要時間は20分')
    assert_empty @provider.calls
    assert result.fetch(:recommendations).all? { |item| !item.fetch('payload').key?('travel_assist') }
    result = response('明日10時に会議を20分')
    payload = result.fetch(:recommendations).first.fetch('payload')
    assert_equal '2026-05-19T10:20:00+09:00', payload.fetch('end_at')
    refute payload.key?('travel_assist')
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: '')
    ['東京駅から有楽町駅まで20分前に到着', '東京駅から有楽町駅まで10時20分移動', '「移動時間20分」'].each do |input|
      assert_nil client.send(:extract_travel_route, input)[:travel_minutes], input
    end
  end

  test 'explicit duration retains multileg mode time and conflict fail closed checks' do
    [
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、その後上野駅へ移動、移動時間20分',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩か車で移動、移動時間20分',
      '2026年9月30日の10時に東京駅から有楽町駅まで自転車で移動、移動時間20分',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分、打ち合わせもお願い',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分、15分前に到着',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分、0分前に到着',
      '2026年9月30日の10時から11時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分',
      '2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分、2026年10月1日'
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result.fetch(:recommendations), input
      assert_empty @provider.calls, input
    end
    existing = { id: 903, title: '合成重複予定', start_at: '2026-09-30T10:10:00+09:00', end_at: '2026-09-30T10:30:00+09:00' }
    result = response('2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分',
                      context: { now: '2026-09-23T13:15:00+09:00', personal_events: [existing] })
    assert_empty result.fetch(:recommendations)
    assert_empty @provider.calls
    assert_includes result[:assistant_message], '重なります'
  end

  test 'explicit duration does not override mutation recurrence and all day exclusions' do
    [
      '2026年9月30日10時に東京駅から有楽町駅まで徒歩で移動時間20分の予定を削除して',
      '毎週水曜10時に東京駅から有楽町駅まで徒歩で20分移動',
      '2026年9月30日は終日、東京駅から有楽町駅まで徒歩で移動時間20分'
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty @provider.calls, input
      refute_equal 'rails-local-travel-assist-explicit-v1', result[:provider], input
      refute_equal 'rails-local-routes-api-v1', result[:provider], input
    end
  end

  test 'explicit duration and missing duration do not borrow reverse saved route minutes' do
    reverse = { id: 91, origin_name: '有楽町駅', destination_name: '東京駅', travel_minutes: 70, transport_mode: 'walk' }
    context = { user_travel_routes: [reverse] }
    assert_explicit_departure('2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分', context: context)
    result = response('2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動', context: context)
    assert_equal 1, @provider.calls.length
    assert_equal 30, candidate(result).fetch('events').first.fetch('travel_assist').fetch('travel_minutes')
    unavailable = Provider.new { |_request| Result.new(code: 'no_route') }
    result = response('2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動', context: context, provider: unavailable)
    assert_empty result.fetch(:recommendations)
    assert_equal 1, @provider.calls.length
  end

  test 'explicit travel duration is not replaced by a provider guess' do
    response('2026年9月30日の10時に東京駅から有楽町駅まで徒歩で移動、所要時間は20分',
             context: { now: '2026-09-23T13:15:00+09:00' })
    assert_empty @provider.calls
  end

  test 'production N-008 binds the explicit route date instead of ambient today' do
    input = "今日はカレンダーの整理をしています。天気の話ではありません。\n2026年9月30日の13時に東京駅から有楽町駅まで徒歩で移動\n移動予定だけを候補にしてください。"
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
    assert_equal '2026-09-30T13:00:00+09:00', @requested_times.first&.iso8601, 'N-008 resolved route datetime'
    assert_departure_route_case({
      id: 'N-008', input: input, mode: 'WALK', origin: '東京駅', destination: '有楽町駅',
      departure_time: '2026-09-30T13:00:00+09:00'
    }, result)
  end

  test 'route date binding keeps absolute relative and surrounding date controls' do
    route = '2026年9月30日の13時に東京駅から有楽町駅まで徒歩で移動'
    controls = [
      ['no wrapper', route, '2026-09-30T13:00:00+09:00'],
      ['today core', '今日15時に東京駅から有楽町駅まで徒歩で移動', '2026-09-23T15:00:00+09:00'],
      ['tomorrow core', '明日10時に東京駅から有楽町駅まで徒歩で移動', '2026-09-24T10:00:00+09:00'],
      ['past absolute first', '2026年9月22日はカレンダーの整理をしています。明日10時に東京駅から有楽町駅まで徒歩で移動', '2026-09-24T10:00:00+09:00'],
      ['past absolute last', '明日10時に東京駅から有楽町駅まで徒歩で移動。2026年9月22日はカレンダーの整理をしています。', '2026-09-24T10:00:00+09:00'],
      ['unrelated future first', "2026年10月1日はカレンダーの整理をしています。#{route}", '2026-09-30T13:00:00+09:00'],
      ['ambient tomorrow last', "#{route}。明日はカレンダーの整理をしています。", '2026-09-30T13:00:00+09:00'],
      ['punctuation whitespace', "今日は カレンダーの整理をしています！\n 天気の話ではありません？\n２０２６年９月３０日の１３時に東京駅から有楽町駅まで徒歩で移動！\n移動予定だけを候補にしてください。", '2026-09-30T13:00:00+09:00'],
      ['same date repeated', "2026年9月30日の移動について確認をお願いします。#{route}", '2026-09-30T13:00:00+09:00'],
      ['month day shorthand', '9月30日13時に東京駅から有楽町駅まで徒歩で移動', '2026-09-30T13:00:00+09:00'],
      ['compact 1320', '明日1320に東京駅から有楽町駅まで徒歩で移動', '2026-09-24T13:20:00+09:00'],
      ['compact 2300', '今日2300に東京駅から有楽町駅まで徒歩で移動', '2026-09-23T23:00:00+09:00'],
      ['full width 1800', '今日１８００に東京駅から有楽町駅まで徒歩で移動', '2026-09-23T18:00:00+09:00']
    ]
    controls.each do |id, input, departure|
      assert_departure_route_case(id: id, input: input, mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: departure)
    end
  end

  test 'route date binding preserves month and year boundaries' do
    [
      ['2026-09-30T13:15:00+09:00', '2026年10月1日', '2026-10-01T13:00:00+09:00'],
      ['2026-12-31T13:15:00+09:00', '2027年1月1日', '2027-01-01T13:00:00+09:00']
    ].each do |now, date, departure|
      assert_departure_route_case(id: date, input: "今日はカレンダーの整理をしています。#{date}13時に東京駅から有楽町駅まで徒歩で移動",
                                 now: now, mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: departure)
    end
  end

  test 'route date binding preserves existing holiday and meridiem expressions' do
    [
      ['GW明けの10時に東京駅から有楽町駅まで徒歩で移動', '2027-05-07T10:00:00+09:00'],
      ['明日AM10時に東京駅から有楽町駅まで徒歩で移動', '2026-09-24T10:00:00+09:00'],
      ['2026年9月30日水曜日の13時に東京駅から有楽町駅まで徒歩で移動', '2026-09-30T13:00:00+09:00'],
      ['来週 金曜15時に東京駅から有楽町駅まで徒歩で移動', '2026-10-02T15:00:00+09:00'],
      ['再来週の 金曜15時に東京駅から有楽町駅まで徒歩で移動', '2026-10-09T15:00:00+09:00']
    ].each do |input, departure|
      assert_departure_route_case(id: input, input: input, mode: 'WALK', origin: '東京駅', destination: '有楽町駅', departure_time: departure)
    end
  end

  test 'route date binding rejects conflicting action dates including parentheses' do
    [
      '2026年9月30日と2026年10月1日13時に東京駅から有楽町駅まで徒歩で移動',
      '明日2026年9月30日13時に東京駅から有楽町駅まで徒歩で移動',
      '明日（2026年9月30日）13時に東京駅から有楽町駅まで徒歩で移動',
      '2026年9月24日の移動について確認をお願いします。2026年9月30日13時に東京駅から有楽町駅まで徒歩で移動',
      '2026年9月24日。2026年9月30日13時に東京駅から有楽町駅まで徒歩で移動'
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_clarifies result, '異なる日付'
      assert_empty @provider.calls, input
    end
  end

  test 'route date binding retains surrounding clauses with explicit action clocks' do
    result = response('2026年9月30日15時にカレンダーの整理をしています。2026年10月1日13時に東京駅から有楽町駅まで徒歩で移動',
                      context: { now: '2026-09-23T13:15:00+09:00' })
    assert_empty result.fetch(:recommendations)
    assert_empty @provider.calls
  end

  test 'route date binding never hides conflicting bracketed date annotations' do
    ['【2026年9月30日】', '[2026年9月30日]', '（開催日:2026年9月30日）'].each do |annotation|
      result = response("東京駅から大阪駅まで電車で移動。明日15時に会議#{annotation}",
                        context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result.fetch(:recommendations), annotation
      assert_empty @provider.calls, annotation
    end
  end

  test 'route date binding never borrows ambient dates or rescues invalid dates and clocks' do
    [
      '今日はカレンダーの整理をしています。13時に東京駅から有楽町駅まで徒歩で移動',
      '13時に東京駅から有楽町駅まで徒歩で移動',
      '2026年9月31日13時に東京駅から有楽町駅まで徒歩で移動',
      '2027年2月29日13時に東京駅から有楽町駅まで徒歩で移動',
      '2026年9月22日13時に東京駅から有楽町駅まで徒歩で移動',
      '2026年9月30日24:00に東京駅から有楽町駅まで徒歩で移動',
      '明日2360に東京駅から有楽町駅まで徒歩で移動'
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result.fetch(:recommendations), input
      assert_empty @provider.calls, input
    end
  end

  test 'route date binding ignores literal title dates and clocks while retaining the appointment' do
    ['「9月25日 1320 ID2300 会議」', '「2026年10月1日 2300 会議」'].each do |title|
      result = response("東京駅から大阪駅まで電車で移動。2026年9月30日15時にタイトルは#{title}",
                        context: { now: '2026-09-23T13:15:00+09:00' })
      payload = candidate(result)
      assert_equal 1, @provider.calls.length
      request = @provider.calls.first
      assert_equal 'TRANSIT', request.fetch(:mode)
      assert_equal 'RAIL', request.fetch(:transit_mode)
      assert_equal '東京駅', request.fetch(:origin)
      assert_equal '大阪駅', request.fetch(:destination)
      refute request.key?(:departure_time)
      assert_equal 2, payload.fetch('events').length
      event = payload.fetch('events').last
      assert_equal '2026-09-30T15:00:00+09:00', event.fetch('start_at')
      assert_equal title[1...-1], event.fetch('title')
      assert_equal '2026-09-30', request.fetch(:arrival_time).to_date.iso8601
      assert_equal true, result.fetch(:tool_invocations).first.fetch(:metadata).fetch(:read_only)
    end
  end

  test 'route date binding preserves appointment duration and overnight annotations' do
    [
      ['2026年9月30日15時に会議（30分）', '2026-09-30T15:00:00+09:00', '2026-09-30T15:30:00+09:00'],
      ['2026年9月30日23時から1時まで会議（日またぎ）', '2026-09-30T23:00:00+09:00', '2026-10-01T01:00:00+09:00']
    ].each do |appointment, start_at, end_at|
      result = response("東京駅から大阪駅まで電車で移動、#{appointment}", context: { now: '2026-09-23T13:15:00+09:00' })
      payload = candidate(result)
      assert_equal 1, @provider.calls.length
      assert_equal 2, payload.fetch('events').length
      event = payload.fetch('events').last
      assert_equal start_at, event.fetch('start_at')
      assert_equal end_at, event.fetch('end_at')
    end
  end

  test 'route date binding does not parse clock range fragments as calendar dates' do
    [
      ['13:00-14:00', '2026-09-24T13:00:00+09:00', '2026-09-24T14:00:00+09:00'],
      ['1320-1420', '2026-09-24T13:20:00+09:00', '2026-09-24T14:20:00+09:00']
    ].each do |range, start_at, end_at|
      result = response("東京駅から大阪駅まで電車で移動、明日#{range}に会議", context: { now: '2026-09-23T13:15:00+09:00' })
      payload = candidate(result)
      assert_equal 1, @provider.calls.length
      assert_equal Time.iso8601(start_at), @provider.calls.first.fetch(:arrival_time)
      event = payload.fetch('events').last
      assert_equal start_at, event.fetch('start_at')
      assert_equal end_at, event.fetch('end_at')
    end
  end

  test 'route date binding does not change normal nonroute scheduling or promote numeric IDs' do
    result = response('2026年9月30日13時にタイトルは「ID1320 料金2300円 会議」を1時間入れて',
                      context: { now: '2026-09-23T13:15:00+09:00' })
    assert_empty @provider.calls
    event = result.fetch(:recommendations).first.fetch('payload')
    assert_equal '2026-09-30T13:00:00+09:00', event.fetch('start_at')
    assert_equal 'ID1320 料金2300円 会議', event.fetch('title')
  end

  test 'provider failure after wrapper parsing remains fail closed' do
    provider = Provider.new { Result.new(code: 'no_route') }
    result = response(PRODUCTION_WRAPPER_INTENT_CASES.first.fetch(:input),
                      context: { now: '2026-09-23T13:15:00+09:00' }, provider: provider)
    assert_clarifies result, '取得できませんでした'
    assert_equal 1, provider.calls.length
  end

  test 'departure travel consult uses real route times instead of event mutation parser' do
    result = nil
    assert_no_difference 'Event.count' do
      result = response('明日10時に東京駅から大阪駅まで電車で移動')
    end
    payload = candidate(result)
    assert_equal '移動: 東京駅 → 大阪駅', payload.fetch('title')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(payload.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T10:30:00+09:00'), Time.iso8601(payload.fetch('end_at'))
    assert_equal 'TRANSIT', @provider.calls.one? && @provider.calls.first.fetch(:mode)
    assert_equal 'RAIL', @provider.calls.first.fetch(:transit_mode)
    assert_equal '東京駅', @provider.calls.first.fetch(:origin)
    assert_equal '大阪駅', @provider.calls.first.fetch(:destination)
    assert_equal 1800, payload.fetch('travel_assist').fetch('duration_seconds')
    assert_equal 1, payload.fetch('events').length
    assert_includes result.fetch(:assistant_message), 'Google Maps'
    assert_equal 'google_routes', payload.fetch('routing').fetch('source')
    assert_equal 'TRANSIT', payload.fetch('routing').fetch('request').fetch('mode')
    assert_equal 900, Time.iso8601(payload['routing']['expires_at']) - Time.iso8601(payload['routing']['checked_at'])
  end

  def assert_appointment_binding(input, buffer: 15, context: {}, provider: Provider.new, duration: 30, arrival_offset: 0)
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' }.merge(context), provider: provider)
    request = @provider.calls.first || {}
    assert_equal '上野駅近く', request[:destination], result[:assistant_message]
    assert_equal '東京駅', request[:origin]
    assert_equal 'TRANSIT', request[:mode]
    refute request.key?(:transit_mode)
    deadline = Time.iso8601('2026-09-28T15:00:00+09:00') - buffer.minutes
    assert_equal deadline.iso8601, request[:arrival_time]&.iso8601
    refute request.key?(:departure_time)
    assert_equal 1, @provider.calls.length
    payload = candidate(result)
    assert_equal 2, payload.fetch('events').length
    travel, meeting = payload.fetch('events')
    assert_equal '移動: 東京駅 → 上野駅近く', travel.fetch('title')
    assert_equal '上野駅近く', travel.fetch('location')
    assert_equal (deadline - arrival_offset.minutes - duration.minutes).iso8601, travel.fetch('start_at')
    assert_equal (deadline - arrival_offset.minutes).iso8601, travel.fetch('end_at')
    assert_equal duration, travel.fetch('travel_assist').fetch('travel_minutes')
    assert_equal buffer, travel.fetch('travel_assist').fetch('arrival_buffer_minutes')
    assert_equal '会議', meeting.fetch('title')
    assert_equal '上野駅近く', meeting.fetch('location')
    assert_equal '2026-09-28T15:00:00+09:00', meeting.fetch('start_at')
    assert_equal '2026-09-28T16:00:00+09:00', meeting.fetch('end_at')
    assert_equal '移動込み: 会議', result.fetch(:recommendations).first.fetch('title')
    assert_equal buffer, payload.fetch('routing').fetch('arrival_buffer_minutes')
    assert_equal 'Google Maps', payload.fetch('route_attribution')
    assert_includes result[:assistant_message], 'Google Maps'
    assert_equal 1, result[:tool_invocations].length
    assert_equal true, result[:tool_invocations].first.fetch(:metadata).fetch(:read_only)
    result
  end

  test 'production P-APPOINTMENT-W0 binds the appointment location' do
    assert_appointment_binding("2026年9月28日の15時から16時に上野駅近くで会議があります。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。")
  end

  test 'production P-APPOINTMENT-POLITE binds the appointment location' do
    assert_appointment_binding("恐れ入りますが、2026年9月28日の15時から16時に上野駅近くで会議があります。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。経路も確認して候補を出していただけますか。")
  end

  test 'production P-APPOINTMENT-TWO binds the appointment location' do
    assert_appointment_binding("カレンダー上の会議と移動をまとめて確認しています。2026年9月28日の15時から16時に上野駅近くで会議があります。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。")
  end

  test 'production P-APPOINTMENT-LINES binds the appointment location' do
    assert_appointment_binding("会議の到着時刻を確認してください。\n2026年9月28日の15時から16時に上野駅近くで会議があります。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。\nまずは予定候補だけ作って、まだ保存しないでください。")
  end

  APPOINTMENT_BINDING_CORE = '2026年9月28日の15時から16時に上野駅近くで会議があります。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。'.freeze

  test 'appointment binding preserves exact explicit destination and buffer boundaries' do
    assert_appointment_binding(APPOINTMENT_BINDING_CORE.sub('東京駅から公共交通', '東京駅から上野駅近くまで公共交通'))
    [0, 15, 180].each do |minutes|
      assert_appointment_binding(APPOINTMENT_BINDING_CORE.sub('15分前', "#{minutes}分前"), buffer: minutes)
    end
    saved = { id: 71, origin_name: '東京駅', destination_name: '上野駅近く', transport_mode: 'public_transport', arrival_buffer_minutes: 30, travel_minutes: 70 }
    context = { user_travel_routes: [saved, saved.merge(id: 72, origin_name: '上野駅近く', destination_name: '東京駅', arrival_buffer_minutes: 90), saved.merge(id: 73, transport_mode: 'walk', arrival_buffer_minutes: 120)] }
    assert_appointment_binding(APPOINTMENT_BINDING_CORE, buffer: 30, context: context)
    early = Provider.new do |request|
      arrival = request.fetch(:arrival_time) - 5.minutes
      Result.new(code: 'ok', duration_seconds: 17 * 60, departure_time: (arrival - 17.minutes).iso8601, arrival_time: arrival.iso8601)
    end
    assert_appointment_binding(APPOINTMENT_BINDING_CORE, provider: early, duration: 17, arrival_offset: 5)
  end

  test 'appointment binding keeps different missing and ambiguous places fail closed' do
    inputs = [
      APPOINTMENT_BINDING_CORE.sub('東京駅から公共交通', '東京駅から上野駅まで公共交通'),
      APPOINTMENT_BINDING_CORE.sub('東京駅から公共交通', '東京駅から京都駅まで公共交通'),
      APPOINTMENT_BINDING_CORE.sub('上野駅近くで', ''),
      APPOINTMENT_BINDING_CORE.sub('上野駅近く', '現在地'),
      APPOINTMENT_BINDING_CORE.sub('上野駅近く', 'いつもの場所'),
      APPOINTMENT_BINDING_CORE.sub('会議があります', '会議と京都駅で面談があります'),
      '京都駅で会議の資料を確認しています。' + APPOINTMENT_BINDING_CORE,
      APPOINTMENT_BINDING_CORE + '京都駅で打ち合わせもあります。'
    ]
    inputs.each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result[:recommendations], input
      assert_empty @provider.calls, input
    end
    places = [81, 82].map { |id| { id: id, label: '上野駅近く', place_name: "合成会場#{id}", address_text: "合成住所#{id}" } }
    result = response(APPOINTMENT_BINDING_CORE, context: { now: '2026-09-23T13:15:00+09:00', user_places: places })
    assert_empty result[:recommendations]
    assert_empty @provider.calls
  end

  test 'appointment binding never adopts a place inside a quoted title or parenthesis' do
    [
      '2026年9月28日の15時から16時に「上野駅近くで会議」の相談です。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。',
      '2026年9月28日の15時から16時に会議（上野駅近くで会議）があります。東京駅から公共交通機関で移動して15分前に到着する候補を作ってください。'
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result[:recommendations], input
      assert_empty @provider.calls, input
    end
    input = '東京駅から上野駅近くまで公共交通機関で移動、2026年9月28日の15時から16時に「京都駅で会議」、15分前に到着'
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
    payload = candidate(result)
    assert_equal '上野駅近く', @provider.calls.first.fetch(:destination)
    assert_equal '上野駅近く', payload.fetch('events').last.fetch('location')
    assert_equal '「京都駅で会議」', payload.fetch('events').last.fetch('title')
  end

  test 'appointment binding retains mode buffer and provider validation' do
    [
      APPOINTMENT_BINDING_CORE.sub('公共交通機関', '徒歩'),
      APPOINTMENT_BINDING_CORE.sub('公共交通機関', '車'),
      APPOINTMENT_BINDING_CORE.sub('公共交通機関', '徒歩か車'),
      APPOINTMENT_BINDING_CORE.sub('15分前', '181分前'),
      APPOINTMENT_BINDING_CORE.sub('15分前', '-15分前'),
      APPOINTMENT_BINDING_CORE.sub('東京駅から', '東京駅から京都駅を経由して')
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result[:recommendations], input
      assert_empty @provider.calls, input
    end
    [Provider.new { |_r| Result.new(code: 'no_route') }, Provider.new { |r| Result.new(code: 'ok', duration_seconds: 1800, departure_time: (r.fetch(:arrival_time) - 20.minutes).iso8601, arrival_time: (r.fetch(:arrival_time) + 10.minutes).iso8601) }].each do |provider|
      result = response(APPOINTMENT_BINDING_CORE, context: { now: '2026-09-23T13:15:00+09:00' }, provider: provider)
      assert_empty result[:recommendations]
      assert_equal 1, @provider.calls.length
    end
  end

  test 'appointment binding retains travel waiting gap and meeting conflict checks' do
    %w[14:20 14:50 15:10].each do |time|
      start = Time.iso8601("2026-09-28T#{time}:00+09:00")
      existing = { id: 91, title: '合成重複予定', start_at: start.iso8601, end_at: (start + 5.minutes).iso8601 }
      result = response(APPOINTMENT_BINDING_CORE, context: { now: '2026-09-23T13:15:00+09:00', personal_events: [existing] })
      assert_empty result[:recommendations], time
      assert_includes result[:assistant_message], '重なります'
    end
    input = APPOINTMENT_BINDING_CORE.sub('移動して', '移動、移動時間20分、')
    result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
    assert_empty @provider.calls
    travel, meeting = result[:recommendations].first.fetch('payload').fetch('events')
    assert_equal '2026-09-28T14:25:00+09:00', travel.fetch('start_at')
    assert_equal '2026-09-28T14:45:00+09:00', travel.fetch('end_at')
    assert_equal '2026-09-28T15:00:00+09:00', meeting.fetch('start_at')
    assert_equal '2026-09-28T16:00:00+09:00', meeting.fetch('end_at')
    assert_equal '上野駅近く', meeting.fetch('location')
    refute_includes result.to_json, 'Google Maps'
  end

  test 'appointment binding keeps whitespace-separated route and meeting locations distinct' do
    assert_appointment_binding('東京駅から上野駅近くまで公共交通機関で移動 2026年9月28日の15時から16時に上野駅近くで会議、15分前に到着')
  end

  test 'appointment binding zero arrival allowance never permits zero event or travel duration' do
    [
      APPOINTMENT_BINDING_CORE.sub('15時から16時', '15時').sub('会議があります', '会議を0分').sub('15分前', '0分前'),
      APPOINTMENT_BINDING_CORE.sub('移動して', '移動、移動時間0分、').sub('15分前', '0分前'),
      APPOINTMENT_BINDING_CORE.sub('15分前', '0.0分前')
    ].each do |input|
      result = response(input, context: { now: '2026-09-23T13:15:00+09:00' })
      assert_empty result[:recommendations], input
      assert_empty @provider.calls, input
    end
  end

  test 'fixed appointment transit includes buffer and retains full main duration' do
    result = response('東京駅から大阪駅まで電車で移動、明日15時に会議、15分前に到着')
    payload = candidate(result)
    travel, main = payload.fetch('events')
    assert_equal '移動込み: 会議', result[:recommendations].first.fetch('title')
    assert_equal '会議', main.fetch('title')
    assert_equal '2026-05-19T14:15:00+09:00', travel.fetch('start_at')
    assert_equal '2026-05-19T14:45:00+09:00', travel.fetch('end_at')
    assert_equal '2026-05-19T15:00:00+09:00', main.fetch('start_at')
    assert_equal '2026-05-19T16:00:00+09:00', main.fetch('end_at')
    assert_equal 15, payload['routing']['arrival_buffer_minutes']
    assert_equal Time.iso8601('2026-05-19T14:45:00+09:00'), @provider.calls.first.fetch(:arrival_time)
    refute @provider.calls.first.key?(:departure_time)
  end

  test 'destination attached to main appointment and origin attached to movement work together' do
    payload = candidate(response('明日15時に大阪駅で会議、東京駅から電車で移動も入れて'))
    assert_equal '会議', payload.fetch('events').last.fetch('title')
    assert_equal '東京駅', @provider.calls.first.fetch(:origin)
    assert_equal '大阪駅', @provider.calls.first.fetch(:destination)
  end

  test 'explicit main end time is retained and clock connector is not a second route' do
    payload = candidate(response('東京駅から大阪駅まで電車で移動、明日15時から16時に会議'))
    assert_equal '2026-05-19T16:00:00+09:00', payload.fetch('events').last.fetch('end_at')
  end

  test 'car and walking allow only departure route requests' do
    { '車' => 'DRIVE', '徒歩' => 'WALK' }.each do |label, mode|
      candidate(response("明日10時に東京駅から大阪駅まで#{label}で移動"))
      assert_equal mode, @provider.calls.first.fetch(:mode)
      assert @provider.calls.first.key?(:departure_time)
      result = response("東京駅から大阪駅まで#{label}で移動、明日15時に会議")
      assert_clarifies result, '出発日時'
      assert_empty @provider.calls
    end
  end

  test 'missing route inputs never call provider or invent candidates' do
    {
      '明日10時に東京駅から大阪駅まで移動' => '交通手段',
      '東京駅から大阪駅まで電車で移動' => '日付',
      '明日東京駅から大阪駅まで電車で移動' => '出発時刻',
      '明日10時に電車で移動' => '出発地',
      '明日10時に東京駅から大阪駅まで自転車で移動' => '交通手段',
      '明日10時に東京駅から大阪駅まで電車と車で移動' => '交通手段'
    }.each do |message, clarification|
      assert_clarifies response(message), clarification
      assert_empty @provider.calls
    end
  end

  test 'rail and bus constraints remain explicit and shinkansen is not silently broadened' do
    candidate(response('明日10時に東京駅から大阪駅までバスで移動'))
    assert_equal 'BUS', @provider.calls.first.fetch(:transit_mode)
    candidate(response('明日10時に東京駅から大阪駅まで公共交通で移動'))
    refute @provider.calls.first.key?(:transit_mode)
    ['新幹線', '電車とバス'].each do |mode|
      assert_clarifies response("明日10時に東京駅から大阪駅まで#{mode}で移動"), '対応していません'
      assert_empty @provider.calls
    end
  end

  test 'current location and unbound home are never sent as guessed addresses' do
    %w[現在地 自宅 勤務先].each do |place|
      assert_clarifies response("明日10時に#{place}から大阪駅まで電車で移動"), '住所'
      assert_empty @provider.calls
    end
  end

  test 'saved aliases resolve exact scoped names and retain binding evidence' do
    saved = { id: 12, kind: 'home', label: '自宅', place_name: '東京駅', address_text: '東京都千代田区丸の内1丁目' }
    payload = candidate(response('明日10時に自宅から大阪駅まで電車で移動', context: { user_places: [saved] }))
    assert_equal saved[:address_text], @provider.calls.first.fetch(:origin)
    assert_equal '移動: 自宅 → 大阪駅', payload.fetch('title')
    assert_equal [saved.stringify_keys], payload.fetch('routing').fetch('place_bindings')

    assert_clarifies response('明日10時に自宅から大阪駅まで電車で移動', context: { user_places: [saved.merge(label: '自宅近く')] }), '住所'
    assert_empty @provider.calls
    assert_clarifies response('明日10時に自宅から大阪駅まで電車で移動', context: { user_places: [saved, saved.merge(id: 13)] }), '住所'
    assert_empty @provider.calls
  end

  test 'multi leg or intervening lunch request never silently drops a segment' do
    [
      '明日10時に東京駅から新宿駅まで電車で移動、その後新宿駅から大阪駅まで電車で移動',
      '明日10時に東京駅から大阪駅まで電車で移動、途中でランチ',
      '東京駅から大阪駅まで電車で移動、明日15時に会議、ランチも入れて'
    ].each do |message|
      result = response(message)
      assert_equal 'rails-local-routes-api-v1', result.fetch(:provider)
      assert_empty result.fetch(:recommendations)
      assert_empty @provider.calls
    end
  end

  test 'provider failures and exceptions are closed and contain no upstream secrets' do
    %w[not_configured unavailable no_route invalid_response].each do |code|
      result = response('明日10時に東京駅から大阪駅まで電車で移動', provider: Provider.new { Result.new(code: code) })
      assert_clarifies result, '取得できませんでした'
      assert_equal code, result.fetch(:tool_invocations).first.fetch(:output_payload).fetch(:code)
    end
    result = response('明日10時に東京駅から大阪駅まで電車で移動', provider: Provider.new { raise 'secret_api_key_and_private_address' })
    assert_clarifies result, '取得できませんでした'
    refute_includes result.to_json, 'secret_api_key_and_private_address'
  end

  test 'out of bounds provider times and past departure produce no candidate' do
    early = Provider.new do |request|
      start = request.fetch(:departure_time) - 60
      Result.new(code: 'ok', duration_seconds: 1800, departure_time: start.iso8601, arrival_time: (start + 1800).iso8601)
    end
    assert_clarifies response('明日10時に東京駅から大阪駅まで電車で移動', provider: early), '指定日時'

    result = response('東京駅から大阪駅まで電車で移動、今日8時15分に会議')
    assert_clarifies result, '出発時刻が過去'
  end

  test 'travel main and arrival waiting gap all check existing conflicts' do
    [
      ['2026-05-19T14:20:00+09:00', '2026-05-19T14:30:00+09:00'],
      ['2026-05-19T14:50:00+09:00', '2026-05-19T14:55:00+09:00'],
      ['2026-05-19T15:30:00+09:00', '2026-05-19T16:00:00+09:00']
    ].each do |start_at, end_at|
      existing = { id: 901, title: '既存予定', start_at: start_at, end_at: end_at, all_day: false }
      result = response('東京駅から大阪駅まで電車で移動、明日15時に会議、15分前に到着', context: { personal_events: [existing] })
      assert_clarifies result, '重なります'
    end
  end

  test 'explicit travel duration and ordinary location meeting avoid API calls' do
    result = response('自宅から大阪駅まで45分、明日10時に会議、15分前に到着')
    assert_equal 'rails-local-travel-assist-bundle-v1', result.fetch(:provider)
    assert_empty @provider.calls
    assert_equal 2, result.fetch(:recommendations).first.fetch('payload').fetch('events').size

    result = response('明日10時に大阪駅で会議')
    assert_equal 'rails-local-single-explicit-v5', result.fetch(:provider)
    assert_empty @provider.calls
  end

  test 'saved travel memory for existing location schedule still avoids API calls' do
    saved = { id: 1, origin_name: '自宅', origin_kind: 'home', destination_name: '大阪駅', travel_minutes: 30, transport_mode: 'train' }
    result = response('明日10時に大阪駅で会議', context: { user_travel_routes: [saved] })
    assert_equal 'rails-local-saved-travel-memory-v1', result.fetch(:provider)
    assert_equal 2, result.fetch(:recommendations).size
    travel = result.fetch(:recommendations).last.fetch('payload').fetch('events').first
    assert_equal 30, travel.fetch('travel_assist').fetch('travel_minutes')
    assert_empty @provider.calls
  end

  test 'upstream UTC times are rendered and stored in context timezone' do
    utc = Provider.new do |_request|
      Result.new(code: 'ok', duration_seconds: 1800, departure_time: '2026-05-19T01:00:00Z',
                 arrival_time: '2026-05-19T01:30:00Z', walking_seconds: 0, distance_meters: 100)
    end
    result = response('明日10時に東京駅から大阪駅まで電車で移動', provider: utc)
    payload = candidate(result)
    assert_equal '2026-05-19T10:00:00+09:00', payload.fetch('start_at')
    assert_equal '2026-05-19T10:30:00+09:00', payload.fetch('end_at')
    assert_includes result.fetch(:assistant_message), '5/19 10:00出発'
  end

  test 'place names containing hiragana ni are not truncated' do
    candidate(response('明日10時に東京駅からなにわ橋駅に電車で移動'))
    assert_equal 'なにわ橋駅', @provider.calls.first.fetch(:destination)
  end

  test 'different main location and unrecognized extra activity never silently disappear' do
    [
      '東京駅から大阪駅まで電車で移動、明日15時に京都駅で会議',
      '東京駅から大阪駅まで電車で移動、明日15時にプレゼン'
    ].each do |message|
      result = response(message)
      assert_equal 'rails-local-routes-api-v1', result.fetch(:provider)
      assert_empty result.fetch(:recommendations)
      assert_empty @provider.calls
    end
  end

  test 'effective arrival buffer takes maximum explicit preference and exact saved direction mode' do
    route = { id: 1, origin_name: '東京駅', destination_name: '大阪駅', transport_mode: 'train', travel_minutes: 30, arrival_buffer_minutes: 25 }
    context = {
      ai_user_preferences: [{ key: 'arrival_buffer.meeting', value: '20' }, { key: 'arrival_buffer.default', value: '10' }],
      user_travel_routes: [route, route.merge(origin_name: '大阪駅', destination_name: '東京駅', arrival_buffer_minutes: 100),
                           route.merge(transport_mode: 'car', arrival_buffer_minutes: 120),
                           route.merge(destination_name: '新大阪駅', arrival_buffer_minutes: 150)]
    }
    payload = candidate(response('東京駅から大阪駅まで電車で移動、明日15時に会議、15分前に到着', context: context))
    assert_equal 25, payload['routing']['arrival_buffer_minutes']
    assert_equal '2026-05-19T14:35:00+09:00', payload.fetch('events').first.fetch('end_at')
    assert_equal ['arrival_buffer.meeting', 'arrival_buffer.default'], payload['routing']['buffer_context']['preference_keys']
    assert_equal ['train'], payload['routing']['buffer_context']['transport_modes']
    assert_equal 15, payload['routing']['buffer_context']['explicit_minutes']

    context[:ai_user_preferences].first[:value] = '40'
    payload = candidate(response('東京駅から大阪駅まで電車で移動、明日15時に会議、15分前に到着', context: context))
    assert_equal 40, payload['routing']['arrival_buffer_minutes']
  end

  test 'malformed applicable saved buffer fails closed' do
    result = response('東京駅から大阪駅まで電車で移動、明日15時に会議',
                      context: { ai_user_preferences: [{ key: 'arrival_buffer.meeting', value: 'not-a-number' }] })
    assert_clarifies result, '0〜180分'
    assert_empty @provider.calls
  end
end
