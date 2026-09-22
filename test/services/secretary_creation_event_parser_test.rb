# frozen_string_literal: true

require 'test_helper'

class SecretaryCreationEventParserTest < ActiveSupport::TestCase
  setup do
    @user = User.new(id: 1, name: 'Test')
    @now = Time.zone.parse('2026-09-20 09:00:00')
  end

  test 'explicit timing is preserved and no default duration or date is guessed' do
    start_only = parse('今日18時に来客を入れて')
    assert_equal 'needs_clarification', start_only[:status]
    assert_equal '終了時刻または所要時間を教えてください。例：「10時まで」「1時間」', start_only[:question]
    assert_equal 'needs_clarification', parse('18時から19時まで来客を入れて')[:status]
    assert_equal 'needs_clarification', parse('明日来客を入れて')[:status]
    result = parse('今日18時に来客を入れて', '1時間')
    assert_equal 'ready', result[:status], result.inspect
    assert_equal '2026-09-20T19:00:00+09:00', result.dig(:details, 'end_at')
  end

  test 'single message accepts an explicit range or duration without another question' do
    messages = [
      '明日9時から10時までピクニックに行く予定を登録して',
      '明日9時から1時間、ピクニックに行く予定を登録して',
      '明日9時、60分でピクニックに行く予定を登録して'
    ]

    results = messages.map { |message| parse(message) }

    results.each do |result|
      assert_equal 'ready', result[:status], result.inspect
      assert_equal '2026-09-21T09:00:00+09:00', result.dig(:details, 'start_at')
      assert_equal '2026-09-21T10:00:00+09:00', result.dig(:details, 'end_at')
    end
  end

  test 'missing both times asks once for a range and a range answer preserves the original title' do
    original = '明日ピクニックに行く予定を登録して'
    question = parse(original)

    assert_equal 'needs_clarification', question[:status]
    assert_equal '開始時刻と、終了時刻または所要時間をまとめて教えてください。例：「9時から10時」「9時から1時間」', question[:question]

    result = parse(original, '9時から10時')
    assert_equal 'ready', result[:status], result.inspect
    assert_equal '2026-09-21T09:00:00+09:00', result.dig(:details, 'start_at')
    assert_equal '2026-09-21T10:00:00+09:00', result.dig(:details, 'end_at')
    assert_equal 'ピクニックに行く予定', result.dig(:details, 'title')
    refute_match(/9時|10時/, result.dig(:details, 'title'))
  end

  test 'start-only request accepts bare end clocks and duration answers' do
    original = '明日9時にピクニックに行く予定を登録して'
    answers = ['10時', '10:00', '10;00', '10時まで', '終了は10時', '1時間', '60分']

    answers.each do |answer|
      result = parse(original, answer)
      assert_equal 'ready', result[:status], "#{answer}: #{result.inspect}"
      assert_equal '2026-09-21T09:00:00+09:00', result.dig(:details, 'start_at')
      assert_equal '2026-09-21T10:00:00+09:00', result.dig(:details, 'end_at')
      assert_equal 'ピクニックに行く予定', result.dig(:details, 'title')
      refute_match(/#{Regexp.escape(answer)}/, result.dig(:details, 'title'))
    end
  end

  test 'invalid ambiguous or non-increasing follow-up end stays non-executable' do
    original = '明日9時にピクニックに行く予定を登録して'

    ['8時', '10時か11時', '25時'].each do |answer|
      result = parse(original, answer)
      assert_equal 'needs_clarification', result[:status], "#{answer}: #{result.inspect}"
      assert_nil result[:details]
    end

    corrected = parse(original, '25時', '10時')
    assert_equal 'ready', corrected[:status], corrected.inspect
    assert_equal '2026-09-21T10:00:00+09:00', corrected.dig(:details, 'end_at')
  end

  test 'non-increasing single-message range is not executable' do
    result = parse('明日10時から9時までピクニックに行く予定を登録して')

    assert_equal 'needs_clarification', result[:status]
    assert_nil result[:details]
  end

  test 'a full restatement replaces the original title and timing' do
    result = parse(
      '明日9時に古い会議を登録して',
      '明後日14時から15時まで新しい面談を登録して'
    )

    assert_equal 'ready', result[:status], result.inspect
    assert_equal '新しい面談', result.dig(:details, 'title')
    assert_equal '2026-09-22T14:00:00+09:00', result.dig(:details, 'start_at')
    assert_equal '2026-09-22T15:00:00+09:00', result.dig(:details, 'end_at')
    refute_match(/古い会議/, result.dig(:details, 'title'))
  end

  test 'parser canonicalizes control whitespace before returning executable details' do
    result = parse("予定名は「ピクニック\t会議」明日9時から10時まで登録して")

    assert_equal 'ready', result[:status], result.inspect
    assert_equal 'ピクニック 会議', result.dig(:details, 'title')
    refute_match(/\p{Cc}/, result.dig(:details, 'title'))
    refute_match(/\p{Cc}/, result.dig(:details, 'location'))
  end

  test 'parser canonicalizes provider title and location before binding confirmation details' do
    response = {
      recommendations: [{
        kind: 'draft_event', title: " Picnic\r\n\tMeeting ",
        start_at: '2026-09-21T09:00:00+09:00', end_at: '2026-09-21T10:00:00+09:00',
        payload: {
          title: " Picnic\r\n\tMeeting ", description: '', location: " Room\t A\n",
          start_at: '2026-09-21T09:00:00+09:00', end_at: '2026-09-21T10:00:00+09:00', all_day: false
        }
      }]
    }
    parser_class = Class.new(SecretaryCreation::EventParser) do
      define_method(:call) { response }
    end
    parser = parser_class.new(
      context: { scope: 'home', now: @now.iso8601, timezone: 'Asia/Tokyo' },
      user_message: '明日9時から10時まで会議を登録して'
    )

    result = parser.creation_candidate(['明日9時から10時まで会議を登録して'])

    assert_equal 'ready', result[:status], result.inspect
    assert_equal 'Picnic Meeting', result.dig(:details, 'title')
    assert_equal 'Room A', result.dig(:details, 'location')
  end

  test 'parser fails closed when the provider title is control-only or invalid UTF-8' do
    ["\t\r\n\u0001", "bad\xFF".b.force_encoding(Encoding::UTF_8)].each do |invalid_title|
      response = {
        recommendations: [{
          kind: 'draft_event', title: invalid_title,
          start_at: '2026-09-21T09:00:00+09:00', end_at: '2026-09-21T10:00:00+09:00',
          payload: {
            title: invalid_title, description: '', location: '',
            start_at: '2026-09-21T09:00:00+09:00', end_at: '2026-09-21T10:00:00+09:00', all_day: false
          }
        }]
      }
      parser_class = Class.new(SecretaryCreation::EventParser) do
        define_method(:call) { response }
      end
      parser = parser_class.new(
        context: { scope: 'home', now: @now.iso8601, timezone: 'Asia/Tokyo' },
        user_message: '明日9時から10時まで会議を登録して'
      )

      result = parser.creation_candidate(['明日9時から10時まで会議を登録して'])

      assert_equal 'needs_clarification', result[:status]
      assert_nil result[:details]
    end
  end

  test 'single all day preserves midnight and exclusive next day end' do
    result = parse('明日は終日休暇を予定に入れて')
    assert_equal 'ready', result[:status], result.inspect
    assert_equal true, result.dig(:details, 'all_day')
    assert_equal '休暇', result.dig(:details, 'title')
    assert_equal '2026-09-21T00:00:00+09:00', result.dig(:details, 'start_at')
    assert_equal '2026-09-22T00:00:00+09:00', result.dig(:details, 'end_at')
    SecretaryCreation::Contract.validate_details!(result[:details], provider: 'chrono_flow')
  end

  test 'invalid dates and unsupported multi or recurring requests never become executable' do
    [
      '2月30日18時から19時まで来客を追加', '明日25時から26時まで会議を追加',
      '毎週火曜18時から19時まで会議を追加', '明日18時から19時まで会議をグループに共有して',
      '明日18時から19時まで来客、20時から21時まで夕食を追加',
      '明日18時から19時まで会議を追加して15分前に通知して'
    ].each do |message|
      result = parse(message)
      refute_equal 'ready', result[:status], "#{message}: #{result.inspect}"
      assert_nil result[:details]
    end
  end

  test 'alternative dates or clock times and date ranges require clarification' do
    [
      '明日か明後日18時から19時まで来客を予定に追加',
      '明日18時か19時から1時間会議を追加',
      '明日18時から19時か20時まで会議を追加',
      '月曜または火曜18時から19時まで会議を追加',
      '明日から明後日まで終日休暇を予定に追加'
    ].each do |message|
      result = parse(message)
      assert_equal 'needs_clarification', result[:status], "#{message}: #{result.inspect}"
      assert_nil result[:details]
    end
  end

  private

  def parse(*messages)
    SecretaryCreation::EventParser.call(user: @user, messages: messages, now: @now)
  end
end
