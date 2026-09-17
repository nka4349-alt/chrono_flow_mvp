# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientCompactClockTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-09-17T22:13:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  def response_for(message)
    remote_called = false
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: message)
    client.define_singleton_method(:request_remote) do
      remote_called = true
      raise 'Unexpected remote request in compact-clock regression'
    end

    response = nil
    assert_no_difference('Event.count', message) { response = client.call }
    refute remote_called, message
    assert_empty response.fetch(:tool_invocations), message
    response
  end

  def assert_event(event, title:, start_at:, end_at:)
    assert_equal title, event.fetch('title')
    assert_equal Time.iso8601(start_at), Time.iso8601(event.fetch('start_at'))
    assert_equal Time.iso8601(end_at), Time.iso8601(event.fetch('end_at'))
    assert_equal false, event.fetch('all_day')
  end

  def assert_single_schedule(message, title: '会議', start_at:, end_at:)
    response = response_for(message)
    assert_equal 1, response.fetch(:recommendations).length, message
    recommendation = response.fetch(:recommendations).sole
    assert_equal 'draft_event', recommendation.fetch('kind'), message
    assert_event(recommendation, title: title, start_at: start_at, end_at: end_at)

    payload = recommendation.fetch('payload')
    assert_event(payload, title: title, start_at: start_at, end_at: end_at)
    if payload.key?('events')
      assert_equal 1, payload.fetch('events').length, message
      assert_event(payload.fetch('events').sole, title: title, start_at: start_at, end_at: end_at)
    end
    response
  end

  test 'original today 2300 request means 23:00 through next midnight' do
    assert_single_schedule('今日の2300に会議',
                           start_at: '2026-09-17T23:00:00+09:00',
                           end_at: '2026-09-18T00:00:00+09:00')
  end

  test 'original tomorrow 1320 request means 13:20 for one hour' do
    assert_single_schedule('明日1320に会議',
                           start_at: '2026-09-18T13:20:00+09:00',
                           end_at: '2026-09-18T14:20:00+09:00')
  end

  test 'fullwidth compact clock digits retain the same requested times' do
    {
      '今日の２３００に会議' => ['2026-09-17T23:00:00+09:00', '2026-09-18T00:00:00+09:00'],
      '明日１３２０に会議' => ['2026-09-18T13:20:00+09:00', '2026-09-18T14:20:00+09:00']
    }.each do |message, (start_at, end_at)|
      assert_single_schedule(message, start_at: start_at, end_at: end_at)
    end
  end

  test 'compact clocks preserve midnight and leading-zero morning hours' do
    {
      '明日0000に会議' => ['2026-09-18T00:00:00+09:00', '2026-09-18T01:00:00+09:00'],
      '明日0930に会議' => ['2026-09-18T09:30:00+09:00', '2026-09-18T10:30:00+09:00']
    }.each do |message, (start_at, end_at)|
      assert_single_schedule(message, start_at: start_at, end_at: end_at)
    end
  end

  test '2359 is valid and its default duration crosses the date boundary' do
    assert_single_schedule('今日2359に会議',
                           start_at: '2026-09-17T23:59:00+09:00',
                           end_at: '2026-09-18T00:59:00+09:00')
  end

  test 'out of range compact hours and minutes are rejected without correction' do
    %w[2460 2400 2360].each do |clock|
      response = response_for("明日#{clock}に会議")

      assert_equal 'rails-local-time-validation-v1', response.fetch(:provider), clock
      assert_empty response.fetch(:recommendations), clock
      assert_includes response.fetch(:assistant_message), '無効', clock
    end
  end

  test 'a compact explicit time earlier today retains past-time validation' do
    response = response_for('今日1320に会議')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '過去'
    assert_includes response.fetch(:assistant_message), '13:20'
  end

  test 'long digit sequences and identifiers are not split into compact clocks' do
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: '')
    [
      '明日13200に会議',
      '明日123456に会議',
      'ID1320に関する会議',
      '項目1320に関する会議',
      '明日24600円の買い物'
    ].each do |message|
      assert_empty client.send(:explicit_clock_scan, message).fetch(:tokens), message
    end
  end

  test 'amounts and years are not interpreted as compact clocks' do
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: '')
    ['1320円の買い物', '2460円の買い物', '2026年の計画'].each do |message|
      assert_empty client.send(:explicit_clock_scan, message).fetch(:tokens), message
    end

    assert_single_schedule('2026年9月18日の15:00に会議',
                           start_at: '2026-09-18T15:00:00+09:00',
                           end_at: '2026-09-18T16:00:00+09:00')
  end

  test 'quoted compact-looking numeric names stay literal beside a real clock' do
    ['1320', '2460'].each do |title|
      message = "明日15:00から1時間の「#{title}」の候補をください。"
      client = Ai::Client.new(context: BASE_CONTEXT, user_message: message)
      assert_equal ['15:00'], client.send(:explicit_clock_scan, message).fetch(:tokens).map { |token| token.fetch(:raw) }, message
      assert_single_schedule(message, title: title,
                             start_at: '2026-09-18T15:00:00+09:00',
                             end_at: '2026-09-18T16:00:00+09:00')
    end
  end

  test 'existing colon ranges retain their exact start and end' do
    assert_single_schedule('明日13:20から14:20まで会議',
                           start_at: '2026-09-18T13:20:00+09:00',
                           end_at: '2026-09-18T14:20:00+09:00')
  end

  test 'compact time ranges retain both clocks with Japanese and hyphen connectors' do
    ['明日1320から1420まで会議', '明日1320-1420に会議'].each do |message|
      assert_single_schedule(message,
                             start_at: '2026-09-18T13:20:00+09:00',
                             end_at: '2026-09-18T14:20:00+09:00')
    end
  end

  test 'an explicitly overnight compact range keeps the next-day midnight endpoint' do
    assert_single_schedule('今日2300から翌日0000まで会議',
                           start_at: '2026-09-17T23:00:00+09:00',
                           end_at: '2026-09-18T00:00:00+09:00')
  end

  test 'a temporal-looking expression inside a quoted title remains literal' do
    message = '明日15:00から1時間の『1320に会議』の候補をください。'
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: message)

    assert_equal ['15:00'], client.send(:explicit_clock_scan, message).fetch(:tokens).map { |token| token.fetch(:raw) }
    assert_single_schedule(message, title: '1320に会議',
                           start_at: '2026-09-18T15:00:00+09:00',
                           end_at: '2026-09-18T16:00:00+09:00')
  end

  test 'a spaced currency unit does not turn an amount into the scheduled time' do
    message = '明日1320 円の備品を15:00に購入する'
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: message)

    assert_equal ['15:00'], client.send(:explicit_clock_scan, message).fetch(:tokens).map { |token| token.fetch(:raw) }
    response = response_for(message)
    recommendation = response.fetch(:recommendations).sole
    assert_equal '2026-09-18T15:00:00+09:00', recommendation.fetch('start_at')
    assert_equal '2026-09-18T16:00:00+09:00', recommendation.fetch('end_at')
  end

  test 'numbers in unquoted titles stay literal after an explicit clock' do
    [
      ['明日15:00に予算 3000 円の会議', '3000'],
      ['明日15:00に予算 1320 円の会議', '1320'],
      ['明日15:00に 2026 年度の計画会議', '2026'],
      ['明日15:00に ID 2460 に関する会議', '2460'],
      ['明日15:00に 1320 について会議', '1320']
    ].each do |message, literal|
      client = Ai::Client.new(context: BASE_CONTEXT, user_message: message)
      assert_equal ['15:00'], client.send(:explicit_clock_scan, message).fetch(:tokens).map { |token| token.fetch(:raw) }, message
      recommendation = response_for(message).fetch(:recommendations).sole
      assert_equal '2026-09-18T15:00:00+09:00', recommendation.fetch('start_at'), message
      assert_equal '2026-09-18T16:00:00+09:00', recommendation.fetch('end_at'), message
      assert_includes recommendation.fetch('title'), literal, message
      assert_includes recommendation.fetch('payload').fetch('title'), literal, message
    end
  end

  test 'compact clocks allow whitespace between a date time and activity' do
    ['明日 1320 に会議', '明日 1320 会議'].each do |message|
      assert_single_schedule(message,
                             start_at: '2026-09-18T13:20:00+09:00',
                             end_at: '2026-09-18T14:20:00+09:00')
    end
  end

  test 'a compact reversed range still needs an explicit next-day cue' do
    response = response_for('今日2300から0000まで会議')
    assert_empty response.fetch(:recommendations)
    assert_equal 'rails-local-time-range-validation-v1', response.fetch(:provider)
  end

  test 'existing Japanese clocks keep distinct days in a multiple-schedule request' do
    response = response_for('明日13時20分に会議、明後日15時に打ち合わせ')
    events = response.fetch(:recommendations).flat_map do |recommendation|
      recommendation.dig('payload', 'events') || [recommendation]
    end.sort_by { |event| event.fetch('start_at') }

    assert_equal 2, events.length
    assert_event(events.first, title: '会議',
                 start_at: '2026-09-18T13:20:00+09:00', end_at: '2026-09-18T14:20:00+09:00')
    assert_event(events.last, title: '打ち合わせ',
                 start_at: '2026-09-19T15:00:00+09:00', end_at: '2026-09-19T16:00:00+09:00')
  end
end
