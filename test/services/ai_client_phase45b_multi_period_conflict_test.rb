# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientPhase45bMultiPeriodConflictTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-18T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def recommendations(response)
    response.fetch(:recommendations)
  end

  def first_recommendation(response)
    recommendations(response).first
  end

  test 'multiple explicit timed events are split' do
    response = ai_response('明日10時に会議、11時に資料作成')
    recs = recommendations(response)

    assert_equal 2, recs.length
    assert_equal '会議', recs[0].fetch('title')
    assert_equal '資料作成', recs[1].fetch('title')

    first_start = Time.iso8601(recs[0].fetch('start_at'))
    first_end = Time.iso8601(recs[0].fetch('end_at'))
    second_start = Time.iso8601(recs[1].fetch('start_at'))
    second_end = Time.iso8601(recs[1].fetch('end_at'))

    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), first_start
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), first_end
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), second_start
    assert_equal Time.iso8601('2026-05-19T12:00:00+09:00'), second_end
    assert_includes response.fetch(:assistant_message), '2件'
  end

  test 'multiple explicit timed events with durations are split' do
    response = ai_response('明日10時に30分電話、11時から1時間資料作成')
    recs = recommendations(response)

    assert_equal 2, recs.length
    assert_equal '電話', recs[0].fetch('title')
    assert_equal '資料作成', recs[1].fetch('title')

    first_start = Time.iso8601(recs[0].fetch('start_at'))
    first_end = Time.iso8601(recs[0].fetch('end_at'))
    second_start = Time.iso8601(recs[1].fetch('start_at'))
    second_end = Time.iso8601(recs[1].fetch('end_at'))

    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), first_start
    assert_equal Time.iso8601('2026-05-19T10:30:00+09:00'), first_end
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), second_start
    assert_equal Time.iso8601('2026-05-19T12:00:00+09:00'), second_end
  end

  test 'partial multi intent asks clarification' do
    response = ai_response('明日10時に会議、資料作成')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '資料作成'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'weekend trip becomes all day period event' do
    response = ai_response('土日で旅行')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal '旅行', recommendation.fetch('title')
    assert_equal true, recommendation.fetch('all_day')
    assert_equal Time.iso8601('2026-05-23T00:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-25T00:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal true, payload.fetch('all_day')
  end

  test 'next weekend trip becomes next all day period event' do
    response = ai_response('来週末に旅行')
    recommendation = first_recommendation(response)

    assert_equal '旅行', recommendation.fetch('title')
    assert_equal true, recommendation.fetch('all_day')
    assert_equal Time.iso8601('2026-05-30T00:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-06-01T00:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
  end

  test 'weekend without title asks clarification' do
    response = ai_response('土日で予定')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '予定内容'
  end

  test 'all day and time contradiction asks clarification' do
    response = ai_response('明日終日で10時から会議')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '終日'
    assert_includes response.fetch(:assistant_message), '10時'
    assert_includes response.fetch(:assistant_message), 'どちら'
  end

  test 'date weekday mismatch asks clarification' do
    response = ai_response('2026年5月18日金曜に会議')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '2026年5月18日'
    assert_includes response.fetch(:assistant_message), '月曜'
    assert_includes response.fetch(:assistant_message), '金曜'
  end

  test 'morning and night conflict asks clarification' do
    response = ai_response('明日朝夜に勉強')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '朝'
    assert_includes response.fetch(:assistant_message), '夜'
  end
end
