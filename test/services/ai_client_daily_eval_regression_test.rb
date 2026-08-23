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

  def ai_response_with_remote_sentinel(message)
    remote_called = false
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: message)
    client.define_singleton_method(:request_remote) do
      remote_called = true
      {
        assistant_message: 'REMOTE_SENTINEL',
        recommendations: [],
        provider: 'remote-sentinel',
        policy_run: {},
        tool_invocations: []
      }
    end

    [client.call, remote_called]
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

  test 'CF-WEEKDAY-CLOCK-MINUTE-DURATION keeps clock minutes separate from explicit duration' do
    response, remote_called = ai_response_with_remote_sentinel(<<~TEXT)
      予定候補:
      1. 月曜10時30分に45分会議
      2. 火曜11時に1時間設計確認
    TEXT
    recs = recommendations(response)
    meeting = recs.find { |rec| rec.fetch('title') == '会議' }

    refute remote_called
    assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    assert_equal %w[会議 設計確認], recs.map { |rec| rec.fetch('title') }
    assert meeting
    assert_equal Time.iso8601('2026-08-17T10:30:00+09:00'), Time.iso8601(meeting.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-17T11:15:00+09:00'), Time.iso8601(meeting.fetch('end_at'))
    assert_equal 45.minutes, Time.iso8601(meeting.fetch('end_at')) - Time.iso8601(meeting.fetch('start_at'))
    refute_equal 30.minutes, Time.iso8601(meeting.fetch('end_at')) - Time.iso8601(meeting.fetch('start_at'))
  end

  test 'CF-RECURRENCE-CLOCK-MINUTE-DURATION keeps clock minutes separate from explicit duration' do
    response, remote_called = ai_response_with_remote_sentinel('毎週火曜10時30分に会議を45分')
    payload = recommendations(response).sole.fetch('payload')
    events = payload.fetch('events')

    refute remote_called
    assert_equal 'rails-local-weekly-recurrence-v5', response.fetch(:provider)
    assert_equal 'weekly', payload.fetch('recurrence_kind')
    assert_equal 8, events.length
    events.each do |event|
      start_at = Time.iso8601(event.fetch('start_at'))
      end_at = Time.iso8601(event.fetch('end_at'))

      assert_equal 2, start_at.wday
      assert_equal [10, 30], [start_at.hour, start_at.min]
      assert_equal [11, 15], [end_at.hour, end_at.min]
      assert_equal 45.minutes, end_at - start_at
      assert_equal '会議', event.fetch('title')
      refute_equal 30.minutes, end_at - start_at
    end
  end

  test 'CF-WEEKDAY-MULTI-SINGLE-CLAUSE-COMPLETE expands one complete clause for every weekday' do
    response, remote_called = ai_response_with_remote_sentinel('月曜と火曜に10時から会議を1時間入れて')
    recs = recommendations(response)

    refute remote_called
    assert_equal 2, recs.length
    assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    refute_equal 'rails-local-weekday-multi-event-clarification-v1', response.fetch(:provider)
    assert_equal [1, 2], recs.map { |rec| Time.iso8601(rec.fetch('start_at')).wday }
    assert_equal %w[2026-08-17 2026-08-18], recs.map { |rec| Time.iso8601(rec.fetch('start_at')).to_date.iso8601 }
    assert_equal ['会議', '会議'], recs.map { |rec| rec.fetch('title') }
    recs.each do |rec|
      assert_equal [10, 0], [Time.iso8601(rec.fetch('start_at')).hour, Time.iso8601(rec.fetch('start_at')).min]
      assert_equal 60.minutes, Time.iso8601(rec.fetch('end_at')) - Time.iso8601(rec.fetch('start_at'))
    end
  end

  test 'CF-WEEKDAY-ORGANIZATION-PRECEDENCE keeps organization requests ahead of weekday candidates' do
    response, remote_called = ai_response_with_remote_sentinel('月曜に会議、火曜に資料作成、予定が多すぎるので整理したい')

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-schedule-organization-v1', response.fetch(:provider)
    refute_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    refute_includes recommendations(response).map { |rec| rec.fetch('title') }, '会議'
    refute_includes recommendations(response).map { |rec| rec.fetch('title') }, '資料作成'

    strong_response, strong_remote_called = ai_response_with_remote_sentinel(
      '月曜に会議、火曜に資料作成、予定候補も含めて予定が多すぎるので整理したい'
    )

    refute strong_remote_called
    assert_empty recommendations(strong_response)
    assert_equal 'rails-local-schedule-organization-v1', strong_response.fetch(:provider)
  end

  test 'CF-TITLE-INTERPUNCT-PRESERVED keeps an interpunct inside the activity title' do
    response, remote_called = ai_response_with_remote_sentinel('月曜にUI・UX設計')
    recs = recommendations(response)

    refute remote_called
    assert_equal 1, recs.length
    assert_equal 'UI・UX設計', recs.sole.fetch('title')
    refute_equal 'UI', recs.sole.fetch('title')
    assert_includes recs.sole.fetch('title'), '・'
    assert_includes recs.sole.fetch('title'), 'UX設計'

    contextual_response, contextual_remote_called = ai_response_with_remote_sentinel(<<~TEXT)
      予定候補:
      1. 月曜にUI・UX設計
      2. 火曜11時に1時間設計確認
    TEXT
    contextual_titles = recommendations(contextual_response).map { |rec| rec.fetch('title').downcase }

    refute contextual_remote_called
    assert_equal 'rails-local-weekday-multi-event-v1', contextual_response.fetch(:provider)
    assert_equal ['ui・ux設計', '設計確認'], contextual_titles
  end

  test 'CF-MULTI-INTERPUNCT-EXPLICIT-TIMES routes contextually split times as separate events' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時に会議・11時に資料作成')
    recs = recommendations(response)

    refute remote_called
    assert_equal 2, recs.length
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    refute_equal 'rails-local-focus-work-v1', response.fetch(:provider)
    assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
    assert_includes recs.map { |rec| rec.fetch('title') }, '会議'
  end

  test 'CF-MULTI-UNKNOWN-ACTIVITY-INCOMPLETE does not drop an untimed event title' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時に会議、歯医者')

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-multi-explicit-clarification-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '歯医者'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'CF-MULTI-NON-EVENT-HEADER ignores a dated list heading' do
    response, remote_called = ai_response_with_remote_sentinel(<<~TEXT)
      明日の予定候補:
      1. 10時に会議
      2. 11時に資料作成
    TEXT
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
  end

  test 'CF-LIST-JAPANESE-NUMBERED-MARKERS ignores Japanese numbered list markers' do
    response, remote_called = ai_response_with_remote_sentinel(<<~TEXT)
      明日の予定候補:
      1、10時に会議
      2、11時に資料作成
    TEXT
    recs = recommendations(response)
    titles = recs.map { |rec| rec.fetch('title') }

    refute remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    refute_equal 'rails-local-multi-explicit-clarification-v1', response.fetch(:provider)
    assert_equal 2, recs.length
    assert_equal %w[会議 資料作成], titles
    refute_includes titles, '1'
    refute_includes titles, '2'
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
  end

  test 'CF-LIST-INLINE-NUMBERED-MARKERS preserves existing inline list parsing' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1. 10時に会議、2. 11時に資料作成'
    )
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    assert_equal 2, recs.length
    assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
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

  test 'CF-WEEKDAY-MULTI-SINGLE-CLAUSE-INCOMPLETE stays local and asks for content' do
    response, remote_called = ai_response_with_remote_sentinel('月と火に予定を入れて')

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-weekday-multi-event-clarification-v1', response.fetch(:provider)
    refute_equal 'remote-sentinel', response.fetch(:provider)
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

  test 'CF-DATETIME-CLOCK-MINUTE-EXPLICIT-DURATION keeps the duration after a Japanese clock minute' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時30分・45分')
    recommendation = recommendations(response).sole

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal '予定', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-16T10:30:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:15:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal 45.minutes, Time.iso8601(recommendation.fetch('end_at')) - Time.iso8601(recommendation.fetch('start_at'))
  end

  test 'CF-DATETIME-CLOCK-MINUTE-EXPLICIT-DURATION-PARTICLE keeps the duration after a Japanese clock minute' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時30分に45分の予定')
    recommendation = recommendations(response).sole

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal '予定', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-16T10:30:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:15:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal 45.minutes, Time.iso8601(recommendation.fetch('end_at')) - Time.iso8601(recommendation.fetch('start_at'))
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
