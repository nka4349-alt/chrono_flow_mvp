# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientSeptemberInputControlsTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-09-14T21:57:59+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  MEETING_EVENT = {
    id: 910,
    title: '会議',
    start_at: '2026-09-15T14:00:00+09:00',
    end_at: '2026-09-15T15:00:00+09:00',
    all_day: false
  }.freeze

  def client_for(message, context: {})
    Ai::Client.new(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def ai_response(message, context: {})
    remote_called = false
    client = client_for(message, context: context)
    client.define_singleton_method(:request_remote) do
      remote_called = true
      raise 'Unexpected remote request in input-control regression'
    end

    response = nil
    assert_no_difference('Event.count', message) { response = client.call }
    refute remote_called, message
    assert_empty response.fetch(:tool_invocations), message
    response
  end

  def events(response)
    response.fetch(:recommendations).flat_map do |recommendation|
      recommendation.dig('payload', 'events') || [recommendation]
    end
  end

  test 'capability words inside a quoted title do not replace a timed schedule with an explanation' do
    ['「非対応操作の対応方法を説明して」', '『非対応操作の対応方法を説明して』', '"非対応操作の対応方法を説明して"'].each do |literal|
      response = ai_response("明日14時から30分の#{literal}の候補をください。")
      recommendation = response.fetch(:recommendations).sole

      refute_equal 'rails-local-capability-explanation-v1', response.fetch(:provider)
      assert_equal '非対応操作の対応方法を説明して', recommendation.fetch('title')
      assert_equal '2026-09-15T14:00:00+09:00', recommendation.fetch('start_at')
      assert_equal '2026-09-15T14:30:00+09:00', recommendation.fetch('end_at')
      assert_equal '非対応操作の対応方法を説明して', recommendation.fetch('payload').fetch('title')
      assert_equal '非対応操作の対応方法を説明して', events(response).sole.fetch('title')
    end
  end

  test 'capability explanation requires a positive request outside literals' do
    client = client_for('')
    [
      '非対応操作の対応方法は説明しないでください。',
      '対応していない機能の説明をしないでください。',
      '非対応操作の対応方法を教えないでください。',
      '「非対応操作の対応方法を説明してください」という文です。'
    ].each do |message|
      assert_nil client.send(:local_capability_explanation_response, message), message
    end
  end

  test 'past words in explicit activity names do not reject a future schedule' do
    ['昨日の資料作成', '先週の集中作業'].each do |title|
      response = ai_response("明日14時から30分の「#{title}」の候補を作ってください。")
      event = events(response).sole

      assert_equal title, event.fetch('title')
      assert_equal '2026-09-15T14:00:00+09:00', event.fetch('start_at')
      assert_equal '2026-09-15T14:30:00+09:00', event.fetch('end_at')
    end
  end

  test 'a timed scheduling request with supplemental explanation is not declared explanation only' do
    client = client_for('')
    [
      '明日14時から30分の会議の候補をください。非対応操作の対応方法も説明してください。',
      '明日14時から30分の会議の候補をください。非対応操作の対応方法は説明しないでください。'
    ].each do |message|
      assert_nil client.send(:local_capability_explanation_response, message), message
    end
  end

  test 'a positive capability explanation stays local and creates no candidates' do
    response = ai_response('対応していない操作の対応方法を日本語で説明してください。候補作成や通知は不要です。')

    assert_equal 'rails-local-capability-explanation-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '対応していない操作'
    refute_match(/通知しました|保存しました|実行しました/, response.fetch(:assistant_message))
  end

  test 'an untimed candidate request is preserved when capability explanation is supplementary' do
    response = ai_response('来週、集中作業の候補をください。対応している機能も説明してください。')

    refute_equal 'rails-local-capability-explanation-v1', response.fetch(:provider)
    refute_empty events(response)
    refute_includes response.fetch(:assistant_message), '今回は説明だけ'
    events(response).each do |event|
      assert_operator Time.iso8601(event.fetch('start_at')), :>=, Time.iso8601('2026-09-21T00:00:00+09:00')
      assert_operator Time.iso8601(event.fetch('end_at')), :<=, Time.iso8601('2026-09-28T00:00:00+09:00')
    end
  end

  test 'a name-first timed clause remains a separate dated event' do
    [
      '名前は「会議」で明日10時から30分、明後日11時から1時間の運動の候補をください。',
      '明日10時から30分の会議。名前は「設計確認」で明後日11時から1時間の候補をください。'
    ].each do |message|
      response = ai_response(message)
      recommendations = events(response).sort_by { |event| event.fetch('start_at') }

      assert_equal 2, recommendations.length, message
      assert_equal ['2026-09-15T10:00:00+09:00', '2026-09-16T11:00:00+09:00'], recommendations.map { |event| event.fetch('start_at') }, message
      assert_equal ['2026-09-15T10:30:00+09:00', '2026-09-16T12:00:00+09:00'], recommendations.map { |event| event.fetch('end_at') }, message
    end
  end

  test 'English scheduling tokens inside explicit titles keep their case and literal meaning' do
    ['「Today Tomorrow 2-hour Review」', '『Today Tomorrow 2-hour Review』', '"Today Tomorrow 2-hour Review"'].each do |literal|
      message = "Please suggest a 20-minute break tomorrow at 14:00. 名前は#{literal}、説明は日本語でお願いします。候補の表示だけを希望します。"
      response = ai_response(message)
      recommendation = response.fetch(:recommendations).sole

      assert_equal 'Today Tomorrow 2-hour Review', recommendation.fetch('title')
      assert_equal 'Today Tomorrow 2-hour Review', recommendation.fetch('payload').fetch('title')
      assert_equal 'Today Tomorrow 2-hour Review', events(response).sole.fetch('title')
      assert_equal '2026-09-15T14:00:00+09:00', recommendation.fetch('start_at')
      assert_equal '2026-09-15T14:20:00+09:00', recommendation.fetch('end_at')
    end
  end

  test 'English day and duration forms outside titles resolve the requested time' do
    {
      'a 20 minute break tomorrow' => ['2026-09-15T14:00:00+09:00', '2026-09-15T14:20:00+09:00'],
      'a 1-hour break day after tomorrow' => ['2026-09-16T14:00:00+09:00', '2026-09-16T15:00:00+09:00']
    }.each do |request, expected|
      response = ai_response("Please suggest #{request} at 14:00. 名前は「Input Review」、説明は日本語でお願いします。候補の表示だけを希望します。")
      recommendation = events(response).sole

      assert_equal 'Input Review', recommendation.fetch('title')
      assert_equal expected, [recommendation.fetch('start_at'), recommendation.fetch('end_at')]
    end
  end

  test 'negative notification controls keep a requested schedule without a reminder' do
    ['通知はしないでください', '保存や通知はしないでください', 'リマインダーは不要です'].each do |control|
      response = ai_response("明日14時から30分の「設計確認」の候補をください。#{control}。")
      recommendation = response.fetch(:recommendations).sole

      refute_match(/reminder/, response.fetch(:provider), control)
      assert_equal 'draft_event', recommendation.fetch('kind'), control
      assert_equal '設計確認', recommendation.fetch('title'), control
      assert_equal '2026-09-15T14:00:00+09:00', recommendation.fetch('start_at'), control
    end
  end

  test 'a positive notification request still returns a reminder candidate' do
    response = ai_response('会議の10分前に通知して', context: { personal_events: [MEETING_EVENT] })
    recommendation = response.fetch(:recommendations).sole

    assert_equal 'event_reminder', recommendation.fetch('kind')
    assert_equal 910, recommendation.fetch('source_event_id')
    assert_equal 10, recommendation.fetch('payload').fetch('minutes_before')
    assert_equal '2026-09-15T13:50:00+09:00', recommendation.fetch('payload').fetch('remind_at')
  end

  test 'a separate negative control does not erase a positive reminder request' do
    [
      '保存はしないでください。会議の10分前に通知して',
      '通知はしないでください。会議の10分前にリマインダーをください。',
      '会議の10分前にリマインダーをください。通知はしないでください。'
    ].each do |message|
      client = client_for(message, context: { personal_events: [MEETING_EVENT] })
      assert client.send(:reminder_request?, message), message
      response = ai_response(message, context: { personal_events: [MEETING_EVENT] })

      assert_match(/reminder/, response.fetch(:provider), message)
      refute_match(/通知しました|保存しました|実行しました/, response.fetch(:assistant_message), message)
    end
  end
end
