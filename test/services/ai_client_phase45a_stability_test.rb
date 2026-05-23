# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientPhase45aStabilityTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-18T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  TANAKA_EVENT = {
    id: 701,
    title: '田中と打ち合わせ',
    start_at: '2026-05-19T15:00:00+09:00',
    end_at: '2026-05-19T16:00:00+09:00',
    all_day: false
  }.freeze

  MEETING_EVENT = {
    id: 702,
    title: '会議',
    start_at: '2026-05-19T10:00:00+09:00',
    end_at: '2026-05-19T11:00:00+09:00',
    all_day: false
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def first_recommendation(response)
    response.fetch(:recommendations).first
  end

  test 'conflicting explicit timed event warns and returns alternative' do
    response = ai_response('明日の15時に30分電話', context: { personal_events: [TANAKA_EVENT] })
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_includes response.fetch(:assistant_message), '重なります'
    assert_includes response.fetch(:assistant_message), '田中と打ち合わせ'
    assert_equal '電話', recommendation.fetch('title')
    assert_equal Date.new(2026, 5, 19), start_at.to_date
    assert_equal 16, start_at.hour
    assert_equal 0, start_at.min
    assert_equal 16, end_at.hour
    assert_equal 30, end_at.min
    assert_equal false, recommendation.fetch('all_day')
  end

  test 'date only schedule asks clarification' do
    response = ai_response('明日予定入れて')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '内容と時間'
  end

  test 'date and person only schedule asks clarification' do
    response = ai_response('明日田中さん')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '内容'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'vague open slot asks clarification' do
    response = ai_response('来週の空いてるところで')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '何を'
    assert_includes response.fetch(:assistant_message), 'どれくらい'
  end

  test 'negative reminder is rejected' do
    response = ai_response('明日の会議の-10分前に通知', context: { personal_events: [MEETING_EVENT] })

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '指定できません'
    assert_includes response.fetch(:assistant_message), '正の時間'
  end

  test 'reminder without explicit timing asks clarification' do
    response = ai_response('会議の前に通知して', context: { personal_events: [MEETING_EVENT] })

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '何分前'
  end

  test 'explicit valid reminder still works' do
    response = ai_response('田中さんとの打ち合わせの1時間前にリマインダー', context: { personal_events: [TANAKA_EVENT] })
    recommendation = first_recommendation(response)

    assert_equal 'event_reminder', recommendation.fetch('kind')
    assert_equal 701, recommendation.fetch('source_event_id')
    assert_equal 60, recommendation.fetch('payload').fetch('minutes_before')
  end
end
