# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientProductionRetestRegressionTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-17T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  MEETING_EVENT = {
    id: 201,
    title: '会議',
    start_at: '2026-05-18T10:00:00+09:00',
    end_at: '2026-05-18T11:00:00+09:00',
    all_day: false
  }.freeze

  TANAKA_DISCUSSION_EVENT = {
    id: 202,
    title: '田中と打ち合わせ',
    start_at: '2026-05-18T15:00:00+09:00',
    end_at: '2026-05-18T16:00:00+09:00',
    all_day: false
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def first_recommendation(response)
    response.fetch(:recommendations).first
  end

  test 'this week weekday request does not choose an already past weekday' do
    response = ai_response('今週金曜15時に会議')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 5, 22), start_at.to_date
    assert_equal 15, start_at.hour
  end

  test 'meeting update does not treat discussion event as the same target' do
    response = ai_response(
      '明日の会議を16時に変更',
      context: { personal_events: [MEETING_EVENT, TANAKA_DISCUSSION_EVENT] }
    )
    recommendation = first_recommendation(response)

    assert_equal 'rails-local-existing-event-update-v1', response.fetch(:provider)
    assert_equal 'event_update', recommendation.fetch('kind')
    assert_equal 201, recommendation.fetch('source_event_id')
  end

  test 'discussion delete still matches honorific request wording' do
    response = ai_response(
      '田中さんとの打ち合わせを削除',
      context: { personal_events: [TANAKA_DISCUSSION_EVENT] }
    )
    recommendation = first_recommendation(response)

    assert_equal 'rails-local-existing-event-delete-v1', response.fetch(:provider)
    assert_equal 202, recommendation.fetch('source_event_id')
  end

  test 'time of day only does not become the event title' do
    response = ai_response('再来週月曜の朝')
    recommendation = first_recommendation(response)

    refute_equal '朝', recommendation.fetch('title')
    assert_equal '予定', recommendation.fetch('title')
  end

  test 'morning phrase is removed from nth weekday regular meeting title' do
    response = ai_response('来月の第一月曜の朝に定例会を入れて')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 6, 1), start_at.to_date
    assert_equal '定例会', recommendation.fetch('title')
  end

  test 'subject study title with ascii uppercase is preserved' do
    response = ai_response('明日17時に学校Aの復習')
    recommendation = first_recommendation(response)

    assert_equal '学校Aの復習', recommendation.fetch('title')
    assert_equal '学校Aの復習', recommendation.fetch('payload').fetch('title')
  end
end
