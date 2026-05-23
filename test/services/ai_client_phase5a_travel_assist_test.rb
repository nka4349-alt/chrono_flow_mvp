# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientPhase5aTravelAssistTest < ActiveSupport::TestCase
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

  test 'location schedule asks whether travel time should be added' do
    response = ai_response('明日10時に大阪駅で会議')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal '会議', recommendation.fetch('title')
    assert_equal '大阪駅', payload.fetch('location')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_includes response.fetch(:assistant_message), '移動時間'
    assert_includes response.fetch(:assistant_message), '出発地'
    assert_equal 'rails-local-travel-assist-location-v1', response.fetch(:provider)
  end

  test 'explicit travel duration creates travel event and main event bundle' do
    response = ai_response('明日10時に大阪駅で会議、移動時間30分')
    recommendation = first_recommendation(response)
    events = recommendation.fetch('payload').fetch('events')

    assert_equal '移動込み: 会議', recommendation.fetch('title')
    assert_equal 2, events.length

    travel = events[0]
    main = events[1]

    assert_equal '移動: 大阪駅へ', travel.fetch('title')
    assert_equal Time.iso8601('2026-05-19T09:30:00+09:00'), Time.iso8601(travel.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(travel.fetch('end_at'))
    assert_equal 'travel', travel.fetch('schedule_profile')
    assert_equal 'travel', travel.fetch('intent')

    assert_equal '会議', main.fetch('title')
    assert_equal '大阪駅', main.fetch('location')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(main.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(main.fetch('end_at'))
  end

  test 'origin destination travel duration and arrival buffer are reflected' do
    response = ai_response('自宅から大阪駅まで45分、明日10時に会議、15分前に到着')
    recommendation = first_recommendation(response)
    events = recommendation.fetch('payload').fetch('events')
    travel = events[0]
    main = events[1]

    assert_equal '移動: 自宅 → 大阪駅', travel.fetch('title')
    assert_equal Time.iso8601('2026-05-19T09:00:00+09:00'), Time.iso8601(travel.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T09:45:00+09:00'), Time.iso8601(travel.fetch('end_at'))
    assert_equal '大阪駅', travel.fetch('location')
    assert_equal 15, travel.fetch('buffer_minutes')
    assert_equal 45, travel.fetch('travel_assist').fetch('travel_minutes')

    assert_equal '会議', main.fetch('title')
    assert_equal '大阪駅', main.fetch('location')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(main.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(main.fetch('end_at'))
    assert_equal 15, main.fetch('buffer_minutes')
    assert_equal 15, main.fetch('travel_assist').fetch('arrival_buffer_minutes')
  end

  test 'travel conflict asks for adjustment instead of creating unsafe bundle' do
    existing = {
      id: 801,
      title: '朝会',
      start_at: '2026-05-19T09:00:00+09:00',
      end_at: '2026-05-19T09:30:00+09:00',
      all_day: false
    }

    response = ai_response('自宅から大阪駅まで30分、明日10時に会議、15分前に到着', context: { personal_events: [existing] })

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '移動時間'
    assert_includes response.fetch(:assistant_message), '朝会'
    assert_includes response.fetch(:assistant_message), '重なります'
  end

  test 'travel duration without destination asks clarification' do
    response = ai_response('明日10時に会議、移動時間30分')

    assert_empty recommendations(response)
    assert_includes response.fetch(:assistant_message), '目的地'
  end
end
