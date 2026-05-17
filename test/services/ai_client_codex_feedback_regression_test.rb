# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientCodexFeedbackRegressionTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-17T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  TANAKA_EVENT = {
    id: 120,
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

  test 'delete target matching tolerates honorific and meeting wording differences' do
    response = ai_response('田中さんとの打ち合わせを削除', context: { personal_events: [TANAKA_EVENT] })
    recommendation = first_recommendation(response)

    assert_equal 'rails-local-existing-event-delete-v1', response.fetch(:provider)
    assert_equal 'event_delete', recommendation.fetch('kind')
    assert_equal 120, recommendation.fetch('source_event_id')
  end

  test 'reminder target matching tolerates honorific and meeting wording differences' do
    response = ai_response('田中さんとの打ち合わせの1時間前にリマインダー', context: { personal_events: [TANAKA_EVENT] })
    recommendation = first_recommendation(response)

    assert_equal 'rails-local-event-reminder-v1', response.fetch(:provider)
    assert_equal 'event_reminder', recommendation.fetch('kind')
    assert_equal 120, recommendation.fetch('source_event_id')
    assert_equal 60, recommendation.fetch('payload').fetch('minutes_before')
  end

  test 'all day single event message does not describe a default timed slot' do
    response = ai_response('明日終日で会議')
    recommendation = first_recommendation(response)

    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal true, recommendation.fetch('all_day')
    assert_includes response.fetch(:assistant_message), '終日'
    refute_includes response.fetch(:assistant_message), '9:00'
    refute_includes response.fetch(:assistant_message), '60分'
  end

  test 'short confirmation title removes leftover adverb and desire phrase' do
    response = ai_response('明日の朝イチで10分だけ確認したい')
    recommendation = first_recommendation(response)

    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_equal '確認', recommendation.fetch('title')
    assert_equal '確認', recommendation.fetch('payload').fetch('title')
  end

  test 'morning nth weekday title removes time of day phrase' do
    response = ai_response('来月の第一月曜の朝に定例会を入れて')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 6, 1), start_at.to_date
    refute_includes recommendation.fetch('title'), '朝'
    assert_includes recommendation.fetch('title'), '定例'
  end
end
