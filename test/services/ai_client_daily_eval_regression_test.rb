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

  def ai_response_with_remote_sentinel(message, context: BASE_CONTEXT)
    remote_called = false
    client = Ai::Client.new(context: context, user_message: message)
    client.define_singleton_method(:request_remote) do
      remote_called = true
      raise 'REMOTE_SENTINEL: unexpected remote provider access'
    end

    [client.call, remote_called]
  end

  def recommendations(response)
    response.fetch(:recommendations)
  end

  def assert_positive_recommendation_time_ranges(response, expected_duration_minutes:)
    recommendations(response).each do |recommendation|
      timed_payloads = [recommendation]
      timed_payloads.concat(Array(recommendation.dig('payload', 'events')))

      timed_payloads.each do |payload|
        start_at = Time.iso8601(payload.fetch('start_at'))
        end_at = Time.iso8601(payload.fetch('end_at'))
        duration_minutes = ((end_at - start_at) / 60).to_i

        assert_operator end_at, :>, start_at
        assert_operator duration_minutes, :>, 0
        assert_equal expected_duration_minutes, duration_minutes
        assert_equal expected_duration_minutes.minutes, end_at - start_at
      end
    end
  end

  def assert_weekday_multi_candidate_contract(input, expected_titles:,
                                              expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00])
    assert_no_difference('Event.count', "input=#{input.inspect}") do
      response, remote_called = ai_response_with_remote_sentinel(input)
      recs = recommendations(response)

      refute remote_called, "input=#{input.inspect}"
      assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider), "input=#{input.inspect}"
      assert_equal expected_titles.length, recs.length, "input=#{input.inspect}"
      assert_equal expected_titles, recs.map { |rec| rec.fetch('title') }, "input=#{input.inspect}"
      assert_equal expected_titles, recs.map { |rec| rec.fetch('payload').fetch('title') }, "input=#{input.inspect}"

      recs.zip(expected_starts).each do |recommendation, expected_start|
        payload = recommendation.fetch('payload')
        start_at = Time.iso8601(recommendation.fetch('start_at'))
        end_at = Time.iso8601(recommendation.fetch('end_at'))

        assert_equal Time.iso8601(expected_start), start_at, "input=#{input.inspect}"
        assert_equal start_at, Time.iso8601(payload.fetch('start_at')), "input=#{input.inspect}"
        assert_equal end_at, Time.iso8601(payload.fetch('end_at')), "input=#{input.inspect}"
        assert_operator end_at, :>, start_at, "input=#{input.inspect}"
        assert_operator((end_at - start_at) / 60, :>, 0, "input=#{input.inspect}")
      end

      assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
    end
  end

  def assert_local_summary_contract(input)
    assert_no_difference('Event.count', "input=#{input.inspect}") do
      response, remote_called = ai_response_with_remote_sentinel(input)

      refute remote_called, "input=#{input.inspect}"
      assert_equal 'rails-local-schedule-summary-v1', response.fetch(:provider), "input=#{input.inspect}"
      assert_empty recommendations(response), "input=#{input.inspect}"
      assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
    end
  end

  def assert_local_single_explicit_candidate_contract(input, expected_title:)
    assert_no_difference('Event.count', "input=#{input.inspect}") do
      response, remote_called = ai_response_with_remote_sentinel(input)
      recs = recommendations(response)

      refute remote_called, "input=#{input.inspect}"
      assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider), "input=#{input.inspect}"
      assert_equal 1, recs.length, "input=#{input.inspect}"
      assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"

      recommendation = recs.first
      next unless recommendation

      payload = recommendation.fetch('payload')
      start_at = Time.iso8601(recommendation.fetch('start_at'))
      end_at = Time.iso8601(recommendation.fetch('end_at'))

      assert_equal expected_title, recommendation.fetch('title'), "input=#{input.inspect}"
      assert_equal expected_title, payload.fetch('title'), "input=#{input.inspect}"
      assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), start_at, "input=#{input.inspect}"
      assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), end_at, "input=#{input.inspect}"
      assert_equal start_at, Time.iso8601(payload.fetch('start_at')), "input=#{input.inspect}"
      assert_equal end_at, Time.iso8601(payload.fetch('end_at')), "input=#{input.inspect}"
      assert_operator end_at, :>, start_at, "input=#{input.inspect}"
      assert_operator((end_at - start_at) / 60, :>, 0, "input=#{input.inspect}")
    end
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

  test 'CF-DURATION-ONLY-IS-NOT-START-TIME keeps a weekly hour duration out of the clock parser' do
    response, remote_called = ai_response_with_remote_sentinel('毎週火曜に会議を1時間')
    events = recommendations(response).sole.fetch('payload').fetch('events')

    refute remote_called
    assert_equal 'rails-local-weekly-recurrence-v5', response.fetch(:provider)
    assert_equal 8, events.length
    events.each do |event|
      start_at = Time.iso8601(event.fetch('start_at'))
      end_at = Time.iso8601(event.fetch('end_at'))

      assert_equal 2, start_at.wday
      assert_equal [9, 0], [start_at.hour, start_at.min]
      assert_equal 60.minutes, end_at - start_at
      assert_equal '会議', event.fetch('title')
    end
  end

  test 'CF-DURATION-HOUR-FORMS-ARE-NOT-START-TIMES keeps hour durations out of the clock parser' do
    {
      '毎週火曜に会議を1.5時間' => 90,
      '毎週火曜に会議を2時間' => 120,
      '毎週火曜に会議を1時間半' => 90,
      '毎週火曜に会議を1時間30分' => 90
    }.each do |input, expected_duration|
      response, remote_called = ai_response_with_remote_sentinel(input)
      events = recommendations(response).sole.fetch('payload').fetch('events')

      refute remote_called
      assert_equal 'rails-local-weekly-recurrence-v5', response.fetch(:provider)
      assert_equal 8, events.length
      events.each do |event|
        start_at = Time.iso8601(event.fetch('start_at'))
        end_at = Time.iso8601(event.fetch('end_at'))

        assert_equal 2, start_at.wday
        assert_equal [9, 0], [start_at.hour, start_at.min]
        assert_equal expected_duration.minutes, end_at - start_at
        assert_equal '会議', event.fetch('title')
      end
    end
  end

  test 'CF-PERIOD-WORD-DURATION-IS-NOT-A-CLOCK keeps an afternoon duration at one hour' do
    response, remote_called = ai_response_with_remote_sentinel('毎週火曜に午後1時間の会議')
    events = recommendations(response).sole.fetch('payload').fetch('events')

    refute remote_called
    assert_equal 'rails-local-weekly-recurrence-v5', response.fetch(:provider)
    assert_equal 8, events.length
    events.each do |event|
      start_at = Time.iso8601(event.fetch('start_at'))
      end_at = Time.iso8601(event.fetch('end_at'))

      assert_equal 2, start_at.wday
      assert_equal [9, 0], [start_at.hour, start_at.min]
      assert_equal 60.minutes, end_at - start_at
      assert_equal '会議', event.fetch('title')
    end
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

  test 'CF-WEEKDAY-MULTI-FRAMING keeps request framing out of event titles' do
    [
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って',
      "来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って\n",
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って！',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。保存はしないでください。',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。保存はしないでください！',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。よろしくお願いします。',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。よろしくお願いします！',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。担当者や通知先は設定せず。',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。予定候補だけ整理してください。',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作ってください',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作る',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理して',
      "月曜10時に要件整理、火曜11時に設計確認を予定候補として整理して\n\n",
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理してください。',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理して？',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理してください。保存はしないでください。',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理してください',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理する'
    ].each do |input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)
        recs = recommendations(response)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_equal 2, recs.length, "input=#{input.inspect}"
        assert_equal %w[要件整理 設計確認], recs.map { |rec| rec.fetch('title') }, "input=#{input.inspect}"
        assert_equal Time.iso8601('2026-08-17T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
        assert_equal Time.iso8601('2026-08-17T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
        assert_equal Time.iso8601('2026-08-18T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
        assert_equal Time.iso8601('2026-08-18T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-WEEKDAY-MULTI-FRAMING preserves meaningful title words' do
    [
      [
        '月曜10時に予定候補分析、火曜11時に予定候補整理術を1時間行います',
        %w[予定候補分析 予定候補整理術]
      ],
      [
        '月曜10時に予定候補を作る練習、火曜11時に予定候補として整理する方法を1時間行います',
        ['予定候補を作る練習', '予定候補として整理する方法']
      ],
      [
        '月曜10時に採用面接の予定候補を作る、火曜11時に資料作成を1時間行います',
        ['採用面接の予定候補', '資料作成']
      ],
      [
        '月曜10時に案件を予定候補として整理する、火曜11時に資料作成を1時間行います',
        ['案件を予定候補として整理する', '資料作成']
      ],
      [
        '月曜10時に要件整理、火曜11時に採用面接の予定候補を作る、水曜12時に資料作成を1時間行います',
        ['要件整理', '採用面接の予定候補', '資料作成']
      ],
      [
        'これは架空の議事録です。月曜に要件整理、火曜に設計確認を各30分行います。担当者や通知先は設定せず、予定候補だけ整理してください。保存はしないでください。',
        %w[要件整理 設計確認]
      ],
      [
        '参考メモです。月曜10時に要件整理、火曜11時に設計確認を1時間行います',
        %w[要件整理 設計確認]
      ]
    ].each do |input, expected_titles|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)
        recs = recommendations(response)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_equal expected_titles, recs.map { |rec| rec.fetch('title') }, "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-R13 exact reproductions keep weekday candidates out of summary and framing out of titles' do
    [
      [
        '月曜10時に予定候補レビュー、火曜11時に設計確認',
        %w[予定候補レビュー 設計確認]
      ],
      [
        '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作成してください',
        %w[要件整理 設計確認]
      ],
      [
        '月曜10時に要件整理、火曜11時に設計確認を予定候補としてまとめてください',
        %w[要件整理 設計確認]
      ]
    ].each do |input, expected_titles|
      assert_weekday_multi_candidate_contract(input, expected_titles: expected_titles)
    end
  end

  test 'CF-R13 terminal framing supports the required four-variant matrix' do
    [
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作ってください',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作成してください',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理してください',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補としてまとめてください'
    ].each do |input|
      assert_weekday_multi_candidate_contract(input, expected_titles: %w[要件整理 設計確認])
    end
  end

  test 'CF-R13 terminal framing supports the full semantic allowlist' do
    [
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作ってください',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って下さい',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作る',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作成して',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作成してください',
      '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作成して下さい',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理して',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理してください',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理して下さい',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補として整理する',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補としてまとめて',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補としてまとめてください',
      '月曜10時に要件整理、火曜11時に設計確認を予定候補としてまとめて下さい'
    ].each do |input|
      assert_weekday_multi_candidate_contract(input, expected_titles: %w[要件整理 設計確認])
    end
  end

  test 'CF-R13 terminal framing does not over-strip meaningful title text' do
    [
      [
        '月曜10時に予定候補作成会議、火曜11時に設計確認',
        %w[予定候補作成会議 設計確認]
      ],
      [
        '月曜10時に予定候補を作ってレビュー、火曜11時に設計確認',
        ['予定候補を作ってレビュー', '設計確認']
      ],
      [
        '月曜10時に設計確認を予定候補としてまとめて共有、火曜11時に結果レビュー',
        ['設計確認を予定候補としてまとめて共有', '結果レビュー']
      ],
      [
        '月曜10時に「予定候補を作成して」レビュー、火曜11時に設計確認',
        ['「予定候補を作成して」レビュー', '設計確認']
      ],
      [
        '月曜10時に要件整理、火曜11時に「設計確認の予定候補を作成して」',
        ['要件整理', '「設計確認の予定候補を作成して」']
      ],
      [
        '月曜10時に予定候補として整理する方法、火曜11時に設計確認',
        ['予定候補として整理する方法', '設計確認']
      ],
      [
        '月曜10時に予定候補レビュー、火曜11時に設計確認の後で共有',
        ['予定候補レビュー', '設計確認の後で共有']
      ]
    ].each do |input, expected_titles|
      assert_weekday_multi_candidate_contract(input, expected_titles: expected_titles)
    end
  end

  test 'CF-R13 summary classification preserves concrete weekday event titles containing confirmation words' do
    [
      [
        '月曜10時に予定確認、火曜11時に要件整理',
        %w[予定確認 要件整理]
      ],
      [
        '月曜10時に予定を確認、火曜11時に要件整理',
        ['予定を確認', '要件整理']
      ],
      [
        '月曜10時にスケジュール確認、火曜11時に要件整理の予定候補を作って',
        %w[スケジュール確認 要件整理]
      ],
      [
        '月曜10時に会議、火曜11時に設計確認。水曜10時に設計予定を確認して',
        ['会議', '設計確認', '設計予定を確認'],
        %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00 2026-08-19T10:00:00+09:00]
      ],
      [
        '月曜10時に予定確認、火曜11時に設計確認。水曜10時に業務スケジュールを確認して',
        ['予定確認', '設計確認', '業務スケジュールを確認'],
        %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00 2026-08-19T10:00:00+09:00]
      ]
    ].each do |input, expected_titles, expected_starts|
      assert_weekday_multi_candidate_contract(
        input,
        expected_titles: expected_titles,
        expected_starts: expected_starts || %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00]
      )
    end
  end

  test 'CF-R13 summary and organization classification preserve concrete single event titles' do
    {
      '明日10時に設計予定を確認して' => '設計予定を確認',
      '明日10時に業務スケジュールを確認して' => '業務スケジュールを確認',
      '明日10時に予定整理会議' => '予定整理会議',
      '明日10時に業務スケジュール整理会議' => '業務スケジュール整理会議'
    }.each do |input, expected_title|
      assert_local_single_explicit_candidate_contract(input, expected_title: expected_title)
    end
  end

  test 'CF-R13 clause-scoped summary classification preserves generic summary requests' do
    [
      '来週の予定を確認して',
      '来週の予定を、まとめて教えて',
      "来週の予定を\nまとめて教えて",
      '今週の予定で忙しい日を教えて',
      '明日のスケジュールを教えて',
      '明日の予定は何がある？',
      '月曜と火曜の予定を確認して',
      '月曜10時に要件整理、火曜11時に設計確認の予定候補を作って。来週の予定を確認して',
      '月曜10時に会議、火曜11時に設計確認。水曜10時の予定を確認して',
      '明日10時の予定を、確認して',
      '明日10時の予定について、確認してください',
      '月曜10時に会議、火曜11時に設計確認。水曜10時の予定を、確認して',
      '月曜10時に会議、火曜11時に設計確認。水曜10時の予定について、確認してください',
      '月曜10時に会議、火曜11時に設計確認。水曜10時の予定で、忙しい日を教えて',
      '明日10時の予定を確認して',
      '明日10時のスケジュールを教えて'
    ].each do |input|
      assert_local_summary_contract(input)
    end
  end

  test 'CF-R13 clause-scoped organization classification does not join separate weekday event titles' do
    assert_weekday_multi_candidate_contract(
      '月曜10時に予定レビュー、火曜11時に要件整理',
      expected_titles: %w[予定レビュー 要件整理]
    )

    {
      '今週の予定が多すぎるので整理したい' => 'rails-local-schedule-organization-v1',
      '来週のスケジュールを見直したい' => 'rails-local-schedule-organization-v1',
      '予定を減らしたい' => 'rails-local-schedule-organization-v1',
      '予定の整理をしたい' => 'rails-local-schedule-organization-v1',
      'スケジュールの見直しをしたい' => 'rails-local-schedule-organization-v1'
    }.each do |input, expected_provider|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal expected_provider, response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-WEEKDAY-MULTI-MIXED-CLAUSE does not drop a trailing event' do
    [
      [
        '来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って。明日12時にレビューを1時間入れて',
        'レビュー'
      ],
      [
        '月曜10時に要件整理、火曜11時に設計確認の予定候補を作って。歯医者',
        '歯医者'
      ],
      [
        '明日12時にレビューを1時間入れて。来週月曜10時に要件整理、来週火曜11時に設計確認の予定候補を作って',
        'レビュー'
      ],
      [
        '歯医者。月曜10時に要件整理、火曜11時に設計確認の予定候補を作って',
        '歯医者'
      ],
      [
        '歯医者です。月曜10時に要件整理、火曜11時に設計確認の予定候補を作って',
        '歯医者'
      ]
    ].each do |input, expected_title|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-weekday-multi-event-clarification-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
        assert_includes response.fetch(:assistant_message), '曜日指定', "input=#{input.inspect}"
        assert_includes response.fetch(:assistant_message), expected_title, "input=#{input.inspect}"
        assert_includes response.fetch(:assistant_message), '日付または曜日', "input=#{input.inspect}"
      end
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

  test 'CF-WEEKDAY-DURATION-ONLY-IS-NOT-START-TIME uses title defaults without inventing clocks' do
    response, remote_called = ai_response_with_remote_sentinel(
      '月曜に会議を1時間、火曜に資料作成を1.5時間行います'
    )
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-weekday-multi-event-v1', response.fetch(:provider)
    assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }
    assert_equal Time.iso8601('2026-08-17T09:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-17T10:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-18T10:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-18T11:30:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
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

  test 'CF-TITLE-JAPANESE-COMMA-CONTINUATION-PRESERVED keeps a compound activity as one event' do
    {
      '明日10時にUI、UX設計を1時間' => 'UI、UX設計',
      '明日10時にAPI、DB設計を1時間' => 'API、DB設計'
    }.each do |input, expected_title|
      response, remote_called = ai_response_with_remote_sentinel(input)
      recs = recommendations(response)

      refute remote_called
      assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
      assert_equal 1, recs.length
      assert_equal expected_title, recs.sole.fetch('title')
      assert_includes recs.sole.fetch('title'), '、'
      refute_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
      assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs.sole.fetch('start_at'))
      assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs.sole.fetch('end_at'))
    end

    independent_response, independent_remote_called = ai_response_with_remote_sentinel(
      '明日10時にUI、11時にUX設計'
    )
    independent_recs = recommendations(independent_response)

    refute independent_remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', independent_response.fetch(:provider)
    assert_equal %w[ui ux設計], independent_recs.map { |rec| rec.fetch('title') }
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(independent_recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(independent_recs[1].fetch('start_at'))

    incomplete_response, incomplete_remote_called = ai_response_with_remote_sentinel('明日10時にUI、歯医者')

    refute incomplete_remote_called
    assert_empty recommendations(incomplete_response)
    assert_equal 'rails-local-multi-explicit-clarification-v1', incomplete_response.fetch(:provider)
    assert_includes incomplete_response.fetch(:assistant_message), '歯医者'
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

  test 'CF-MULTI-DURATION-ONLY-CLAUSE-CLARIFIES instead of inventing a second start time' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時に会議、歯医者を1時間')

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-multi-explicit-clarification-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '歯医者'
    assert_includes response.fetch(:assistant_message), '時間'
    refute_includes response.fetch(:assistant_message), '01:00'
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

  test 'CF-LIST-INLINE-JAPANESE-NUMBERED-MARKERS parses a validated inline list' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に会議、2、11時に資料作成'
    )
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

  test 'CF-LIST-INVALID-START-MATRIX rejects completed lists that do not start at one' do
    marker_forms = [['、', ' '], [')', ' '], ['.', ' '], ['．', ' '], ['．', '']]
    invalid_sequences = [[0, 1], [2, 3], [10, 11]]

    invalid_sequences.product(marker_forms, %i[inline newline]).each do |(first_number, second_number), (marker, marker_space), layout|
      input = if layout == :inline
                "明日の予定候補: #{first_number}#{marker}#{marker_space}10時に会議、#{second_number}#{marker}#{marker_space}11時に資料作成"
              else
                <<~TEXT
                  明日の予定候補:
                  #{first_number}#{marker}#{marker_space}10時に会議
                  #{second_number}#{marker}#{marker_space}11時に資料作成
                TEXT
              end

      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-numbered-list-clarification-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
        assert_equal first_number, response.dig(:policy_run, :result_metadata, :item_number), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-LIST-EXPLICIT-CONTINUATION permits a directly bound continuation prefix' do
    [
      '続き: 2、10時に会議、3、11時に資料作成',
      "前回の続き:\n2、10時に会議\n3、11時に資料作成",
      "予定候補の続き:\n2、10時に会議\n3、11時に資料作成",
      "予定一覧の続き:\n2、10時に会議\n3、11時に資料作成",
      "前回の予定候補の続き:\n2、10時に会議\n3、11時に資料作成"
    ].each do |input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)
        recs = recommendations(response)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_equal 2, recs.length, "input=#{input.inspect}"
        assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }, "input=#{input.inspect}"
        assert_equal [10, 11], recs.map { |rec| Time.iso8601(rec.fetch('start_at')).hour }, "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-LIST-CONTINUATION-SCOPE does not authorize an unrelated start number' do
    [
      "明日の予定候補:\n2、10時に会議の続き\n3、11時に資料作成",
      "明日の予定候補:\n2、10時に会議\n3、11時に資料作成\n続き",
      '続きについて確認します。明日の予定候補: 2、10時に会議、3、11時に資料作成',
      "続きについて:\n2、10時に会議\n3、11時に資料作成",
      '続きについて: 2、10時に会議、3、11時に資料作成',
      '前回の続きについて: 2、10時に会議、3、11時に資料作成'
    ].each do |input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-numbered-list-clarification-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
        assert_equal 2, response.dig(:policy_run, :result_metadata, :item_number), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-LIST-DOT-CLOCK-DATE-VALIDATION does not treat a lone invalid date as a list' do
    [
      '明日 13.10時に会議を1時間',
      '明日 99.10時に会議を1時間'
    ].each do |input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-date-validation-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-TITLE-NUMERIC-JAPANESE-COMMAS-PRESERVED keeps proposal numbers in one title' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時に案1、2、3の比較を1時間')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length
    assert_includes recs.sole.fetch('title'), '案1、2、3の比較'
    refute_includes recs.sole.fetch('title'), '案1、3の比較'
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs.sole.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs.sole.fetch('end_at'))
  end

  test 'CF-TITLE-NUMERIC-PARTICIPANT-RANGE-PRESERVED keeps the numeric participant range' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時に1、2名で会議を1時間')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length
    assert_includes recs.sole.fetch('title'), '1、2名で会議'
    refute_match(/\A2名で会議/, recs.sole.fetch('title'))
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs.sole.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs.sole.fetch('end_at'))
  end

  test 'CF-TITLE-NUMERIC-COMMA-REVIEW-PRESERVED keeps numeric review labels in one title' do
    response, remote_called = ai_response_with_remote_sentinel('明日10時に10、20のレビューを1時間')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length
    assert_includes recs.sole.fetch('title'), '10、20のレビュー'
    refute_match(/\A20のレビュー/, recs.sole.fetch('title'))
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs.sole.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs.sole.fetch('end_at'))
  end

  test 'CF-LIST-INVALID-JAPANESE-NUMBERED-MARKERS does not return partial candidates' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に会議、2、'
    )

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-numbered-list-clarification-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '2'
    assert_includes response.fetch(:assistant_message), '内容'
  end

  test 'CF-LIST-SINGLE-MARKER-NO-OP does not rewrite an unvalidated marker' do
    input = '明日10時に予定候補: 1、会議を1時間'
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)

    assert_equal [input], client.send(:split_event_clauses, input)
  end

  test 'CF-LIST-NUMERIC-TITLE-JAPANESE-COMMAS keeps numeric punctuation inside a valid item' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に案1、2、3の比較を1時間、2、11時に会議'
    )
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    assert_equal 2, recs.length
    assert_includes recs[0].fetch('title'), '案1、2、3の比較'
    refute_includes recs[0].fetch('title'), '予定候補'
    assert_equal '会議', recs[1].fetch('title')
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
  end

  test 'CF-LIST-NUMERIC-TITLE-CANDIDATES keeps non-marker numbers in either item' do
    [
      [
        '明日の予定候補: 1、10時に案3、4、5の比較を1時間、2、11時に会議',
        ['案3、4、5の比較', '会議']
      ],
      [
        '明日の予定候補: 1、10時に会議、2、11時に案3、4、5の比較を1時間',
        ['会議', '案3、4、5の比較']
      ],
      [
        '明日の予定候補: 1、10時に案1、2、3のレビューを1時間、2、11時に会議',
        ['案1、2、3のレビュー', '会議']
      ],
      [
        '明日の予定候補: 1、10時に会議、2、11時に案1、2、3のレビューを1時間',
        ['会議', '案1、2、3のレビュー']
      ],
      [
        '明日の予定候補: 1、10時に案10、20、30のレビューを1時間、2、11時に会議',
        ['案10、20、30のレビュー', '会議']
      ],
      [
        '明日の予定候補: 1、10時に案 1、要件 2、仕様の比較を1時間、2、11時に会議',
        ['案 1、要件 2、仕様の比較', '会議']
      ],
      [
        '明日の予定候補: 1、10時に会議、2、11時に案 1、要件 2、仕様の比較を1時間',
        ['会議', '案 1、要件 2、仕様の比較']
      ],
      [
        '明日の予定候補: 1、10時に案1、2、3の比較を1時間、2) 11時に会議',
        ['案1、2、3の比較', '会議']
      ]
    ].each do |input, expected_titles|
      response, remote_called = ai_response_with_remote_sentinel(input)
      recs = recommendations(response)

      refute remote_called
      assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
      assert_equal 2, recs.length
      expected_titles.zip(recs).each do |expected_title, rec|
        assert_includes rec.fetch('title'), expected_title
        refute_includes rec.fetch('title'), '予定候補'
      end
      assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
      assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
      assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
      assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
    end
  end

  test 'CF-LIST-DUPLICATE-MARKERS does not hide an invalid duplicate item' do
    [
      '明日の予定候補: 1、10時に案1、2、11時に会議、2、12時に資料作成',
      '明日の予定候補: 1、10時に案1、2、365レビュー、2、12時に資料作成',
      '明日の予定候補: 1、10時に案1、2、3名で会議、2、12時に資料作成',
      '明日の予定候補: 1、10時に案1、2、3名参加の会議、2、12時に資料作成'
    ].each do |input|
      response, remote_called = ai_response_with_remote_sentinel(input)

      refute remote_called
      assert_empty recommendations(response)
      assert_equal 'rails-local-numbered-list-clarification-v1', response.fetch(:provider)
      assert_includes response.fetch(:assistant_message), '番号'
    end
  end

  test 'CF-LIST-NUMERIC-UNKNOWN-ITEM does not absorb a possible third item' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に会議、2、11時に案2、3、365レビュー'
    )

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-multi-explicit-clarification-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '365レビュー'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'CF-TITLE-SPACED-NUMERIC-JAPANESE-COMMAS does not infer a list from title spacing' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日10時に案 1、要件 2、仕様の比較を1時間'
    )
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length
    assert_includes recs.sole.fetch('title'), '案 1、要件 2、仕様の比較'
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs.sole.fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs.sole.fetch('end_at'))
  end

  test 'CF-LIST-DIGIT-ENDING-TITLE keeps a following validated marker' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に案1、2、11時に会議'
    )
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    assert_equal 2, recs.length
    assert_equal %w[案1 会議], recs.map { |rec| rec.fetch('title') }
    refute_includes recs[0].fetch('title'), '予定候補'
    assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
  end

  test 'CF-LIST-DIGIT-ENDING-TITLE-UNKNOWN keeps an untimed unknown item for clarification' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に案1、2、歯医者'
    )

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-multi-explicit-clarification-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '歯医者'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'CF-LIST-DIGIT-ENDING-NUMERIC-UNKNOWN keeps the sole following marker' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日の予定候補: 1、10時に案1、2、365レビュー'
    )

    refute remote_called
    assert_empty recommendations(response)
    assert_equal 'rails-local-multi-explicit-clarification-v1', response.fetch(:provider)
    assert_includes response.fetch(:assistant_message), '365レビュー'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'CF-LIST-NON-SCHEDULE-NUMBERING does not hijack a general numbered memo' do
    response, remote_called = ai_response_with_remote_sentinel(<<~TEXT)
      メモ:
      1. 要件
      3. 仕様
    TEXT

    refute remote_called
    assert_equal 'rails-local-short-activity-open-slot-v1', response.fetch(:provider)
    refute_equal 'rails-local-numbered-list-clarification-v1', response.fetch(:provider)
    assert_equal 1, recommendations(response).length
  end

  test 'CF-LIST-LEGACY-MARKER-FORMATS preserves parenthesis fullwidth and mixed lists' do
    [
      '明日の予定候補: 1) 10時に会議、2) 11時に資料作成',
      '明日の予定候補: 1． 10時に会議、2． 11時に資料作成',
      '明日の予定候補: 1. 10時に会議、2) 11時に資料作成',
      '明日の予定候補: 1．10時に会議、2．11時に資料作成',
      "明日の予定候補:\n1．10時に会議\n2．11時に資料作成",
      '明日の予定候補: 1．10時に会議、2) 11時に資料作成'
    ].each do |input|
      response, remote_called = ai_response_with_remote_sentinel(input)
      recs = recommendations(response)

      refute remote_called
      assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
      assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }
      assert_equal Time.iso8601('2026-08-16T10:00:00+09:00'), Time.iso8601(recs[0].fetch('start_at'))
      assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[0].fetch('end_at'))
      assert_equal Time.iso8601('2026-08-16T11:00:00+09:00'), Time.iso8601(recs[1].fetch('start_at'))
      assert_equal Time.iso8601('2026-08-16T12:00:00+09:00'), Time.iso8601(recs[1].fetch('end_at'))
    end
  end

  test 'CF-TITLE-HALFWIDTH-INTERPUNCT-PRESERVED normalizes without splitting the title' do
    response, remote_called = ai_response_with_remote_sentinel('月曜にUI･UX設計')
    recs = recommendations(response)

    refute remote_called
    assert_equal 1, recs.length
    assert_equal 'UI・UX設計', recs.sole.fetch('title')
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

  test 'CF-CLOCK-HIRAGANA-HOUR keeps a hiragana clock instead of applying the default' do
    response, remote_called = ai_response_with_remote_sentinel('明日1じに会議を1時間')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length

    recommendation = recs.sole
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal '会議', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-16T01:00:00+09:00'), start_at
    assert_equal Time.iso8601('2026-08-16T02:00:00+09:00'), end_at
    assert_equal 60.minutes, end_at - start_at
    refute_equal Time.iso8601('2026-08-16T09:00:00+09:00'), start_at
    refute_includes response.fetch(:assistant_message), '時間指定がない'
  end

  test 'CF-CLOCK-HIRAGANA-HOUR-MINUTE keeps a hiragana clock minute' do
    response, remote_called = ai_response_with_remote_sentinel('明日1じ30分に会議を1時間')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length

    recommendation = recs.sole
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal '会議', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-16T01:30:00+09:00'), start_at
    assert_equal Time.iso8601('2026-08-16T02:30:00+09:00'), end_at
    assert_equal 60.minutes, end_at - start_at
  end

  test 'CF-CLOCK-KANJI-RANGE keeps a kanji clock range' do
    response, remote_called = ai_response_with_remote_sentinel('明日一時から二時まで会議')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal 1, recs.length

    recommendation = recs.sole
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal '会議', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-08-16T01:00:00+09:00'), start_at
    assert_equal Time.iso8601('2026-08-16T02:00:00+09:00'), end_at
    assert_equal 60.minutes, end_at - start_at
    refute_equal Time.iso8601('2026-08-16T09:00:00+09:00'), start_at
    refute_includes response.fetch(:assistant_message), '時間指定がない'
  end

  test 'CF-OVERNIGHT-RANGE-BOUND-CUES create only positive next-day candidates' do
    {
      '明日23時から翌日1時まで会議' => ['2026-08-16T23:00:00+09:00', '2026-08-17T01:00:00+09:00', 120],
      '明日23時から翌朝1時まで会議' => ['2026-08-16T23:00:00+09:00', '2026-08-17T01:00:00+09:00', 120],
      '明日23:00から翌日01:00まで会議' => ['2026-08-16T23:00:00+09:00', '2026-08-17T01:00:00+09:00', 120],
      '明日午後11時から翌日午前1時まで会議' => ['2026-08-16T23:00:00+09:00', '2026-08-17T01:00:00+09:00', 120],
      '明日23時から1時まで会議(日またぎ)' => ['2026-08-16T23:00:00+09:00', '2026-08-17T01:00:00+09:00', 120],
      '明日23時から1時まで会議（日またぎ）' => ['2026-08-16T23:00:00+09:00', '2026-08-17T01:00:00+09:00', 120],
      '明日午後1時から翌日2時まで会議' => ['2026-08-16T13:00:00+09:00', '2026-08-17T02:00:00+09:00', 780],
      '明日午後1時から2時まで会議(日またぎ)' => ['2026-08-16T13:00:00+09:00', '2026-08-17T02:00:00+09:00', 780],
      '明日13時から14時まで会議' => ['2026-08-16T13:00:00+09:00', '2026-08-16T14:00:00+09:00', 60]
    }.each do |input, (expected_start, expected_end, expected_duration)|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)
        recs = recommendations(response)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider), "input=#{input.inspect}"
        assert_equal 1, recs.length, "input=#{input.inspect}"
        assert_equal '会議', recs.sole.fetch('title'), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"

        start_at = Time.iso8601(recs.sole.fetch('start_at'))
        end_at = Time.iso8601(recs.sole.fetch('end_at'))
        assert_equal Time.iso8601(expected_start), start_at, "input=#{input.inspect}"
        assert_equal Time.iso8601(expected_end), end_at, "input=#{input.inspect}"
        assert_positive_recommendation_time_ranges(response, expected_duration_minutes: expected_duration)
      end
    end
  end

  test 'CF-OVERNIGHT-RANGE-DST keeps the requested next-day wall clock' do
    [
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-03-07T08:00:00-05:00'),
        '2026-03-07T23:00:00-05:00',
        '2026-03-08T03:00:00-04:00',
        180
      ],
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-10-31T08:00:00-04:00'),
        '2026-10-31T23:00:00-04:00',
        '2026-11-01T03:00:00-05:00',
        300
      ]
    ].each do |context, expected_start, expected_end, expected_elapsed_minutes|
      assert_no_difference('Event.count', "context=#{context.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(
          '今日23時から翌日3時まで会議',
          context: context
        )
        recommendation = recommendations(response).sole
        start_at = Time.iso8601(recommendation.fetch('start_at'))
        end_at = Time.iso8601(recommendation.fetch('end_at'))

        refute remote_called
        assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
        assert_equal '会議', recommendation.fetch('title')
        assert_equal Time.iso8601(expected_start), start_at
        assert_equal Time.iso8601(expected_end), end_at
        assert_operator end_at, :>, start_at
        assert_equal expected_elapsed_minutes.minutes, end_at - start_at
        assert_includes response.fetch(:assistant_message), "#{expected_elapsed_minutes}分"
        assert_empty response.fetch(:tool_invocations)
      end
    end

    focus_context = BASE_CONTEXT.merge(
      timezone: 'America/New_York',
      now: '2026-03-07T08:00:00-05:00'
    )
    focus_response, focus_remote_called = ai_response_with_remote_sentinel(
      '今日23時から翌日3時まで集中作業',
      context: focus_context
    )
    focus_event = recommendations(focus_response).sole

    refute focus_remote_called
    assert_equal 'rails-local-focus-work-v1', focus_response.fetch(:provider)
    assert_equal '2026-03-07T23:00:00-05:00', focus_event.fetch('start_at')
    assert_equal '2026-03-08T03:00:00-04:00', focus_event.fetch('end_at')
    assert_includes focus_response.fetch(:assistant_message), '180分枠'
    refute_includes focus_response.fetch(:assistant_message), '240分枠'
  end

  test 'CF-OVERNIGHT-RANGE-DST-RECURRENCE keeps each requested end clock' do
    context = BASE_CONTEXT.merge(
      timezone: 'America/New_York',
      now: '2026-03-07T08:00:00-05:00'
    )

    assert_no_difference('Event.count') do
      response, remote_called = ai_response_with_remote_sentinel(
        '毎週土曜23時から翌日3時まで会議',
        context: context
      )
      events = recommendations(response).sole.fetch('payload').fetch('events')
      first_event = events.first

      refute remote_called
      assert_equal 'rails-local-weekly-recurrence-v5', response.fetch(:provider)
      assert_equal 8, events.length
      assert_equal '2026-03-07T23:00:00-05:00', first_event.fetch('start_at')
      assert_equal '2026-03-08T03:00:00-04:00', first_event.fetch('end_at')
      assert_equal 180.minutes,
                   Time.iso8601(first_event.fetch('end_at')) - Time.iso8601(first_event.fetch('start_at'))
      assert_includes response.fetch(:assistant_message), '23:00-翌日3:00'
      refute_includes response.fetch(:assistant_message), '4時間'
      assert(events.all? do |event|
        start_at = Time.iso8601(event.fetch('start_at'))
        end_at = Time.iso8601(event.fetch('end_at'))
        start_at.hour == 23 && end_at.hour == 3 && end_at > start_at
      end)
      assert_empty response.fetch(:tool_invocations)
    end
  end

  test 'CF-OVERNIGHT-RANGE-DST rejects nonexistent and ambiguous wall clocks without partial candidates' do
    cases = [
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-03-07T08:00:00-05:00'),
        '今日23時から翌日2時30分まで会議'
      ],
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-03-07T08:00:00-05:00'),
        '今日23時から翌日2時30分まで空いている時間に会議'
      ],
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-03-07T08:00:00-05:00'),
        '今日23時から翌日2時30分まで集中作業'
      ],
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-10-31T08:00:00-04:00'),
        '今日23時から翌日1時30分まで会議'
      ],
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-03-07T08:00:00-05:00'),
        '3月8日2時30分から3時まで会議、3月9日10時から11時まで作業、3月10日12時から13時まで確認'
      ],
      [
        BASE_CONTEXT.merge(timezone: 'America/New_York', now: '2026-03-01T08:00:00-05:00'),
        '毎週日曜2時30分から3時まで会議'
      ]
    ]

    cases.each do |context, input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input, context: context)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-time-range-validation-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-OVERNIGHT-RANGE-DST keeps the wall-clock end through travel candidate routes' do
    context = BASE_CONTEXT.merge(
      timezone: 'America/New_York',
      now: '2026-03-07T08:00:00-05:00'
    )

    assert_no_difference('Event.count') do
      response, remote_called = ai_response_with_remote_sentinel(
        '自宅から大阪駅まで30分、今日23時から翌日3時まで会議',
        context: context
      )
      events = recommendations(response).sole.fetch('payload').fetch('events')
      main_event = events.last

      refute remote_called
      assert_equal 'rails-local-travel-assist-bundle-v1', response.fetch(:provider)
      assert_equal '会議', main_event.fetch('title')
      assert_equal '2026-03-07T23:00:00-05:00', main_event.fetch('start_at')
      assert_equal '2026-03-08T03:00:00-04:00', main_event.fetch('end_at')
      assert_empty response.fetch(:tool_invocations)
    end

    saved_route_context = context.merge(
      user_travel_routes: [
        {
          id: 1,
          origin_name: '自宅',
          origin_kind: 'home',
          destination_name: '大阪駅',
          travel_minutes: 30,
          transport_mode: 'train'
        }
      ]
    )

    assert_no_difference('Event.count') do
      response, remote_called = ai_response_with_remote_sentinel(
        '今日23時から翌日3時まで大阪駅で会議',
        context: saved_route_context
      )
      recs = recommendations(response)
      meeting_only = recs.first
      bundled_main = recs.last.fetch('payload').fetch('events').last

      refute remote_called
      assert_equal 'rails-local-saved-travel-memory-v1', response.fetch(:provider)
      assert_equal 2, recs.length
      [meeting_only, bundled_main].each do |event|
        assert_equal '会議', event.fetch('title')
        assert_equal '2026-03-07T23:00:00-05:00', event.fetch('start_at')
        assert_equal '2026-03-08T03:00:00-04:00', event.fetch('end_at')
      end
      assert_empty response.fetch(:tool_invocations)
    end
  end

  test 'CF-OVERNIGHT-RANGE-CLAUSE-SCAN assigns ranges to clauses linearly' do
    input = Array.new(80) { |index| "#{10 + (index % 10)}時から#{11 + (index % 10)}時まで会議#{index}" }.join('。')
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)
    parsed_ranges = client.send(:explicit_time_range_matches, input)
    index_reads = [0]
    counting_range_class = Class.new(Hash) do
      define_method(:initialize) do |counter|
        @counter = counter
        super()
      end

      define_method(:[]) do |key|
        @counter[0] += 1 if %i[start_index end_index].include?(key)
        super(key)
      end
    end
    counted_ranges = parsed_ranges.map do |range|
      counting_range_class.new(index_reads).merge!(range)
    end
    clause_spans = client.send(:time_range_clause_spans, input)

    rebound = client.send(
      :bind_day_crossing_annotations,
      input,
      counted_ranges,
      clause_spans: clause_spans
    )

    assert_equal 80, rebound.length
    assert_operator index_reads.sole, :<, 80 * 8

    same_clause_input = '明日' + Array.new(80) do |index|
      "#{10 + (index % 10)}時から#{11 + (index % 10)}時まで会議#{index}"
    end.join('と')
    date_scan_count = 0
    original_date_parser = client.method(:first_local_date_from_text)
    client.define_singleton_method(:first_local_date_from_text) do |source|
      date_scan_count += 1
      original_date_parser.call(source)
    end

    assert_nil client.send(:invalid_explicit_time_range_match, same_clause_input)
    assert_operator date_scan_count, :<=, 2
  end

  test 'CF-OVERNIGHT-RANGE-UNBOUND-CUES fail closed without partial candidates' do
    [
      '明日23時から1時まで会議',
      '翌日は休み。明日23時から1時まで会議',
      '明日23時から1時まで会議。翌日は休み',
      '明日23時から1時まで会議、翌日の朝は空いている',
      '翌日対応の会議を明日23時から1時まで入れて',
      '明日午後11時から午前1時まで会議',
      '明日23時から23時まで会議',
      '明日23時から1時まで会議。(日またぎ)',
      '明日23時から1時まで会議(日またぎ)を検討',
      '明日22時から23時まで準備と23時から1時まで会議(日またぎ)',
      '明日23時から翌日1時まで会議、翌日2時から3時まで作業',
      '明日23時から翌日1時まで会議、翌日の2時から3時まで作業',
      '明日23時から翌日1時まで会議、翌朝の2時から3時まで作業',
      '明日23時から翌日1時まで会議、翌日の午前2時から3時まで作業'
    ].each do |input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-time-range-validation-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-OVERNIGHT-RANGE-COMPOUND-TITLES preserve Japanese commas inside one event' do
    {
      '明日23時から1時までAPI、DB設計(日またぎ)' => 'API、DB設計',
      '明日23時から1時まで案1、2、3の比較(日またぎ)' => '案1、2、3の比較'
    }.each do |input, expected_title|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)
        rec = recommendations(response).sole

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider), "input=#{input.inspect}"
        assert_equal expected_title, rec.fetch('title'), "input=#{input.inspect}"
        assert_equal Time.iso8601('2026-08-16T23:00:00+09:00'), Time.iso8601(rec.fetch('start_at'))
        assert_equal Time.iso8601('2026-08-17T01:00:00+09:00'), Time.iso8601(rec.fetch('end_at'))
        assert_empty response.fetch(:tool_invocations)
        assert_positive_recommendation_time_ranges(response, expected_duration_minutes: 120)
      end
    end
  end

  test 'CF-MULTI-HIRAGANA-CLOCKS creates two explicit events' do
    response, remote_called = ai_response_with_remote_sentinel(
      '明日1じに会議、2じに資料作成'
    )
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-multi-explicit-events-v1', response.fetch(:provider)
    refute_equal 'rails-local-focus-work-v1', response.fetch(:provider)
    assert_equal 2, recs.length
    assert_equal %w[会議 資料作成], recs.map { |rec| rec.fetch('title') }

    assert_equal Time.iso8601('2026-08-16T01:00:00+09:00'),
                 Time.iso8601(recs[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T02:00:00+09:00'),
                 Time.iso8601(recs[0].fetch('end_at'))
    assert_equal Time.iso8601('2026-08-16T02:00:00+09:00'),
                 Time.iso8601(recs[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-08-16T03:00:00+09:00'),
                 Time.iso8601(recs[1].fetch('end_at'))
    assert_equal 60.minutes,
                 Time.iso8601(recs[0].fetch('end_at')) - Time.iso8601(recs[0].fetch('start_at'))
    assert_equal 60.minutes,
                 Time.iso8601(recs[1].fetch('end_at')) - Time.iso8601(recs[1].fetch('start_at'))
  end

  test 'CF-INVALID-HIRAGANA-CLOCK rejects an invalid hiragana clock' do
    response, remote_called = ai_response_with_remote_sentinel('明日25じに会議を1時間')
    recs = recommendations(response)

    refute remote_called
    assert_equal 'rails-local-time-validation-v1', response.fetch(:provider)
    assert_empty recs
    assert_includes response.fetch(:assistant_message), '25じ'
    refute_includes response.fetch(:assistant_message), '時間指定がない'
  end

  test 'CF-CLOCK-TOKEN-POSITIVE-CONTROLS keeps valid Japanese and colon clock forms' do
    {
      '明日1時に会議を1時間' => ['2026-08-16T01:00:00+09:00', '2026-08-16T02:00:00+09:00'],
      '明日1時30分に会議を1時間' => ['2026-08-16T01:30:00+09:00', '2026-08-16T02:30:00+09:00'],
      '明日1時半に会議を1時間' => ['2026-08-16T01:30:00+09:00', '2026-08-16T02:30:00+09:00'],
      '明日午前1時に会議を1時間' => ['2026-08-16T01:00:00+09:00', '2026-08-16T02:00:00+09:00'],
      '明日午後1時に会議を1時間' => ['2026-08-16T13:00:00+09:00', '2026-08-16T14:00:00+09:00'],
      '明日13時に会議を1時間' => ['2026-08-16T13:00:00+09:00', '2026-08-16T14:00:00+09:00'],
      '明日13時30分に会議を1時間' => ['2026-08-16T13:30:00+09:00', '2026-08-16T14:30:00+09:00'],
      '明日10:30に会議を1時間' => ['2026-08-16T10:30:00+09:00', '2026-08-16T11:30:00+09:00']
    }.each do |input, (expected_start, expected_end)|
      response, remote_called = ai_response_with_remote_sentinel(input)
      recommendation = recommendations(response).sole

      refute remote_called
      assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
      assert_equal '会議', recommendation.fetch('title')
      assert_equal Time.iso8601(expected_start), Time.iso8601(recommendation.fetch('start_at'))
      assert_equal Time.iso8601(expected_end), Time.iso8601(recommendation.fetch('end_at'))
    end
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
