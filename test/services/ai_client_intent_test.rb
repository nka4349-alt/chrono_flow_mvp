# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientIntentTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-09T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  test 'explicit time is honored for a meeting request' do
    response = ai_response('明日の15時から30分、田中さんと打ち合わせを入れて')
    recommendation = response.fetch(:recommendations).first
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
    assert_includes recommendation.fetch('title'), '打ち合わせ'
    assert_equal 15, start_at.hour
    assert_equal 0, start_at.min
    assert_equal 30, ((end_at - start_at) / 60).round
  end

  test 'date cleanup strips leading Japanese punctuation from title' do
    response = ai_response('明日、神奈川に帰る')
    recommendation = response.fetch(:recommendations).first

    assert_equal '神奈川に帰る', recommendation.fetch('title')
    assert_equal '神奈川に帰る', recommendation.fetch('payload').fetch('title')
  end

  test 'invalid 25 hour request is not clamped to 23 oclock' do
    response = ai_response('明日の25時に予定を入れて')

    assert_equal 'rails-local-time-validation-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '25時'
    assert_includes response.fetch(:assistant_message), '自動変換せず'
  end

  test 'focus work request stays focus work' do
    response = ai_response('来週どこかで集中作業の時間を作って')
    recommendation = response.fetch(:recommendations).first

    assert_equal 'rails-local-focus-work-v1', response.fetch(:provider)
    assert_equal '集中作業', recommendation.fetch('title')
    assert_equal 'focus_work', recommendation.fetch('payload').fetch('intent')
    assert_equal 'focus_work', recommendation.fetch('payload').fetch('schedule_profile')
    refute_includes recommendation.fetch('title'), '関係者調整'
  end

  test 'schedule organization request does not create new event candidates' do
    response = ai_response('予定が多すぎるので今週を整理したい')

    assert_equal 'rails-local-schedule-organization-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '新しい予定候補は作らず'
    assert_includes response.fetch(:assistant_message), '棚卸し'
  end
end
