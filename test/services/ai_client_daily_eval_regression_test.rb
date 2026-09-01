# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientDailyEvalRegressionTest < ActiveSupport::TestCase
  class SliceCountingString < String
    attr_reader :sliced_character_count

    def initialize(value)
      super(value)
      @sliced_character_count = 0
    end

    def to_s
      self
    end

    def [](*arguments)
      value = super
      range_slice = arguments.length == 1 && arguments.first.is_a?(Range)
      @sliced_character_count += value.length if value && (range_slice || arguments.length == 2)
      value
    end
  end

  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-08-15T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  R16_NEGATIVE_DURATION_SIGNS = ['-', '−', '﹣', '－'].freeze
  R16_VERTICAL_DURATION_GAPS = [
    "\n", "\r\n", "\r", "\v", "\f", "\u0085", "\u2028", "\u2029"
  ].freeze
  R16_MIXED_DURATION_GAPS = [
    " \n", "\n\t", "\r\n　", "\u2028\u00A0", "\u2029\t", "\v ", "　\r\n", "\t\u0085　"
  ].freeze

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

  def assert_zero_candidate_contract(input, expected_provider:, context: BASE_CONTEXT, diagnostic: nil)
    response = nil
    failure_context = [diagnostic, "input=#{input.inspect}"].compact.join(' ')

    assert_no_difference('Event.count', failure_context) do
      response, remote_called = ai_response_with_remote_sentinel(input, context: context)

      refute remote_called, failure_context
      assert_equal expected_provider, response.fetch(:provider), failure_context
      assert_empty recommendations(response), failure_context
      assert_empty response.fetch(:tool_invocations), failure_context
    end

    response
  end

  def r16_duration_case_diagnostic(kind:, sign:, gap:, input:)
    sign_codepoint = sign.codepoints.map { |codepoint| format('U+%04X', codepoint) }.join(' ')
    gap_codepoints = gap.codepoints.map { |codepoint| format('U+%04X', codepoint) }.join(' ')

    "kind=#{kind} sign=#{sign_codepoint} gap=#{gap_codepoints} " \
      "gap_inspect=#{gap.inspect} input=#{input.inspect}"
  end

  def response_string_values(value)
    case value
    when Hash
      value.values.flat_map { |child| response_string_values(child) }
    when Array
      value.flat_map { |child| response_string_values(child) }
    when String
      [value]
    else
      []
    end
  end

  def assert_syntax_clarification_contract(input, expected_error_kind:, context: BASE_CONTEXT)
    response = assert_zero_candidate_contract(
      input,
      expected_provider: 'rails-local-schedule-syntax-clarification-v1',
      context: context
    )
    prompt_snapshot = response.fetch(:policy_run).fetch(:prompt_snapshot)

    assert_equal expected_error_kind,
                 response.dig(:policy_run, :result_metadata, :delimiter_error),
                 "input=#{input.inspect}"
    assert_equal true, prompt_snapshot.fetch(:redacted), "input=#{input.inspect}"
    assert_equal 'home', prompt_snapshot.fetch(:scope), "input=#{input.inspect}"
    refute prompt_snapshot.key?(:user_message), "input=#{input.inspect}"
    refute response_string_values(response).any? { |value| value.include?(input) },
           "raw input leaked into response: #{input.inspect}"

    response
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

  def assert_multi_event_contract(input, expected_provider:, expected_titles:, expected_starts:, expected_durations:)
    assert_equal expected_titles.length, expected_starts.length, "input=#{input.inspect}"
    assert_equal expected_titles.length, expected_durations.length, "input=#{input.inspect}"

    assert_no_difference('Event.count', "input=#{input.inspect}") do
      response, remote_called = ai_response_with_remote_sentinel(input)
      recs = recommendations(response)

      refute remote_called, "input=#{input.inspect}"
      assert_equal expected_provider, response.fetch(:provider), "input=#{input.inspect}"
      assert_equal expected_titles.length, recs.length, "input=#{input.inspect}"
      assert_equal expected_titles, recs.map { |rec| rec.fetch('title') }, "input=#{input.inspect}"
      assert_equal expected_titles, recs.map { |rec| rec.fetch('payload').fetch('title') }, "input=#{input.inspect}"
      assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"

      recs.zip(expected_starts, expected_durations).each do |recommendation, expected_start, expected_duration|
        payload = recommendation.fetch('payload')
        start_at = Time.iso8601(recommendation.fetch('start_at'))
        end_at = Time.iso8601(recommendation.fetch('end_at'))

        assert recommendation.fetch('title').present?, "input=#{input.inspect}"
        assert_equal Time.iso8601(expected_start), start_at, "input=#{input.inspect}"
        assert_equal expected_duration.minutes, end_at - start_at, "input=#{input.inspect}"
        assert_operator end_at, :>, start_at, "input=#{input.inspect}"
        assert_operator((end_at - start_at) / 60, :>, 0, "input=#{input.inspect}")
        assert_equal start_at, Time.iso8601(payload.fetch('start_at')), "input=#{input.inspect}"
        assert_equal end_at, Time.iso8601(payload.fetch('end_at')), "input=#{input.inspect}"
      end

      actual_starts = recs.map { |rec| Time.iso8601(rec.fetch('start_at')) }
      assert_equal expected_starts.uniq.length, actual_starts.uniq.length, "input=#{input.inspect}"
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

  test 'CF-R14 safe period boundaries split independent weekday events' do
    [
      '月曜10時に会議．火曜11時に設計確認の予定候補を作成してください！',
      '月曜10時に会議.火曜11時に設計確認の予定候補を作成してください!',
      '月曜10時に会議 . 火曜11時に設計確認の予定候補を作成してください',
      '月曜10時に会議． 火曜11時に設計確認の予定候補を作成してください'
    ].each do |input|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-weekday-multi-event-v1',
        expected_titles: %w[会議 設計確認],
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R14 safe period boundary scan does not reslice the full text for every dot' do
    source = SliceCountingString.new(('月曜.' * 4_000) + '火曜')
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: source)

    boundaries = client.send(:safe_period_event_boundary_indexes, source)

    assert_equal 4_000, boundaries.length
    assert_operator source.bytesize, :>=, 8_000
    assert_operator source.sliced_character_count, :<=, source.length * 40,
                    "sliced #{source.sliced_character_count} characters for #{source.length}-character input"
  end

  test 'CF-R14 period splitting preserves decimals versions lists and title dots' do
    [
      {
        input: '月曜10時に会議を1.5時間、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: %w[会議 設計確認],
        durations: [90, 60]
      },
      {
        input: '月曜10時に会議を1．5時間、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: %w[会議 設計確認],
        durations: [90, 60]
      },
      {
        input: '月曜10時にAPI v2.0レビュー、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['API v2.0レビュー', '設計確認'],
        durations: [60, 60]
      },
      {
        input: '月曜10時にAPI v 2.0レビュー、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['API v 2.0レビュー', '設計確認'],
        durations: [60, 60]
      },
      {
        input: "予定候補:\n1. 月曜10時に会議\n2. 火曜11時に設計確認",
        provider: 'rails-local-weekday-multi-event-v1',
        titles: %w[会議 設計確認],
        durations: [60, 60]
      },
      {
        input: "予定候補:\n1．月曜10時に会議\n2．火曜11時に設計確認",
        provider: 'rails-local-weekday-multi-event-v1',
        titles: %w[会議 設計確認],
        durations: [60, 60]
      },
      {
        input: '月曜10時に仕様2.0確認、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['仕様2.0確認', '設計確認'],
        durations: [60, 60]
      },
      {
        input: '月曜10時に「仕様.確認」レビュー、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['「仕様.確認」レビュー', '設計確認'],
        durations: [60, 60]
      },
      {
        input: '月曜10時にexample.com確認、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['example.com確認', '設計確認'],
        durations: [60, 60]
      }
    ].each do |test_case|
      assert_multi_event_contract(
        test_case.fetch(:input),
        expected_provider: test_case.fetch(:provider),
        expected_titles: test_case.fetch(:titles),
        expected_starts: test_case.fetch(
          :starts,
          %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00]
        ),
        expected_durations: test_case.fetch(:durations)
      )
    end
  end

  test 'CF-R14 domain title dots protect embedded clocks and weekdays per clause' do
    [
      ['月曜10時にexample.10時.jp確認、火曜11時に設計確認', 'example.10時.jp確認'],
      ['月曜10時にexample.火曜.jp確認、火曜11時に設計確認', 'example.火曜.jp確認']
    ].each do |input, expected_first_title|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: [expected_first_title, '設計確認'],
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R14 abbreviation dots stay in titles while a normal event dot still splits' do
    [
      ['月曜10時にNo.10時版レビュー、火曜11時に設計確認', ['No.10時版レビュー', '設計確認']],
      ['月曜10時にDr.火曜レビュー、火曜11時に設計確認', ['Dr.火曜レビュー', '設計確認']],
      ['月曜10時にU.S.火曜版レビュー、火曜11時に設計確認', ['U.S.火曜版レビュー', '設計確認']],
      ['月曜10時に会議.火曜11時に設計確認', ['会議', '設計確認']]
    ].each do |input, expected_titles|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: expected_titles,
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R14 version title casing is preserved independently in each clause' do
    assert_multi_event_contract(
      '明日10時にAPI v2.0レビュー、11時にapi確認',
      expected_provider: 'rails-local-multi-explicit-events-v1',
      expected_titles: ['API v2.0レビュー', 'api確認'],
      expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
      expected_durations: [60, 60]
    )
  end

  test 'CF-R14 protected title literals keep dots weekdays and clocks intact' do
    [
      ["月曜10時に'仕様.火曜11時版'レビュー、火曜12時に設計確認", ["'仕様.火曜11時版'レビュー", '設計確認']],
      ['月曜10時に（仕様.火曜11時版）レビュー、火曜12時に設計確認', ['(仕様.火曜11時版)レビュー', '設計確認']],
      ['月曜10時に[仕様.火曜11時版]レビュー、火曜12時に設計確認', ['[仕様.火曜11時版]レビュー', '設計確認']],
      ['月曜10時に【仕様.火曜11時版】レビュー、火曜12時に設計確認', ['【仕様.火曜11時版】レビュー', '設計確認']],
      ['月曜10時に「火曜11時.仕様」レビュー、火曜12時に設計確認', ['「火曜11時.仕様」レビュー', '設計確認']],
      ['月曜10時に（火曜11時.仕様）レビュー、火曜12時に設計確認', ['(火曜11時.仕様)レビュー', '設計確認']],
      ['月曜10時に[火曜11時.仕様]レビュー、火曜12時に設計確認', ['[火曜11時.仕様]レビュー', '設計確認']]
    ].each do |input, expected_titles|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: expected_titles,
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T12:00:00+09:00],
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R14 protected title anchors stay literal with framing and action suffixes' do
    [
      [
        '月曜10時に「火曜11時.仕様」レビュー、火曜12時に設計確認の予定候補を作って',
        ['「火曜11時.仕様」レビュー', '設計確認']
      ],
      [
        '月曜10時に（火曜11時.仕様）レビュー、火曜12時に設計確認の予定候補を作って',
        ['(火曜11時.仕様)レビュー', '設計確認']
      ],
      [
        '月曜10時に「火曜11時.仕様」レビュー、火曜12時に設計確認を1時間行います',
        ['「火曜11時.仕様」レビュー', '設計確認']
      ]
    ].each do |input, expected_titles|
      assert_weekday_multi_candidate_contract(
        input,
        expected_titles: expected_titles,
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T12:00:00+09:00]
      )
    end
  end

  test 'CF-R14 unmatched closing containers fail closed before a period anchor' do
    [
      '月曜10時に仕様.火曜11時版」レビュー、火曜12時に設計確認',
      '月曜10時に仕様.火曜11時版）レビュー、火曜12時に設計確認',
      '月曜10時に仕様.火曜11時版]レビュー、火曜12時に設計確認',
      '月曜10時に仕様.火曜11時版】レビュー、火曜12時に設計確認'
    ].each do |input|
      assert_syntax_clarification_contract(input, expected_error_kind: :unmatched_closing)
    end
  end

  test 'CF-R14 weekday parenthetical timing metadata drives timing but not titles' do
    [
      {
        input: '月曜10時に会議（30分）、火曜11時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [30, 60]
      },
      {
        input: '月曜10時に会議（所要30分）、火曜11時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [30, 60]
      },
      {
        input: '月曜10時に会議（所要時間30分）、火曜11時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [30, 60]
      },
      {
        input: '月曜10時に会議（1時間30分）、火曜12時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T12:00:00+09:00],
        durations: [90, 60]
      },
      {
        input: '月曜に会議（10時から11時）、火曜12時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T12:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '月曜10時に会議【30分】、火曜11時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [30, 60]
      },
      {
        input: '月曜に会議［10時から11時］、火曜12時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T12:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '月曜に会議[10時から11時]、火曜12時に設計確認の予定候補を作って',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T12:00:00+09:00],
        durations: [60, 60]
      }
    ].each do |test_case|
      assert_multi_event_contract(
        test_case.fetch(:input),
        expected_provider: 'rails-local-weekday-multi-event-v1',
        expected_titles: %w[会議 設計確認],
        expected_starts: test_case.fetch(:starts),
        expected_durations: test_case.fetch(:durations)
      )
    end
  end

  test 'CF-R14 grouped timing metadata does not consume semantic parenthetical text' do
    assert_multi_event_contract(
      '月曜10時に会議（所要時間レビュー）、火曜11時に設計確認の予定候補を作って',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: ['会議(所要時間レビュー)', '設計確認'],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
      expected_durations: [60, 60]
    )
  end

  test 'CF-R14 grouped overnight range matches direct overnight syntax' do
    [
      '月曜に監視作業（23時から翌日1時まで）、火曜12時に設計確認の予定候補を作って',
      '月曜23時から翌日1時まで監視作業、火曜12時に設計確認の予定候補を作って'
    ].each do |input|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-weekday-multi-event-v1',
        expected_titles: %w[監視作業 設計確認],
        expected_starts: %w[2026-08-17T23:00:00+09:00 2026-08-18T12:00:00+09:00],
        expected_durations: [120, 60]
      )
    end
  end

  test 'CF-R14 terminal framing is shared by same-weekday and generic multi-event routes' do
    [
      'の予定候補を作って',
      'の予定候補を作ってください',
      'の予定候補を作って下さい',
      'の予定候補を作る',
      'の予定候補を作成して',
      'の予定候補を作成してください',
      'の予定候補を作成して下さい',
      'を予定候補として整理して',
      'を予定候補として整理してください',
      'を予定候補として整理して下さい',
      'を予定候補として整理する',
      'を予定候補としてまとめて',
      'を予定候補としてまとめてください',
      'を予定候補としてまとめて下さい',
      'を予定候補としてまとめる'
    ].each do |suffix|
      assert_multi_event_contract(
        "月曜10時に会議、月曜11時に資料作成#{suffix}",
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: %w[会議 資料作成],
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-17T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end

    [
      [
        '明日10時に会議、11時に資料作成の予定候補を作成してください',
        %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      ],
      [
        '明日10時に会議、明後日11時に資料作成の予定候補を作成してください',
        %w[2026-08-16T10:00:00+09:00 2026-08-17T11:00:00+09:00]
      ],
      [
        '月曜10時に会議、月曜11時に資料作成の予定候補を作成してください。保存はしないでください。',
        %w[2026-08-17T10:00:00+09:00 2026-08-17T11:00:00+09:00]
      ],
      [
        '保存はしないでください。明日10時に会議、11時に資料作成の予定候補を作成してください',
        %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      ]
    ].each do |input, expected_starts|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: %w[会議 資料作成],
        expected_starts: expected_starts,
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R14 multi-event execution actions are not event titles' do
    [
      ['明日10時に会議、11時に資料作成を1時間行います', 60],
      ['明日10時に会議、11時に資料作成を1時間行う', 60],
      ['明日10時に会議、11時に資料作成を30分実施します', 30],
      ['明日10時に会議、11時に資料作成を30分実施する', 30],
      ['明日10時に会議、11時に資料作成を行います', 60],
      ['明日10時に会議、11時に資料作成を実施します', 60],
      ['明日10時に会議、11時に資料作成を各30分行います', 30],
      ['明日10時に会議、11時に資料作成予定です', 60]
    ].each do |input, second_duration|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: %w[会議 資料作成],
        expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
        expected_durations: [60, second_duration]
      )
    end
  end

  test 'CF-R14 multi-event title cleanup does not over-strip meaningful or quoted text' do
    [
      ['明日10時に会議、11時に実施計画レビュー', %w[会議 実施計画レビュー]],
      ['明日10時に会議、11時に作業を行う方法の確認', ['会議', '作業を行う方法の確認']],
      ['明日10時に会議、11時に実施しますレビュー', %w[会議 実施しますレビュー]],
      ['明日10時に会議、11時に「1時間行います」説明会', ['会議', '「1時間行います」説明会']],
      ['明日10時に会議、11時に（1時間行います）説明会', ['会議', '(1時間行います)説明会']],
      ['月曜10時に予定候補作成会議、月曜11時に設計確認', %w[予定候補作成会議 設計確認]],
      [
        '月曜10時に設計確認を予定候補としてまとめて共有、月曜11時に結果レビュー',
        ['設計確認を予定候補としてまとめて共有', '結果レビュー']
      ],
      [
        '月曜10時に「予定候補を作成してください」レビュー、月曜11時に設計確認',
        ['「予定候補を作成してください」レビュー', '設計確認']
      ]
    ].each do |input, expected_titles|
      expected_date = input.start_with?('明日') ? '2026-08-16' : '2026-08-17'
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: expected_titles,
        expected_starts: ["#{expected_date}T10:00:00+09:00", "#{expected_date}T11:00:00+09:00"],
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R14 multi-anchor clauses expand one shared clock or fail closed' do
    assert_multi_event_contract(
      '月曜と火曜の10時に会議',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: %w[会議 会議],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
      expected_durations: [60, 60]
    )

    [
      '月曜10時に会議 火曜11時に設計確認の予定候補を作って',
      '月曜と火曜の10時から11時から12時まで会議',
      '月曜と火曜の10時-11時-12時に会議'
    ].each do |input|
      assert_no_difference('Event.count', "input=#{input.inspect}") do
        response, remote_called = ai_response_with_remote_sentinel(input)

        refute remote_called, "input=#{input.inspect}"
        assert_equal 'rails-local-weekday-multi-event-clarification-v1', response.fetch(:provider), "input=#{input.inspect}"
        assert_empty recommendations(response), "input=#{input.inspect}"
        assert_empty response.fetch(:tool_invocations), "input=#{input.inspect}"
      end
    end
  end

  test 'CF-R15 unmatched opening delimiters reject the complete request' do
    ['「', '『', '“', '‘', '"', "'", '（', '(', '［', '[', '【'].each do |opening|
      input = "月曜10時に会議#{opening}仕様.火曜11時に設計確認"

      assert_syntax_clarification_contract(input, expected_error_kind: :unmatched_opening)
    end
  end

  test 'CF-R15 unmatched asymmetric closings reject the complete request' do
    ['」', '』', '”', '’', '）', ')', '］', ']', '】'].each do |closing|
      input = "月曜10時に会議#{closing}仕様.火曜11時に設計確認"

      assert_syntax_clarification_contract(input, expected_error_kind: :unmatched_closing)
    end
  end

  test 'CF-R15 mismatched delimiters reject the complete request' do
    [
      '「仕様）',
      '（仕様」',
      '【仕様]',
      '[仕様）',
      '"仕様「詳細"確認」',
      '「仕様 7)」'
    ].each do |malformed_fragment|
      input = "月曜10時に会議#{malformed_fragment}.火曜11時に設計確認"

      assert_syntax_clarification_contract(input, expected_error_kind: :mismatched_closing)
    end

    assert_syntax_clarification_contract(
      '明日の予定候補: 1) 10時に「仕様 7)」会議、2) 11時に資料作成',
      expected_error_kind: :mismatched_closing
    )
  end

  test 'CF-R15 invalid explicit dates with delimiter errors use redacted syntax clarification' do
    [
      '2/30【', '4/31「', '0/10[', '2.30【', '4．31「', '2026年2月30日『',
      '日付は2.30【', '開始日は4．31「', '締切は2.30【', '予約日は2.30【', '提出日は4．31「',
      '締め切り日は2.30【', '締切り日は2.30【', '誕生日は2.30【',
      '予約は2.30【', '提出は4.31「', '開催は2.30【', '締切の2.30【'
    ].each do |input|
      assert_syntax_clarification_contract(input, expected_error_kind: :unmatched_opening)
    end

    [
      '締切は2.30', '予約日は2.30', '提出日は4．31',
      '締め切り日は2.30', '締切り日は2.30', '誕生日は2.30',
      '予約は2.30', '提出は4.31', '開催は2.30', '締切の2.30'
    ].each do |input|
      assert_zero_candidate_contract(input, expected_provider: 'rails-local-date-validation-v1')
    end

    ['本日は4.31版をレビュー', '休日は2.30版を確認', '曜日は2.30という値'].each do |input|
      client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)

      refute client.send(:explicit_date_syntax_present?, input), "input=#{input.inspect}"
      assert_nil client.send(:invalid_explicit_date_match, input), "input=#{input.inspect}"
    end
  end

  test 'CF-R15 balanced delimiters preserve protected title semantics' do
    [
      ['月曜10時に「仕様.確認」レビュー、火曜11時に設計確認', ['「仕様.確認」レビュー', '設計確認']],
      ['月曜10時に（仕様.確認）レビュー、火曜11時に設計確認', ['(仕様.確認)レビュー', '設計確認']],
      ['月曜10時に【仕様.確認】レビュー、火曜11時に設計確認', ['【仕様.確認】レビュー', '設計確認']],
      [
        '月曜10時に「仕様（API v2.0）確認」レビュー、火曜11時に設計確認',
        ['「仕様(API v2.0)確認」レビュー', '設計確認']
      ],
      ["月曜10時にJohn's review、火曜11時に設計確認", ["john's review", '設計確認']],
      ["月曜10時にcafé's review、火曜11時に設計確認", ["café's review", '設計確認']],
      ["月曜10時に会社's review、火曜11時に設計確認", ["会社's review", '設計確認']],
      ["月曜10時にabc'１２３ review、火曜11時に設計確認", ["abc'123 review", '設計確認']],
      [
        '月曜10時にversion 4.31レビュー、火曜11時に仕様v2.30確認',
        ['version 4.31レビュー', '仕様v2.30確認']
      ],
      ['月曜10時にver 4.31レビュー、火曜11時に設計確認', ['ver 4.31レビュー', '設計確認']],
      ['月曜10時にv 2.30レビュー、火曜11時に設計確認', ['v 2.30レビュー', '設計確認']],
      [
        '月曜10時に会議（Phase 1）、火曜11時に設計確認（Phase 2）',
        ['会議(Phase 1)', '設計確認(Phase 2)']
      ]
    ].each do |input, expected_titles|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: expected_titles,
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end

    assert_multi_event_contract(
      '明日10時に予定候補(Phase 1)、11時に資料作成',
      expected_provider: 'rails-local-multi-explicit-events-v1',
      expected_titles: ['予定候補(Phase 1)', '資料作成'],
      expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
      expected_durations: [60, 60]
    )

    assert_multi_event_contract(
      '月曜10時に予定候補（Phase 1）、火曜11時に資料作成',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: ['予定候補(Phase 1)', '資料作成'],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
      expected_durations: [60, 90]
    )
  end

  test 'CF-R15 delimiter scanner remains centralized linear and schedule scoped' do
    source = SliceCountingString.new(
      500.times.map { |index| "月曜10時に「仕様(API v2.0)-#{index}」レビュー" }.join('。')
    )
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: source)

    assert_no_difference('Event.count') do
      scan = client.send(:scan_protected_text_delimiters, source)

      assert_nil scan.fetch(:error)
      assert_equal 500, scan.fetch(:spans).length
      assert_equal 0, source.sliced_character_count
    end

    numeric_marker_source = SliceCountingString.new(
      500.times.map { |index| "月曜10時に会議 #{index % 10})仕様#{index}" }.join('、')
    )
    numeric_marker_scan = client.send(:scan_protected_text_delimiters, numeric_marker_source)

    assert_equal :unmatched_closing, numeric_marker_scan.dig(:error, :kind)
    assert_operator numeric_marker_source.sliced_character_count, :<=, numeric_marker_source.length * 2

    ['v2．30', 'docs．example．com', 'U．S．A．', 'docs․example․com'].each do |source_with_compatible_period|
      compatible_scan = client.send(:scan_protected_text_delimiters, source_with_compatible_period)
      compatible_boundaries = client.send(
        :schedule_syntax_safe_boundaries,
        source_with_compatible_period,
        delimiter_scan: compatible_scan
      )

      assert_nil compatible_scan.fetch(:error), "source=#{source_with_compatible_period.inspect}"
      assert_empty compatible_boundaries, "source=#{source_with_compatible_period.inspect}"
    end

    [
      'この文章「を確認', 'ファイル（を削除', '仕様v2.30【', 'version 4.31「',
      '日付変更線【を説明して', '時刻表「を確認して', '日時計【について教えて',
      '設定【を変更して', '画像「を追加して',
      '資料【を削除して', '資料「を確認して', 'メモ（を削除して',
      '美容院【の写真を見て', '病院「の歴史を教えて', '試験（という単語の意味',
      '予約【という言葉', '会食「の写真を整理', '歯医者【の口コミを検索',
      '映画を見た。設定【を変更して',
      '映画の感想を書いた。その後ファイル【を削除して',
      '読書を終えた。画像「を追加して'
    ].each do |input|
      nonschedule_client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)

      refute nonschedule_client.send(:schedule_like_syntax_input?, input), "input=#{input.inspect}"
      assert_nil nonschedule_client.send(:local_schedule_syntax_clarification_response, input),
                 "input=#{input.inspect}"
      assert_nil nonschedule_client.send(:local_structured_schedule_response),
                 "local candidate route accepted malformed ordinary text: #{input.inspect}"
    end

    [
      '月曜10時に会議 7)仕様、火曜11時に設計 9)確認',
      '月曜10時に会議。1) 火曜11時に設計。3) 水曜12時に確認',
      '月曜10時に手続き 1)仕様.火曜11時に設計確認 2)',
      '月曜10時に未予定候補 1)仕様.火曜11時に設計確認 2)',
      '１．２時間 月曜10時に会議 7)仕様、火曜11時に設計 9)確認',
      "(Phase\n1) 明日10時に会議 7)仕様 9)確認",
      '明日の予定候補: 1) 10時に(会議、2) 11時に資料作成',
      '明日の予定候補: 1）10時に（会議、2）11時に資料作成',
      "明日の予定候補:\n1) 10時に(会議\n2) 11時に資料作成",
      '明日の予定候補: 1) 10時に(会議 2) 11時に資料作成',
      '明日の予定候補: 1）10時に（会議　2）11時に資料作成',
      '明日の予定候補: 1) 10時に(会議 2) 資料作成',
      '明日の予定候補: 1) 10時に(会議 2) 資料作成を11時に',
      '明日の予定候補: 1) 10時に(会議 2) 会議を11時に',
      '明日の予定候補: 1) 10時に(会議 2) 午後に資料作成',
      '明日の予定候補: 1) 明日に(会議 2) 資料作成',
      '明日の予定候補: 1) 明日(会議 2) 資料作成',
      '明日の予定候補: 1) 月曜に(会議 2) 火曜に資料作成',
      '明日の予定候補: 1) 8/20に(会議 2) 8/21に資料作成',
      '明日の予定候補: 1) 午前に(会議 2) 午後に資料作成',
      '明日の予定候補: 1) 次の月曜に(会議 2) 火曜に資料作成',
      '明日の予定候補: 1) 2026年8月20日に(会議 2) 8月21日に資料作成',
      '明日の予定候補: 1) 20日に(会議 2) 21日に資料作成',
      '明日の予定候補: 1) 正午に(会議 2) 午後に資料作成',
      '明日の予定候補: 1) 3日後に(会議 2) 4日後に資料作成',
      '明日の予定候補: 1) 来月頭に(会議 2) 来月に資料作成',
      '明日の予定候補: 1) 昨日に(会議 2) 今日に資料作成',
      '明日の予定候補: 1) きのうに(会議 2) 今日に資料作成',
      '明日の予定候補: 1) 一昨日に(会議 2) 今日に資料作成',
      '明日の予定候補: 1) おとといに(会議 2) 今日に資料作成',
      '明日の予定候補: 1) 先週に(会議 2) 今週に資料作成',
      '明日の予定候補: 1) 週末に(旅行 2) 資料作成',
      '明日の予定候補: 1) 今週末に(旅行 2) 資料作成',
      '明日の予定候補: 1) 来週末に(旅行 2) 資料作成',
      '明日の予定候補: 1) 土日に(旅行 2) 資料作成',
      '明日の予定候補: 1) 来週の土日に(旅行 2) 資料作成',
      '明日の予定候補: 1) 10時頃に(会議 2) 11時に資料作成',
      '明日の予定候補: 1) 月曜の(会議 2) 火曜に資料作成',
      '明日の予定候補: 1) 今週中に(会議 2) 来週に資料作成',
      "明日の予定候補:\n1) 会議(詳細\n2) 資料作成",
      "明日の予定候補:\n1) 会議(\n2) 資料作成",
      "明日の予定候補:\n1) 会議(詳細\n3) 資料作成",
      "明日の予定候補:\n1) 会議(詳細\n2) 資料作成\n2) 電話",
      "明日の予定候補:\n1) 会議(詳細\n4) 資料作成\n4) 電話",
      '明日の予定候補: 1) 会議(詳細 2) 資料作成',
      '明日の予定候補: 1) 会議(詳細、2)資料作成',
      '明日の予定候補: 1) 会議(詳細,2)資料作成',
      '明日の予定候補: 1）会議（詳細、2）資料作成',
      '明日の予定候補: 1) 会議(詳細 2)11時に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)週末に旅行',
      '明日の予定候補: 1) 会議(詳細 2)昨日に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)今週中に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)終日に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)毎週月曜に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)明日11時に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)明日11時に会議',
      '明日の予定候補: 1) 会議(詳細 2)月曜にレビュー',
      '明日の予定候補: 1) 会議(詳細 2)明日正午に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)明日午後に会議',
      '明日の予定候補: 1) 会議(詳細 2)月曜午後にレビュー',
      '明日の予定候補: 1) 会議(詳細 2)明日朝に資料作成',
      '明日の予定候補: 1) 会議(詳細 2)来週末午後に会議',
      '明日の予定候補: 1) 会議(詳細 2)明日終日会議',
      '明日の予定候補: 1) 会議(詳細 2)明日午後会議',
      '明日の予定候補: 1) 会議(詳細 2)月曜午前会議',
      '明日の予定候補: 1) 会議(詳細 2)月曜朝イチ会議',
      '明日の予定候補: 1) 会議(詳細 2)来週末夕方会議',
      '明日の予定候補: 1) 会議(詳細 2)来月頭午後会議',
      '明日の予定候補: 1) 会議(詳細 2)来月頭午後に会議',
      '明日の予定候補: 1) 会議(詳細 2)来月頭正午に会議',
      '明日の予定候補: 1) 会議(詳細、2)明日11時に資料作成',
      '明日の予定候補: 1）会議（詳細、2）明日11時に資料作成',
      *[
        "\u00A0", "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005",
        "\u2006", "\u2007", "\u2008", "\u2009", "\u200A", "\u202F", "\u205F"
      ].map { |space| "明日の予定候補: 1) 会議(詳細#{space}2)#{space}資料作成" },
      "明日の予定候補: 1) 会議(詳細 2)#{' ' * 513}資料作成",
      "明日の予定候補: 1) 会議(詳細\u00A02)#{"\u00A0" * 513}資料作成",
      '1) 10時に(会議、2) 11時に資料作成',
      '1) 10時に(会議 2) 11時に資料作成'
    ].each do |input|
      expected_error_kind = input.match?(/[（(](?:会議|旅行|詳細|\r?\n)/) ?
                              :unmatched_opening :
                              :unmatched_closing
      assert_syntax_clarification_contract(input, expected_error_kind: expected_error_kind)
    end

    [
      '明日の予定候補: 1) 「会議(詳細、2) 資料作成」',
      '明日の予定候補: 1) 「会議(仕様、2) 資料作成」',
      '明日の予定候補: 1) 【会議(詳細、2) 資料作成】',
      '明日の予定候補: 1）「会議（詳細、2） 資料作成」'
    ].each do |input|
      assert_syntax_clarification_contract(input, expected_error_kind: :mismatched_closing)
    end
  end

  test 'CF-R15 schedule action delimiter errors fail closed before mutation and candidate routes' do
    cases = {
      '予約【を変更して' => :unmatched_opening,
      '予約「をキャンセルして' => :unmatched_opening,
      '予約）を確認して' => :unmatched_closing,
      '会食【を追加して' => :unmatched_opening,
      '予約【を教えて' => :unmatched_opening,
      '予約して「' => :unmatched_opening,
      '歯医者を予約【して' => :unmatched_opening,
      '美容院を予約「する' => :unmatched_opening,
      '会食を予約【' => :unmatched_opening,
      '予定【を教えて。その後設定を変更して' => :unmatched_opening,
      'カレンダー「を見せて。画像を追加して' => :unmatched_opening,
      '日程【をまとめて、設定を変更して' => :unmatched_opening,
      '変更管理会議【' => :unmatched_opening,
      '確認会議【' => :unmatched_opening,
      '会議「仕様.確認【' => :unmatched_opening,
      '会議「仕様。確認【' => :unmatched_opening,
      '予定『概要、詳細【' => :unmatched_opening,
      'カレンダー（表示;設定【' => :unmatched_opening,
      '会議「仕様.確認」】' => :unmatched_closing,
      '会議（仕様。確認）】' => :unmatched_closing,
      '予定『概要、詳細』）' => :unmatched_closing,
      'カレンダー（表示;設定）]' => :unmatched_closing,
      '会議「仕様.確認」【' => :unmatched_opening,
      '予定『概要、詳細』（' => :unmatched_opening,
      'カレンダー（表示;設定）「' => :unmatched_opening,
      '会議「仕様.確認」【詳細）' => :mismatched_closing,
      '会議docs.example.com【' => :unmatched_opening,
      '会議U.S.A.【' => :unmatched_opening,
      '予定API.example【' => :unmatched_opening,
      'カレンダーexample.co.jp「' => :unmatched_opening,
      '映画docs.example.com【を追加して' => :unmatched_opening,
      '予約「API.v2」】を確認して' => :unmatched_closing,
      '読書U.S.A.【を追加して' => :unmatched_opening,
      '会食（docs.example.com）】を変更して' => :unmatched_closing,
      '】「仕様.会議」' => :unmatched_closing,
      '）『概要、予定』' => :unmatched_closing,
      ']（表示;カレンダー）' => :unmatched_closing,
      '】"API.v2.会議"' => :unmatched_closing
    }
    cases.each do |input, expected_error_kind|
      assert_syntax_clarification_contract(input, expected_error_kind: expected_error_kind)
    end

    {
      'ファイル）を確認。会議' => :unmatched_closing,
      '設定】を変更。予約' => :unmatched_closing,
      '文章］を読む。映画' => :unmatched_closing,
      '画像』を削除。読書' => :unmatched_closing,
      '会議。ファイル）を確認' => :unmatched_closing,
      '予約。設定】を変更' => :unmatched_closing,
      'ファイル）を確認。チーム会議' => :unmatched_closing,
      '設定】を変更。歯医者' => :unmatched_closing,
      'ファイル）を確認。「仕様.会議」' => :unmatched_closing,
      'ファイル）を確認。会議です' => :unmatched_closing,
      '文章］を読む。読書です' => :unmatched_closing,
      'ファイル）を確認。会議だ' => :unmatched_closing,
      'ファイル）を確認。会議でした' => :unmatched_closing,
      '設定】を変更。予約です' => :unmatched_closing,
      'ファイル）を確認。会議になります' => :unmatched_closing,
      'ファイル）を確認。会議になりました' => :unmatched_closing,
      'ファイル）を確認。電話' => :unmatched_closing,
      'ファイル）を確認。資料作成' => :unmatched_closing,
      'ファイル）を確認。メモ整理' => :unmatched_closing,
      'ファイル）を確認。作業' => :unmatched_closing,
      'ファイル）を確認。レビュー' => :unmatched_closing,
      'ファイル）を確認。飲み会' => :unmatched_closing,
      'ファイル）を確認。飲み' => :unmatched_closing,
      'ファイル）を確認。食事' => :unmatched_closing,
      'ファイル）を確認。旅行' => :unmatched_closing,
      'ファイル）を確認。出張' => :unmatched_closing,
      'ファイル）を確認。滞在' => :unmatched_closing,
      'ファイル）を確認。観光' => :unmatched_closing,
      'ファイル）を確認。宿泊' => :unmatched_closing,
      'ファイル）を確認。帰省' => :unmatched_closing,
      'ファイル）を確認。休み' => :unmatched_closing,
      'ファイル）を確認。休暇' => :unmatched_closing,
      'ファイル）を確認。勉強' => :unmatched_closing,
      'ファイル）を確認。学習' => :unmatched_closing,
      'ファイル）を確認。課題' => :unmatched_closing,
      'ファイル）を確認。チャット' => :unmatched_closing,
      'ファイル）を確認。営業' => :unmatched_closing,
      'ファイル）を確認。定例' => :unmatched_closing,
      'ファイル）を確認。相談' => :unmatched_closing,
      'ファイル）を確認。挨拶' => :unmatched_closing,
      'ファイル）を確認。掃除' => :unmatched_closing,
      'ファイル）を確認。買い物' => :unmatched_closing,
      'ファイル）を確認。洗濯' => :unmatched_closing,
      'ファイル）を確認。散歩' => :unmatched_closing,
      'ファイル）を確認。運動' => :unmatched_closing,
      'ファイル）を確認。ランチ' => :unmatched_closing,
      'ファイル）を確認。ディナー' => :unmatched_closing,
      'ファイル）を確認。ディープワーク' => :unmatched_closing,
      'ファイル）を確認。focus' => :unmatched_closing,
      'ファイル）を確認。作業時間' => :unmatched_closing,
      'ファイル）を確認。作業の時間' => :unmatched_closing,
      'ファイル）を確認。資料を作る' => :unmatched_closing,
      'ファイル）を確認。レビュー時間' => :unmatched_closing,
      'ファイル）を確認。課題時間' => :unmatched_closing,
      'ファイル）を確認。宿題' => :unmatched_closing,
      'ファイル）を確認。復習' => :unmatched_closing,
      'ファイル）を確認。毎日ストレッチ' => :unmatched_closing,
      'ファイル）を確認。毎朝体操' => :unmatched_closing,
      'ファイル）を確認。毎晩休憩' => :unmatched_closing,
      'ファイル）を確認。毎日ランニング' => :unmatched_closing,
      'ファイル）を確認。毎朝ヨガ' => :unmatched_closing,
      'ファイル）を確認。毎晩日記' => :unmatched_closing,
      'ファイル）を確認。毎日瞑想' => :unmatched_closing,
      'ファイル）を確認。毎朝朝食' => :unmatched_closing,
      'ファイル）を確認。毎晩夕食' => :unmatched_closing,
      'ファイル）を確認。ストレッチを毎日' => :unmatched_closing,
      'ファイル）を確認。ヨガを毎朝' => :unmatched_closing,
      'ファイル）を確認。日記を毎晩' => :unmatched_closing,
      'ファイル）を確認。ストレッチを毎日する' => :unmatched_closing,
      'ファイル）を確認。毎日' => :unmatched_closing,
      'ファイル）を確認。忙しい日を教えて' => :unmatched_closing,
      'ファイル）を確認。整理したい' => :unmatched_closing,
      'ファイル）を確認。会議のリマインダー' => :unmatched_closing,
      'ファイル）を確認。会議を通知して' => :unmatched_closing,
      'ファイル）を確認。会議を知らせて' => :unmatched_closing,
      'ファイル）を確認。会議のアラート' => :unmatched_closing,
      'ファイル）を確認。空き時間を教えて' => :unmatched_closing,
      'ファイル）を確認。会議と面談の間' => :unmatched_closing,
      'ファイル）を確認。会議をずらしたい' => :unmatched_closing,
      '電話｡ファイル）を確認' => :unmatched_closing,
      '電話︒ファイル）を確認' => :unmatched_closing,
      '電話．ファイル）を確認' => :unmatched_closing,
      '電話﹒ファイル）を確認' => :unmatched_closing,
      '電話․ファイル）を確認' => :unmatched_closing,
      '電話､ファイル）を確認' => :unmatched_closing,
      '電話，ファイル）を確認' => :unmatched_closing,
      '電話︑ファイル）を確認' => :unmatched_closing,
      '電話﹑ファイル）を確認' => :unmatched_closing,
      '電話︐ファイル）を確認' => :unmatched_closing,
      '電話﹐ファイル）を確認' => :unmatched_closing,
      '電話;ファイル）を確認' => :unmatched_closing,
      '電話︔ファイル）を確認' => :unmatched_closing,
      '電話﹔ファイル）を確認' => :unmatched_closing,
      'U.S.A.，電話｡ファイル）を確認' => :unmatched_closing,
      'U．S．A．，電話｡ファイル）を確認' => :unmatched_closing,
      'Dr.，電話｡ファイル）を確認' => :unmatched_closing,
      'U.S.A.︕電話｡ファイル）を確認' => :unmatched_closing,
      'U.S.A.︖電話｡ファイル）を確認' => :unmatched_closing,
      'U.S.A.︔電話｡ファイル）を確認' => :unmatched_closing,
      '電話そしてファイル）を確認' => :unmatched_closing,
      '電話それからファイル）を確認' => :unmatched_closing,
      'ファイル）を確認。設計確認' => :unmatched_closing,
      'ファイル）を確認。仕様2.0確認' => :unmatched_closing,
      'ファイル）を確認。API確認' => :unmatched_closing,
      'ファイル）を確認。example.com確認' => :unmatched_closing,
      'ファイル）を確認。会議(Phase 1)' => :unmatched_closing,
      'ファイル）を確認。設計確認(Phase 2)' => :unmatched_closing,
      'ファイル）を確認。電話当番' => :unmatched_closing,
      'ファイル）を確認。読書タイム' => :unmatched_closing,
      'ファイル）を確認。旅行準備' => :unmatched_closing,
      'ファイル）を確認。会議準備' => :unmatched_closing,
      'ファイル）を確認。掃除当番' => :unmatched_closing,
      'ファイル）を確認。運動タイム' => :unmatched_closing,
      'ファイル）を確認。ランチ会' => :unmatched_closing,
      'ファイル）を確認。チャット会' => :unmatched_closing,
      'ファイル）を確認。レビュー会' => :unmatched_closing,
      'ファイル）を確認。食事会' => :unmatched_closing,
      'ファイル）を確認。飲み会準備' => :unmatched_closing,
      'ファイル）を確認。電話をお願いしたい' => :unmatched_closing,
      'ファイル）を確認。電話をお願いいたします' => :unmatched_closing,
      'ファイル）を確認。電話をかけたい' => :unmatched_closing,
      'ファイル）を確認。電話をかける' => :unmatched_closing,
      'ファイル）を確認。会議を開きたい' => :unmatched_closing,
      'ファイル）を確認。会議を開く' => :unmatched_closing,
      'ファイル）を確認。散歩に出たい' => :unmatched_closing,
      'ファイル）を確認。運動を始めたい' => :unmatched_closing,
      'ファイル）を確認。旅行へ出たい' => :unmatched_closing,
      'ファイル）を確認。ランチを食べたい' => :unmatched_closing,
      'ファイル）を確認。ディナーを食べたい' => :unmatched_closing,
      'ファイル）を確認。電話する' => :unmatched_closing,
      'ファイル）を確認。会議する' => :unmatched_closing,
      'ファイル）を確認。運動する' => :unmatched_closing,
      'ファイル）を確認。掃除する' => :unmatched_closing,
      'ファイル）を確認。洗濯する' => :unmatched_closing,
      'ファイル）を確認。読書する' => :unmatched_closing,
      'ファイル）を確認。旅行する' => :unmatched_closing,
      'ファイル）を確認。散歩する' => :unmatched_closing,
      'ファイル）を確認。ランチする' => :unmatched_closing,
      'ファイル）を確認。ディナーする' => :unmatched_closing,
      'ファイル）を確認。チャットする' => :unmatched_closing,
      'ファイル）を確認。レビューする' => :unmatched_closing,
      'ファイル）を確認。面談する' => :unmatched_closing,
      '電話「重要' => :unmatched_opening,
      '電話重要」' => :unmatched_closing,
      '電話「重要）' => :mismatched_closing,
      '作業「集中' => :unmatched_opening,
      '旅行【夏季' => :unmatched_opening,
      '会食『顧客' => :unmatched_opening,
      '歯医者（定期' => :unmatched_opening,
      'ファイル）を確認。電話（重要）' => :unmatched_closing,
      'ファイル）を確認。作業（集中）' => :unmatched_closing,
      'ファイル）を確認。旅行【夏季】' => :unmatched_closing,
      '散歩【したい' => :unmatched_opening,
      'ランチ【したい' => :unmatched_opening,
      '運動【したい' => :unmatched_opening,
      '旅行【に行きたい' => :unmatched_opening,
      '休み【を取りたい' => :unmatched_opening,
      '会議【を入れたい' => :unmatched_opening,
      '運動【してください' => :unmatched_opening,
      '読書【して' => :unmatched_opening,
      '通院【お願い' => :unmatched_opening,
      '買い物【入れといて' => :unmatched_opening,
      '買い物【いれといて' => :unmatched_opening,
      '会議【の時間' => :unmatched_opening,
      '飲み【してください' => :unmatched_opening,
      '資料【作ってください' => :unmatched_opening,
      'メモ【お願いします' => :unmatched_opening,
      '確認【してください' => :unmatched_opening,
      '散歩【お願いします' => :unmatched_opening
    }.each do |input, expected_error_kind|
      assert_syntax_clarification_contract(input, expected_error_kind: expected_error_kind)
    end

    existing_event_context = BASE_CONTEXT.merge(
      personal_events: [
        {
          id: 42,
          title: '予約',
          start_at: '2026-08-16T10:00:00+09:00',
          end_at: '2026-08-16T11:00:00+09:00'
        }
      ]
    )
    cases.first(3).each do |input, expected_error_kind|
      assert_syntax_clarification_contract(
        input,
        expected_error_kind: expected_error_kind,
        context: existing_event_context
      )
    end

    meeting_context = BASE_CONTEXT.merge(
      personal_events: [
        {
          id: 84,
          title: '会議',
          start_at: '2026-08-16T14:00:00+09:00',
          end_at: '2026-08-16T15:00:00+09:00'
        }
      ]
    )
    [
      '会議の議事録を書いた。設定【を変更して',
      '会議とは無関係。ファイル（を削除して',
      'ファイル）を確認。会議の議事録を書いた',
      '文章］を読む。病院の歴史を教えて',
      '予約という言葉。画像「を追加して',
      'ファイル）を確認。会議の議事録です',
      '文章］を読む。病院の歴史です',
      'ファイル）を確認。電話の仕組みです',
      '文章］を読む。資料を読んだ',
      '画像』を削除。メモを整理した',
      '設定】を変更。旅行の記事です',
      '文章］を読む。運動の歴史です',
      '画像』を削除。レビューを読んだ',
      'ファイル）を確認。毎日新聞について教えて',
      'ファイル）を確認。毎日新聞を読む',
      '文章］を読む。通知の仕組みです',
      '画像』を削除。空きという言葉です',
      'ファイル）を確認。散歩したいという話です',
      '資料の内容【を確認してください',
      '文章【をレビューしてください',
      'コード【をレビューしてください',
      '映画【をレビューしてください',
      '電話「の仕組み',
      '旅行【の記事',
      '映画「の感想',
      '電話番号」',
      '作業手順」',
      'ファイル）を確認。電話番号',
      'ファイル）を確認。旅行記事',
      'ファイル）を確認。病院歴史',
      '電話、という言葉。ファイル）を確認',
      '「電話」、という言葉。ファイル）を確認',
      '映画、という単語。ファイル）を確認',
      'focus、という単語。ファイル）を確認',
      '予約、という言葉。画像）を追加',
      '「focus」という単語の意味。ファイル）を確認',
      '「毎日」という言葉。ファイル）を確認',
      '「空き時間」という言葉。ファイル）を確認',
      '「リマインダー」という言葉。ファイル）を確認',
      '電話帳【を開いて',
      '電話機【を買いたい',
      '作業服【を買いたい',
      '食事メニュー【を見せて',
      'ランチメニュー【を見せて',
      '会議室【の場所を教えて',
      'レビュー欄【を開いて',
      '予約語【を説明して',
      'チャット欄【を開いて',
      '掃除機【を買いたい',
      '洗濯機【を買いたい',
      '電話帳【とは何',
      '会議室【の設備を教えて',
      '読書感想文【の書き方を教えて',
      '会議の議事録【を確認してください',
      '電話、というのは何。ファイル）を確認',
      '「電話」、とはどういう意味。ファイル）を確認',
      '電話、とは何か。ファイル）を確認',
      '映画、という作品名。ファイル）を確認',
      '予約、という概念。ファイル）を確認',
      'focus、とはどういう意味。ファイル）を確認',
      '電話【って何',
      '映画【って何',
      '予約【って何',
      'focus【って何',
      '電話【を説明して',
      '予約【を説明して',
      '電話【の読み方',
      '電話【の例',
      '電話【の英訳',
      '電話【を英訳して',
      '映画【を見せて',
      'レビュー【を見せて',
      '会食【を教えて',
      '歯医者【を教えて',
      '電話【ってどういうこと',
      '映画【とはどのようなもの',
      '予約【について解説して',
      '電話【を教えて',
      '映画【のおすすめ',
      'レビュー【の評価',
      '旅行【の価格',
      '読書【の種類',
      'ランチ【のお店を教えて',
      '掃除【のコツ',
      'カレンダー【の機能を教えて',
      '映画【を買いたい',
      '電話【について知りたいです',
      '映画【について教えてほしい',
      '予約【を知りたい',
      '会議【を説明してほしい',
      '旅行【の値段',
      '旅行【の費用',
      '旅行【の料金',
      '旅行【の評判',
      '読書【のお勧め',
      '読書【のオススメ',
      '読書【の情報',
      '読書【の詳細',
      '読書【の概要',
      'ランチ【のやり方',
      'ランチ【の仕方',
      'ランチ【のアクセス',
      'ランチ【の連絡先',
      'ランチ【の営業時間',
      'イベント【のニュース',
      'イベント【の画像',
      'イベント【の動画',
      '映画【を調べてほしい',
      '映画【を検索してほしい',
      '映画【を見せてほしい',
      '映画【を探して',
      '映画【を紹介して',
      '映画【をおすすめして',
      '映画【を評価して',
      '映画【を比較して',
      '映画【を注文したい',
      '映画【を購入したい',
      '映画【を買おうと思う',
      '会議費【の料金',
      '電話料金【の料金',
      '作業台【の料金',
      '予約サイト【の料金',
      'カレンダーアプリ【の料金',
      'イベント会場【の料金',
      '会議費【を購入したい',
      '電話料金【を購入したい',
      '作業台【を購入したい',
      '会議費【の内訳',
      '会議費【の明細',
      '会議録【の書式',
      '会議録【のテンプレート',
      '会議資料【のフォーマット',
      '会議資料【のサンプル',
      '電話料金【の請求',
      '作業台【のサイズ',
      '作業台【の素材',
      '作業台【の仕様',
      '作業着【のサイズ',
      '予約サイト【のURL',
      '予約サイト【の比較',
      'カレンダーアプリ【の設定',
      'イベント会場【の地図',
      '会議場所【への行き方',
      '資料【を開いて',
      'カレンダーアプリ【を起動して',
      '会議資料【を表示して',
      '会議資料【を共有して',
      '映画ファイル【を削除して',
      'イベントページ【を開いて',
      '予約サイト【を開いて',
      '電話ファイル【を閉じる',
      '会議資料【をダウンロードして',
      '会議資料【をアップロードして',
      '会議資料【を送ってください',
      '会議資料【をコピーして',
      '会議資料【を保存して',
      'カレンダーアプリ【を起動してほしい',
      '会議資料【を共有してほしい',
      '映画ファイル【を開いてほしい',
      'イベントページ【を開けてください',
      '会議資料【を閲覧して',
      '映画ファイル【を再生して',
      'カレンダーアプリ【を読み込んで',
      'イベントページ【をクリックして',
      '会議資料【を添付して',
      'カレンダーアプリ【を同期して',
      'カレンダーアプリ【をインストールして',
      '会議PDF【を開いて',
      '会議CSV【を保存して',
      '会議メール【を送って',
      '会議メモ【を共有して',
      '会議録【を開いて',
      '会議録【を起動して',
      '会議録【を表示して',
      '会議録【を閉じて',
      '会議録【をdownload',
      '会議録【を共有して',
      '会議録【を送って',
      '会議録【を保存して',
      '会議録【を削除して',
      '会議録【を閲覧して',
      '会議録【を再生して',
      '会議録【を読み込んで',
      '会議録【をclick',
      '会議録【を添付して',
      '会議録【を同期して',
      '会議録【をinstall',
      '会議PDF【を削除して',
      '会議CSV【を削除して'
    ].each do |input|
      client = Ai::Client.new(context: meeting_context, user_message: input)

      refute client.send(:schedule_action_syntax_input?, input), "input=#{input.inspect}"
      assert_nil client.send(:local_schedule_syntax_clarification_response, input),
                 "input=#{input.inspect}"
      assert_nil client.send(:local_structured_schedule_response),
                 "local candidate route accepted malformed ordinary text: #{input.inspect}"
    end

    [
      '読書感想文を書く',
      '読書感想文の時間',
      '旅行記を書く',
      '会議議事録を書く',
      '会議議事録を整理する',
      'レビュー記事を書く',
      '旅行記事を書く',
      '会議内容を確認する',
      '電話番号を確認する',
      '会議資料を読む',
      '会議室を準備する',
      '会議室を予約する',
      '会議室を掃除する',
      '電話帳を更新する',
      '電話機を修理する',
      '作業服を購入する',
      '旅行記を編集する',
      '読書感想文を提出する',
      'レビュー記事を編集する',
      '会議議事録を作る',
      '会議議事録を印刷する',
      '会議内容を準備する',
      '掃除機を修理する',
      '洗濯機を修理する',
      '運動靴を購入する',
      '読書感想文を書きたい',
      '読書感想文を書きます',
      '読書感想文を提出したい',
      '旅行記を書きたい',
      '旅行記を読みたい',
      '旅行記を編集したい',
      '会議議事録を作りたい',
      '会議議事録を印刷したい',
      '会議議事録を確認したい',
      '会議議事録を整理したい',
      '会議室を予約したい',
      '会議室を準備したい',
      '会議室を掃除したい',
      '電話機を修理したい',
      '電話帳を更新したい',
      '掃除機を修理したい',
      '食事メニューを作りたい',
      'レビュー記事を書きたい',
      '会議内容を確認したい',
      '会議室を予約して',
      '会議室を予約してください',
      '会議室を準備して',
      '会議資料を読んでください',
      '会議議事録を印刷してください',
      '旅行記を書いてください',
      '読書感想文を提出してください',
      '電話機を修理してください',
      '掃除機を修理して',
      '旅行記を書こう',
      '会議議事録を作ろう',
      '読書感想文を提出しよう'
    ].each do |input|
      client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)

      refute client.send(:short_activity_request_excluded?, input), "input=#{input.inspect}"
      assert client.send(:short_activity_title_from_text, input).present?, "input=#{input.inspect}"
      assert_syntax_clarification_contract("#{input}【", expected_error_kind: :unmatched_opening)
    end
  end

  test 'CF-R15 list closing exceptions match existing inline heading semantics' do
    [
      {
        input: '来月の予定候補: 1) 9月1日10時に会議、2) 9月2日11時に資料作成',
        starts: %w[2026-09-01T10:00:00+09:00 2026-09-02T11:00:00+09:00]
      },
      {
        input: '今月の予定候補: 1) 8月20日10時に会議、2) 8月21日11時に資料作成',
        starts: %w[2026-08-20T10:00:00+09:00 2026-08-21T11:00:00+09:00]
      },
      {
        input: '仕事の予定候補: 1) 明日10時に会議、2) 明日11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '明日の予定候補(Phase 1): 1) 10時に会議、2) 11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '明日の予定候補(Phase 1) 1) 10時に会議、2) 11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '月曜の予定候補 1) 10時に会議、2) 11時に資料作成',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-17T11:00:00+09:00]
      },
      {
        input: '次の月曜の予定候補 1) 10時に会議、2) 11時に資料作成',
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-17T11:00:00+09:00]
      },
      {
        input: '予定候補：１）明日10時に会議、２）明日11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '予定候補，1）明日10時に会議，2）明日11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '予定候補：１)明日10時に会議、２)明日11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: "予定候補:\u00A01）明日10時に会議、\u00A02）明日11時に資料作成",
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '予定候補: 1）明日10時に会議､2）明日11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      },
      {
        input: '予定候補｡1）明日10時に会議｡2）明日11時に資料作成',
        starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      }
    ].each do |test_case|
      assert_multi_event_contract(
        test_case.fetch(:input),
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: %w[会議 資料作成],
        expected_starts: test_case.fetch(:starts),
        expected_durations: [60, 60]
      )
    end

    assert_multi_event_contract(
      '明日の予定候補: 1) 10時に会議(Phase 2)、2) 11時に資料作成',
      expected_provider: 'rails-local-multi-explicit-events-v1',
      expected_titles: ['会議(Phase 2)', '資料作成'],
      expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
      expected_durations: [60, 60]
    )

    {
      '仕様' => '設計確認(仕様 3)',
      '案' => '設計確認(案 3)',
      '会議室' => '設計確認(会議室 3)',
      'フェーズ' => '設計確認(フェーズ 3)',
      'API' => '設計確認(API 3)'
    }.each do |qualifier, expected_title|
      assert_multi_event_contract(
        "明日の予定候補: 1) 10時に会議、2) 11時に設計確認(#{qualifier} 3)",
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: ['会議', expected_title],
        expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end

    [
      '1) 10時に会議(仕様 2)',
      '1) 明日10時に仕様レビュー(API:2)',
      '1) 明日10時に仕様レビュー(案、2)',
      '1) 明日10時に仕様レビュー(Part;2)',
      '1) 明日10時に仕様レビュー(v1.2)',
      '1) 明日10時に仕様レビュー(API:2)版',
      '1) 明日10時に仕様レビュー(案、2)の確認',
      '1) 明日10時に仕様レビュー(Part;2)レビュー',
      '1) 明日10時に会議(ProjectX:2)確認',
      '1) 明日10時に会議(ProjectX:2)更新',
      '1) 明日10時に会議(ProjectX:2)会議',
      '1) 明日10時に会議(ProjectX:2)報告',
      '1) 明日10時に会議(ProjectX:2)共有',
      '1) 明日10時に会議(ProjectX:2)準備',
      '1) 明日10時に会議(ProjectX:2)発表',
      '1) 明日10時に会議(ProjectX:2)振り返り',
      '1) 明日10時に会議(ProjectX:2)説明',
      '1) 明日10時に会議(ProjectX:2)面談',
      '1) 明日10時に会議(ProjectX:2)相談',
      '1) 明日10時に会議(ProjectX:2)研修',
      '1) 明日10時に(ProjectX 2)報告',
      '1) 明日10時に（ProjectX ２）報告',
      '1) 明日10時に(ProjectX 2)共有',
      '1) 明日10時に(ProjectX 2)準備',
      '1) 明日10時に(ProjectX 2)発表',
      '1) 明日10時に(ProjectX 2)説明',
      '1) 明日10時に(ProjectX 2)面談',
      '1) 明日10時に(ProjectX 2)相談',
      '1) 明日10時に(ProjectX 2)研修',
      "1) 明日10時に(ProjectX 2)報告#{'詳細' * 300}",
      '1) 明日10時に「(ProjectX 2)報告」',
      '1) 明日10時に【（ProjectX ２）報告】',
      '1) 明日10時に会議(ProjectX:2) 報告',
      '1) 明日10時に会議(ProjectX:2) レビュー',
      '1) 明日10時にReview(ProjectX:2) report',
      '1) 明日10時に「会議(ProjectX:2) 報告」',
      '1) 明日10時に会議(ProjectX、2)確認',
      '1) 明日10時に「会議(ProjectX:2)確認」',
      '1) 10時に会議(仕様 2)10時版レビュー',
      '1) 明日10時に会議(詳細 2)月曜レビュー',
      '1) 明日10時に会議(仕様 2)月曜定例',
      '1) 明日10時に会議(詳細 7)月曜レビュー',
      '明日の予定候補: 1) 10時に会議、2) 11時に設計確認(詳細 9)月曜レビュー',
      '1) 明日10時に「仕様（API 2） 確認」レビュー',
      '1) 明日10時に「仕様（詳細 2） 確認」レビュー',
      '1) 明日10時に「仕様（ProjectX 2） 確認」レビュー',
      '1) 明日10時に会議(詳細 (API 2) 確認)',
      '1) 明日10時に【仕様(API 2) 確認】レビュー',
      "1) 明日10時に会議(仕様 2)月曜レビュー#{'詳細' * 300}",
      "1) 明日10時に会議(仕様 2)月曜に関する#{'詳細' * 10}レビュー",
      "1) 明日10時に会議(仕様 2)月曜に関する#{'詳細' * 300}レビュー",
      "1) 明日10時に会議(仕様 2)10時に関する#{'詳細' * 300}レビュー"
    ].each do |single_item|
      single_item_client = Ai::Client.new(context: BASE_CONTEXT, user_message: single_item)
      assert_nil single_item_client.send(:scan_protected_text_delimiters, single_item).fetch(:error),
                 "input=#{single_item.inspect}"
      assert_nil single_item_client.send(:local_schedule_syntax_clarification_response, single_item),
                 "input=#{single_item.inspect}"
    end

    [
      "1) 明日10時に(ProjectX 2)報告(Phase 3)共有",
      "1) 明日10時に（ProjectX ２）報告（Phase ３）共有",
      *[
        "\u00A0", "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005",
        "\u2006", "\u2007", "\u2008", "\u2009", "\u200A", "\u202F", "\u205F", "\u3000"
      ].flat_map do |space|
        [
          "1) 明日10時に(ProjectX#{space}2)報告",
          "1) 明日10時に（ProjectX#{space}２）報告"
        ]
      end
    ].each do |single_item|
      single_item_client = Ai::Client.new(context: BASE_CONTEXT, user_message: single_item)
      assert_nil single_item_client.send(:scan_protected_text_delimiters, single_item).fetch(:error),
                 "input=#{single_item.inspect}"
      assert_nil single_item_client.send(:local_schedule_syntax_clarification_response, single_item),
                 "input=#{single_item.inspect}"
    end

    assert_syntax_clarification_contract(
      '明日の予定候補: 1) 10時に(会議 2)資料作成 3)12時に確認',
      expected_error_kind: :unmatched_opening
    )

    qualifier_with_control =
      '明日の予定候補: 1) 10時に会議、2) 11時に設計確認(仕様 3)。保存はしないでください'
    control_client = Ai::Client.new(context: BASE_CONTEXT, user_message: qualifier_with_control)
    assert_nil control_client.send(:scan_protected_text_delimiters, qualifier_with_control).fetch(:error)
    assert_nil control_client.send(
      :local_schedule_syntax_clarification_response,
      qualifier_with_control
    )

    {
      '設計確認(仕様 3)レビュー' => '設計確認(仕様 3)レビュー',
      '設計確認(案 3)の確認' => '設計確認(案 3)の確認',
      '設計確認(API 3)版レビュー' => '設計確認(API 3)版レビュー'
    }.each do |qualified_title, expected_title|
      assert_multi_event_contract(
        "明日の予定候補: 1) 10時に会議、2) 11時に#{qualified_title}",
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: ['会議', expected_title],
        expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end

    [
      '明日の予定候補: 1) 10時に会議、2) 11時に設計確認(仕様 3)月曜レビュー',
      '明日の予定候補: 1) 10時に会議、2) 11時に設計確認(仕様 3)明日版レビュー',
      '明日の予定候補: 1) 10時に会議、2) 11時に設計確認(仕様 3)午後レビュー'
    ].each do |input|
      client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)
      assert_nil client.send(:scan_protected_text_delimiters, input).fetch(:error), "input=#{input.inspect}"
      assert_nil client.send(:local_schedule_syntax_clarification_response, input), "input=#{input.inspect}"
    end

    [
      '1) 10時に会議(仕様 2)レビュー',
      '1) 10時に会議(案 2)の確認',
      '1) 10時に会議(会議室 2)予約'
    ].each do |input|
      client = Ai::Client.new(context: BASE_CONTEXT, user_message: input)
      assert_nil client.send(:scan_protected_text_delimiters, input).fetch(:error), "input=#{input.inspect}"
      assert_nil client.send(:local_schedule_syntax_clarification_response, input), "input=#{input.inspect}"
    end
  end

  test 'CF-R15 balanced qualified list headings preserve all delimiter families' do
    [
      '「Phase 1」', '『Phase 1』', '“Phase 1”', '‘Phase 1’', '"Phase 1"', "'Phase 1'",
      '（Phase 1）', '(Phase 1)', '［Phase 1］', '[Phase 1]', '【Phase 1】'
    ].each do |qualifier|
      assert_multi_event_contract(
        "明日の予定候補#{qualifier} 1) 10時に会議、2) 11時に資料作成",
        expected_provider: 'rails-local-multi-explicit-events-v1',
        expected_titles: %w[会議 資料作成],
        expected_starts: %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00],
        expected_durations: [60, 60]
      )
    end
  end

  test 'CF-R15 negative duration signs reject the complete request' do
    [
      '明日10時に会議を−30分',
      '明日10時に会議を−1時間',
      '明日10時に会議を-30分',
      '明日10時に会議を－30分',
      '明日10時に会議を﹣30分',
      '明日10時に会議を−1.5時間',
      '明日10時に会議を−0.5時間',
      '明日10時に会議を−.5時間',
      '明日10時に会議を − 30分',
      '明日10時から−30分、会議',
      '明日10時に会議、11時に資料作成を−30分行います',
      '月曜10時に会議、火曜11時に資料作成を−1時間実施します',
      '8月の月曜にゴミ出しを−30分'
    ].each do |input|
      assert_zero_candidate_contract(input, expected_provider: 'rails-local-duration-validation-v1')
    end
  end

  test 'CF-R15 zero duration connectors preserve the existing fail closed invariant' do
    [
      '明日10時から0',
      '明日10時〜0',
      '明日10時~0',
      '明日10時に会議を0.00時間',
      '明日10時に会議を00分'
    ].each do |input|
      assert_zero_candidate_contract(input, expected_provider: 'rails-local-duration-validation-v1')
    end
  end

  test 'CF-R15 monthly garbage preprocessing preserves validation precedence' do
    {
      '8月の月曜にゴミ出しを0分' => 'rails-local-duration-validation-v1',
      '8月の月曜にゴミ出しを0.00時間' => 'rails-local-duration-validation-v1',
      '8月の月曜にゴミ出しを000分' => 'rails-local-duration-validation-v1',
      '8月の月曜25時にゴミ出し' => 'rails-local-time-validation-v1',
      '8月の月曜10時から9時までゴミ出し' => 'rails-local-time-range-validation-v1',
      '2026年9月31日の月曜にゴミ出し' => 'rails-local-date-validation-v1'
    }.each do |input, provider|
      assert_zero_candidate_contract(input, expected_provider: provider)
    end

    assert_no_difference('Event.count') do
      response, remote_called = ai_response_with_remote_sentinel('8月の月曜にゴミ出し')

      refute remote_called
      assert_equal 'rails-garbage-recurrence-v1', response.fetch(:provider)
      assert_equal 1, recommendations(response).length
      assert_empty response.fetch(:tool_invocations)
    end
  end

  test 'CF-R15 negative duration controls preserve ranges titles and positive durations' do
    [
      {
        input: '明日10時から11時まで会議',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [60]
      },
      {
        input: '明日10時-11時に会議',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [60]
      },
      {
        input: '月曜10時にA−B比較、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['a−b比較', '設計確認'],
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '月曜10時にC-APIレビュー、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['c-apiレビュー', '設計確認'],
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '明日10時に会議を30分',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [30]
      },
      {
        input: '明日10時に会議を 0.5時間',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [30]
      },
      {
        input: '明日10時にProject -30レビュー',
        provider: 'rails-local-single-explicit-v5',
        titles: ['Project -30レビュー'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [60]
      },
      {
        input: '明日10時にProject -0レビュー',
        provider: 'rails-local-single-explicit-v5',
        titles: ['Project -0レビュー'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [60]
      }
    ].each do |test_case|
      assert_multi_event_contract(
        test_case.fetch(:input),
        expected_provider: test_case.fetch(:provider),
        expected_titles: test_case.fetch(:titles),
        expected_starts: test_case.fetch(:starts),
        expected_durations: test_case.fetch(:durations)
      )
    end
  end

  test 'CF-R15 duration validation parser builder and response gates fail closed independently' do
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: '明日10時に会議')

    ['-30分', '−30分', '﹣30分', '－30分', '− 30分', '−1時間', '−1.5時間', '−0.5時間', '−.5時間'].each do |duration|
      assert_equal(-1, client.send(:explicit_duration_minutes, duration), "duration=#{duration.inspect}")
    end

    build_options = {
      title: '会議',
      date: Date.new(2026, 8, 16),
      text: '明日10時に会議',
      start_minute: 10 * 60,
      default_duration: 60,
      all_day: false
    }

    assert_nil client.send(:build_local_event_payload, **build_options, duration_minutes: 0)
    assert_nil client.send(:build_local_event_payload, **build_options, duration_minutes: -30)
    assert_nil client.send(
      :build_local_event_payload,
      **build_options.merge(text: '明日10時に会議を−30分'),
      duration_minutes: 30
    )
    assert_nil client.send(
      :build_local_event_payload,
      **build_options.merge(text: '明日終日会議を−30分', all_day: true),
      duration_minutes: 30
    )

    valid_event = client.send(:build_local_event_payload, **build_options, duration_minutes: 30)
    assert client.send(:positive_local_event_time_range?, valid_event)
    assert_equal 30.minutes,
                 Time.iso8601(valid_event.fetch('end_at')) - Time.iso8601(valid_event.fetch('start_at'))
    refute client.send(
      :positive_local_event_time_range?,
      { 'start_at' => '2026-08-16T10:00:00+09:00', 'end_at' => '2026-08-16T10:00:00+09:00' }
    )
    refute client.send(
      :positive_local_event_time_range?,
      { 'start_at' => '2026-08-16T10:00:00+09:00', 'end_at' => '2026-08-16T09:59:00+09:00' }
    )
  end

  test 'CF-R15 shared clock weekday framing strips all required terminal variants' do
    [
      '月曜と火曜の10時に会議の予定候補を作って',
      '月曜と火曜の10時に会議の予定候補を作ってください',
      '月曜と火曜の10時に会議の予定候補を作成してください',
      '月曜と火曜の10時に会議の予定候補を作成して下さい',
      '月曜と火曜の10時に会議を予定候補として整理してください',
      '月曜と火曜の10時に会議を予定候補として整理して下さい',
      '月曜と火曜の10時に会議を予定候補としてまとめてください',
      '月曜と火曜の10時に会議を予定候補としてまとめて下さい',
      '月曜と火曜の10時に会議の予定候補を作って。保存はしないでください。',
      '月曜と火曜の10時に会議の予定候補を作って。通知先は設定しない',
      '月曜と火曜の10時に会議の予定候補を作って。通知先は設定しません',
      '月曜と火曜の10時に会議の予定候補を作って。通知先は設定不要',
      '月曜と火曜の10時に会議の予定候補を作って。通知先は設定なし',
      '月曜と火曜の10時に会議の予定候補を作って。担当者と通知先は設定しない',
      '月曜と火曜の10時に会議の予定候補を作って。通知は設定しない',
      '月曜と火曜の10時に会議の予定候補を作って。担当者や通知先は設定せず'
    ].each do |input|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-weekday-multi-event-v1',
        expected_titles: %w[会議 会議],
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
        expected_durations: [60, 60]
      )
    end

    assert_multi_event_contract(
      '来週月曜と火曜の10時にAPI v2.0確認を45分の予定候補としてまとめてください',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: ['API v2.0確認', 'API v2.0確認'],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
      expected_durations: [45, 45]
    )
  end

  test 'CF-R15 shared clock weekday framing preserves structural boundaries' do
    [
      ['月曜と火曜の10時に会議', %w[会議 会議]],
      ['月曜と火曜の10時に予定候補作成会議', %w[予定候補作成会議 予定候補作成会議]],
      [
        '月曜と火曜の10時に会議の予定候補を作ってレビュー',
        ['会議の予定候補を作ってレビュー', '会議の予定候補を作ってレビュー']
      ],
      [
        '月曜と火曜の10時に「予定候補を作って」レビュー',
        ['「予定候補を作って」レビュー', '「予定候補を作って」レビュー']
      ]
    ].each do |input, expected_titles|
      assert_multi_event_contract(
        input,
        expected_provider: 'rails-local-weekday-multi-event-v1',
        expected_titles: expected_titles,
        expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
        expected_durations: [60, 60]
      )
    end

    assert_zero_candidate_contract(
      '月曜と火曜の10時に会議、11時に設計確認',
      expected_provider: 'rails-local-weekday-multi-event-clarification-v1'
    )

    assert_multi_event_contract(
      '月曜の10時に会議の予定候補を作って',
      expected_provider: 'rails-local-single-explicit-v5',
      expected_titles: ['会議の予定候補'],
      expected_starts: ['2026-08-17T10:00:00+09:00'],
      expected_durations: [60]
    )

    assert_zero_candidate_contract(
      '月曜と火曜の10時に予定の予定候補を作って',
      expected_provider: 'rails-local-weekday-multi-event-clarification-v1'
    )
  end

  test 'CF-R15 combined delimiter duration and shared framing regressions stay fail closed' do
    assert_multi_event_contract(
      '月曜と火曜の10時に「API v2.0確認」の予定候補を作成してください',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: ['「API v2.0確認」', '「API v2.0確認」'],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
      expected_durations: [60, 60]
    )

    assert_multi_event_contract(
      '月曜と火曜の10時に会議を30分、予定候補としてまとめてください',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: %w[会議 会議],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
      expected_durations: [30, 30]
    )

    assert_zero_candidate_contract(
      '月曜と火曜の10時に会議を−30分の予定候補を作って',
      expected_provider: 'rails-local-duration-validation-v1'
    )

    assert_syntax_clarification_contract(
      '月曜と火曜の10時に「会議の予定候補を作って',
      expected_error_kind: :unmatched_opening
    )
  end

  [
    { label: 'unicode minus minutes', sign: '−', gap: "\n", duration: "−\n30分" },
    { label: 'unicode minus hours', sign: '−', gap: "\n", duration: "−\n1時間" },
    { label: 'ascii minus minutes', sign: '-', gap: "\n", duration: "-\n30分" },
    { label: 'fullwidth minus minutes', sign: '－', gap: "\n", duration: "－\n30分" },
    { label: 'small minus minutes', sign: '﹣', gap: "\n", duration: "﹣\n30分" }
  ].each do |test_case|
    test "CF-R16 exact reproduction rejects #{test_case.fetch(:label)}" do
      input = "明日10時に会議を#{test_case.fetch(:duration)}"
      assert_zero_candidate_contract(
        input,
        expected_provider: 'rails-local-duration-validation-v1',
        diagnostic: r16_duration_case_diagnostic(
          kind: :single_exact_reproduction,
          sign: test_case.fetch(:sign),
          gap: test_case.fetch(:gap),
          input: input
        )
      )
    end
  end

  test 'CF-R16 rejects every vertical duration gap before candidate routing' do
    assert_equal 4, R16_NEGATIVE_DURATION_SIGNS.length
    assert_equal 8, R16_VERTICAL_DURATION_GAPS.length
    assert_equal 96, R16_NEGATIVE_DURATION_SIGNS.product(R16_VERTICAL_DURATION_GAPS).length * 3

    R16_NEGATIVE_DURATION_SIGNS.product(R16_VERTICAL_DURATION_GAPS).each do |sign, gap|
      {
        single_sign_value: "#{sign}#{gap}30分",
        single_value_unit: "#{sign}30#{gap}分",
        single_both_gaps: "#{sign}#{gap}30#{gap}分"
      }.each do |kind, duration|
        input = "明日10時に会議を#{duration}"
        diagnostic = r16_duration_case_diagnostic(
          kind: kind,
          sign: sign,
          gap: gap,
          input: input
        )

        assert_zero_candidate_contract(
          input,
          expected_provider: 'rails-local-duration-validation-v1',
          diagnostic: diagnostic
        )
      end
    end

    R16_VERTICAL_DURATION_GAPS.each do |gap|
      [
        "30#{gap}分",
        "1#{gap}時間",
        "1.5#{gap}時間",
        ".5#{gap}時間",
        "1#{gap}時間#{gap}30#{gap}分",
        "1#{gap}時間#{gap}半"
      ].each do |duration_body|
        input = "明日10時に会議を−#{gap}#{duration_body}"
        assert_zero_candidate_contract(
          input,
          expected_provider: 'rails-local-duration-validation-v1',
          diagnostic: r16_duration_case_diagnostic(
            kind: :single_duration_form,
            sign: '−',
            gap: gap,
            input: input
          )
        )
      end
    end

    ogham_gap = "\u1680"
    ogham_input = "明日10時に会議を−#{ogham_gap}30分"
    assert_zero_candidate_contract(
      ogham_input,
      expected_provider: 'rails-local-duration-validation-v1',
      diagnostic: r16_duration_case_diagnostic(
        kind: :single_unicode_horizontal_gap,
        sign: '−',
        gap: ogham_gap,
        input: ogham_input
      )
    )
  end

  test 'CF-R16 rejects the whole multi event request for multiline negative durations' do
    multi_case_count = 0
    R16_NEGATIVE_DURATION_SIGNS.each do |sign|
      gap = "\n"
      input = "明日10時に会議、11時に資料作成を#{sign}#{gap}30分行います"
      assert_zero_candidate_contract(
        input,
        expected_provider: 'rails-local-duration-validation-v1',
        diagnostic: r16_duration_case_diagnostic(
          kind: :multi_sign,
          sign: sign,
          gap: gap,
          input: input
        )
      )
      multi_case_count += 1
    end

    R16_VERTICAL_DURATION_GAPS.each do |gap|
      input = "明日10時に会議、11時に資料作成を−#{gap}30分行います"
      assert_zero_candidate_contract(
        input,
        expected_provider: 'rails-local-duration-validation-v1',
        diagnostic: r16_duration_case_diagnostic(
          kind: :multi_vertical_gap,
          sign: '−',
          gap: gap,
          input: input
        )
      )
      multi_case_count += 1
    end

    [
      "月曜10時に会議、火曜11時に資料作成を−\n1時間実施します",
      "月曜と火曜の10時に会議を−\n30分の予定候補を作って"
    ].each do |input|
      assert_zero_candidate_contract(
        input,
        expected_provider: 'rails-local-duration-validation-v1',
        diagnostic: r16_duration_case_diagnostic(
          kind: :multi_route_precedence,
          sign: '−',
          gap: "\n",
          input: input
        )
      )
      multi_case_count += 1
    end
    assert_equal 14, multi_case_count
  end

  test 'CF-R16 rejects mixed horizontal and vertical duration gaps' do
    assert_equal 8, R16_MIXED_DURATION_GAPS.length
    mixed_case_count = 0
    R16_MIXED_DURATION_GAPS.each do |gap|
      {
        mixed_sign_value: "−#{gap}30分",
        mixed_value_unit: "−30#{gap}分",
        mixed_both_gaps: "−#{gap}30#{gap}分"
      }.each do |kind, duration|
        input = "明日10時に会議を#{duration}"
        assert_zero_candidate_contract(
          input,
          expected_provider: 'rails-local-duration-validation-v1',
          diagnostic: r16_duration_case_diagnostic(
            kind: kind,
            sign: '−',
            gap: gap,
            input: input
          )
        )
        mixed_case_count += 1
      end
    end
    assert_equal 24, mixed_case_count
  end

  test 'CF-R16 shares duration token gap coverage across validation parser and builder' do
    client = Ai::Client.new(context: BASE_CONTEXT, user_message: '明日10時に会議')
    recognized_gaps = (
      Ai::Client::DURATION_TOKEN_WHITESPACE_CHARACTERS +
      R16_VERTICAL_DURATION_GAPS +
      R16_MIXED_DURATION_GAPS
    ).uniq

    recognized_gaps.each do |gap|
      {
        "30#{gap}分" => 30,
        "1#{gap}時間" => 60,
        "1.5#{gap}時間" => 90,
        "1#{gap}時間#{gap}30#{gap}分" => 90,
        "1#{gap}時間#{gap}半" => 90
      }.each do |positive_duration, expected_minutes|
        assert_equal expected_minutes,
                     client.send(:explicit_duration_minutes, positive_duration),
                     "positive gap=#{gap.codepoints.map { |cp| format('U+%04X', cp) }.join(' ')} " \
                     "gap_inspect=#{gap.inspect} duration=#{positive_duration.inspect}"
      end

      R16_NEGATIVE_DURATION_SIGNS.each do |sign|
        negative_duration = "#{sign}#{gap}30#{gap}分"
        diagnostic = r16_duration_case_diagnostic(
          kind: :defence_in_depth,
          sign: sign,
          gap: gap,
          input: negative_duration
        )

        assert client.send(:invalid_duration_match, negative_duration), diagnostic
        assert_equal(-1, client.send(:explicit_duration_minutes, negative_duration), diagnostic)
      end
    end

    ["A−\nB", "C-\r\nAPI", "UTF−\u20288確認"].each do |title|
      assert_nil client.send(:invalid_duration_match, title), "title=#{title.inspect}"
    end
    assert client.send(:invalid_duration_match, "－\u00851\r\n時間\v30\f分")
    assert_equal(-1, client.send(:explicit_duration_minutes, "−\n.5\u2029時間"))

    build_options = {
      title: '会議',
      date: Date.new(2026, 8, 16),
      start_minute: 10 * 60,
      default_duration: 60,
      all_day: false
    }
    assert_nil client.send(
      :build_local_event_payload,
      **build_options.merge(text: "明日10時に会議を−\n30分"),
      duration_minutes: 30
    )
  end

  test 'CF-R16 preserves positive durations clock ranges and title minus literals' do
    [
      {
        input: '明日10時から11時まで会議',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [60]
      },
      {
        input: '月曜10時にA−B比較、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['a−b比較', '設計確認'],
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '月曜10時にC-APIレビュー、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['c-apiレビュー', '設計確認'],
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '月曜10時にUTF−8確認、火曜11時に設計確認',
        provider: 'rails-local-multi-explicit-events-v1',
        titles: ['utf−8確認', '設計確認'],
        starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
        durations: [60, 60]
      },
      {
        input: '明日10時に会議を30分',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [30]
      },
      {
        input: "明日10時に会議を\n30分",
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [30]
      },
      {
        input: '明日10時に会議を1.5時間',
        provider: 'rails-local-single-explicit-v5',
        titles: ['会議'],
        starts: ['2026-08-16T10:00:00+09:00'],
        durations: [90]
      }
    ].each do |test_case|
      assert_multi_event_contract(
        test_case.fetch(:input),
        expected_provider: test_case.fetch(:provider),
        expected_titles: test_case.fetch(:titles),
        expected_starts: test_case.fetch(:starts),
        expected_durations: test_case.fetch(:durations)
      )
    end

    ["明日10時-\n11時に会議", "明日10時〜\n11時に会議"].each do |input|
      assert_zero_candidate_contract(
        input,
        expected_provider: 'rails-local-multi-explicit-clarification-v1'
      )
    end
  end

  test 'CF-R16 keeps duration gaps local to duration tokens and preserves clause boundaries' do
    [
      [
        "明日の予定候補:\n1) 10時に会議\n2) 11時に資料作成",
        'rails-local-multi-explicit-events-v1',
        %w[会議 資料作成],
        %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      ],
      [
        "月曜10時に会議\n火曜11時に設計確認",
        'rails-local-multi-explicit-events-v1',
        %w[会議 設計確認],
        %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00]
      ],
      [
        "明日の予定候補:\r\n1) 10時に会議\r\n2) 11時に資料作成",
        'rails-local-multi-explicit-events-v1',
        %w[会議 資料作成],
        %w[2026-08-16T10:00:00+09:00 2026-08-16T11:00:00+09:00]
      ]
    ].each do |input, provider, titles, starts|
      assert_multi_event_contract(
        input,
        expected_provider: provider,
        expected_titles: titles,
        expected_starts: starts,
        expected_durations: [60, 60]
      )
    end

    normalization_client = Ai::Client.new(context: BASE_CONTEXT, user_message: '確認')
    ["\u2028", "\u2029"].each do |separator|
      source = "前半#{separator}後半"
      normalized = normalization_client.send(:normalize_japanese, source)
      assert_includes normalized, separator, "source=#{source.inspect} normalized=#{normalized.inspect}"

      assert_zero_candidate_contract(
        "月曜10時に会議#{separator}火曜11時に設計確認",
        expected_provider: 'rails-local-weekday-multi-event-clarification-v1'
      )
    end

    assert_syntax_clarification_contract(
      "月曜10時に「会議\n火曜11時に設計確認",
      expected_error_kind: :unmatched_opening
    )
    assert_syntax_clarification_contract(
      "明日10時に「会議を−\n30分",
      expected_error_kind: :unmatched_opening
    )
    assert_multi_event_contract(
      '月曜10時に会議．火曜11時に設計確認の予定候補を作成してください',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: %w[会議 設計確認],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T11:00:00+09:00],
      expected_durations: [60, 60]
    )
    assert_multi_event_contract(
      '月曜と火曜の10時に会議の予定候補を作って',
      expected_provider: 'rails-local-weekday-multi-event-v1',
      expected_titles: %w[会議 会議],
      expected_starts: %w[2026-08-17T10:00:00+09:00 2026-08-18T10:00:00+09:00],
      expected_durations: [60, 60]
    )
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
