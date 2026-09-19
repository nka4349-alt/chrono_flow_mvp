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
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message, routes_provider: provider)
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
