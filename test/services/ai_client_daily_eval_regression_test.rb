# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientDailyEvalRegressionTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-08-15T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  LONG_WEEKDAY_INPUT =
    'EVAL-CF-20260815-LONG 架空の議事録です。月曜に要件整理、火曜に設計確認、水曜に実装レビュー、' \
    '木曜にテスト計画、金曜に振り返りを各30分行います。担当者や通知先は設定せず、' \
    '予定候補だけ整理してください。保存はしないでください。'

  def ai_response(message)
    Ai::Client.call(context: BASE_CONTEXT, user_message: message)
  end

  def recommendations(response)
    response.fetch(:recommendations)
  end

  test 'CF-DATETIME-TODAY creates an unset-content draft from time and duration' do
    response = ai_response('今日18時・30分の予定')
    recommendation = recommendations(response).sole

    assert_equal '予定', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-15T18:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-15T18:30:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal false, recommendation.fetch('all_day')
    assert_includes response.fetch(:assistant_message), '内容'
    assert_match(/未設定|変更/, response.fetch(:assistant_message))
  end

  test 'CF-DATETIME-RELATIVE parses tomorrow time and duration separated by middle dot' do
    response = ai_response('明日15時・30分')
    recommendation = recommendations(response).sole

    assert_equal '予定', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-16T15:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T15:30:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal false, recommendation.fetch('all_day')
  end

  test 'CF-GENERIC-SCHEDULE asks what when and how long without creating a candidate' do
    response = ai_response('予定を入れたい')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '何'
    assert_includes response.fetch(:assistant_message), 'いつ'
    assert_includes response.fetch(:assistant_message), 'どれくらい'
  end

  test 'CF-RECURRENCE-GENERIC creates eight clean weekly generic events' do
    response = ai_response('毎週火曜18時・1時間')
    recommendation = recommendations(response).sole
    payload = recommendation.fetch('payload')
    events = payload.fetch('events')

    assert_equal '予定', events.first.fetch('title')
    assert_equal 'weekly', payload.fetch('recurrence_kind')
    assert_equal 8, events.length
    events.each do |event|
      start_at = Time.iso8601(event.fetch('start_at'))
      end_at = Time.iso8601(event.fetch('end_at'))

      assert_equal 2, start_at.wday
      assert_equal [18, 0], [start_at.hour, start_at.min]
      assert_equal 60.minutes, end_at - start_at
      assert_equal '予定', event.fetch('title')
      refute_match(/入れて|時間を間/, event.fetch('title'))
    end
    assert_includes response.fetch(:assistant_message), '毎週'
    assert_includes response.fetch(:assistant_message), '火曜'
    assert_includes response.fetch(:assistant_message), '18:00'
    assert_includes response.fetch(:assistant_message), '1時間'
    assert_includes response.fetch(:assistant_message), '内容は未設定'
  end

  test 'CF-RECURRENCE-TITLED keeps the explicit activity title' do
    response = ai_response('毎週火曜18時に英語学習を1時間')
    events = recommendations(response).sole.fetch('payload').fetch('events')

    assert_equal 8, events.length
    assert events.all? { |event| event.fetch('title') == '英語学習' }
  end

  test 'CF-RECURRENCE-PARTICIPANT keeps participant and activity separate from time' do
    response = ai_response('毎週火曜18時に田中さんと会議を1時間')
    events = recommendations(response).sole.fetch('payload').fetch('events')

    assert_equal 8, events.length
    assert events.all? { |event| event.fetch('title') == '田中と会議' }
    assert events.all? { |event| event.fetch('participant_names') == ['田中'] }
  end

  test 'CF-LONG splits the evaluated weekday transcript into five candidates' do
    response = ai_response(LONG_WEEKDAY_INPUT)
    recs = recommendations(response)

    assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    assert_equal 5, recs.length
    assert_equal %w[要件整理 設計確認 実装レビュー テスト計画 振り返り], recs.map { |rec| rec.fetch('title') }

    expected_dates = %w[2026-08-17 2026-08-18 2026-08-19 2026-08-20 2026-08-21]
    recs.zip(expected_dates).each do |recommendation, expected_date|
      start_at = Time.iso8601(recommendation.fetch('start_at'))
      end_at = Time.iso8601(recommendation.fetch('end_at'))

      assert_equal expected_date, start_at.to_date.iso8601
      assert_equal [9, 0], [start_at.hour, start_at.min]
      assert_equal 30.minutes, end_at - start_at
      assert_equal false, recommendation.fetch('all_day')
    end
  end

  test 'CF-WEEKDAY-MULTI keeps numbered newline clauses and their own durations' do
    response = ai_response(<<~TEXT)
      予定候補:
      1. 月曜10時に30分要件整理
      2. 火曜11時に1時間設計確認
    TEXT
    recs = recommendations(response)

    assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    assert_equal %w[要件整理 設計確認], recs.map { |rec| rec.fetch('title') }
    assert_equal 30.minutes, Time.iso8601(recs[0].fetch('end_at')) - Time.iso8601(recs[0].fetch('start_at'))
    assert_equal 60.minutes, Time.iso8601(recs[1].fetch('end_at')) - Time.iso8601(recs[1].fetch('start_at'))
  end

  test 'CF-SUMMARY-PRECEDENCE keeps weekday summary requests on the summary route' do
    response = ai_response('月曜は会議、火曜は打ち合わせの予定をまとめて')

    assert_empty recommendations(response)
    assert_equal 'rails-local-schedule-summary-v1', response.fetch(:provider)
  end

  test 'CF-WEEKDAY-INCOMPLETE asks for the missing clause without partial candidates' do
    response = ai_response('月曜に会議、火曜に資料作成、水曜に予定を入れて')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '水曜'
    assert_includes response.fetch(:assistant_message), '内容'
  end

  test 'CF-WEEKDAY-BARE-INCOMPLETE does not discard an unresolved bare weekday clause' do
    response = ai_response('月曜に会議、火曜に資料作成、水に予定を入れて')

    assert_empty recommendations(response)
    refute_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '水'
    assert_includes response.fetch(:assistant_message), '内容'
  end

  test 'CF-DATETIME-MISSING-DURATION asks for duration before creating a generic draft' do
    response = ai_response('明日10時')

    assert_empty recommendations(response)
    assert_match(/所要時間|終了時刻|どれくらい/, response.fetch(:assistant_message))
  end

  test 'CF-DATETIME-CLOCK-MINUTE does not reuse the clock minute as duration' do
    response = ai_response('明日10時30分')

    assert_empty recommendations(response)
    assert_equal 'rails-local-generic-schedule-details-clarification-v1', response.fetch(:provider)
    assert_match(/所要時間|終了時刻|どれくらい/, response.fetch(:assistant_message))
  end

  test 'CF-INVALID rejects an impossible date and time' do
    response = ai_response('5月32日・25時')

    assert_empty recommendations(response)
    assert_match(/存在しない|無効|正しい日付/, response.fetch(:assistant_message))
  end

  test 'CF-UNSAFE requires a concrete delete target' do
    response = ai_response('全予定を削除して')

    assert_empty recommendations(response)
    assert_match(/対象|具体/, response.fetch(:assistant_message))
  end
end
