# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientMemoryRagTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-18T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: [],
    user_places: [],
    user_travel_routes: [],
    ai_user_preferences: []
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def first_recommendation(response)
    response.fetch(:recommendations).first
  end

  test 'home place memory candidate' do
    response = ai_response('自宅は天王寺駅です')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal 1, response.fetch(:recommendations).length
    assert_equal 'memory_save', recommendation.fetch('kind')
    assert_equal 'user_place', payload.fetch('memory_type')
    assert_equal 'home', payload.fetch('kind')
    assert_equal '自宅', payload.fetch('label')
    assert_equal '天王寺駅', payload.fetch('place_name')
    assert_match(/記憶|保存/, response.fetch(:assistant_message))
  end

  test 'work place memory candidate' do
    response = ai_response('勤務先は梅田です')
    payload = first_recommendation(response).fetch('payload')

    assert_equal 'user_place', payload.fetch('memory_type')
    assert_equal 'work', payload.fetch('kind')
    assert_equal '勤務先', payload.fetch('label')
    assert_equal '梅田', payload.fetch('place_name')
  end

  test 'route memory candidate' do
    response = ai_response('自宅から大阪駅まで30分')
    payload = first_recommendation(response).fetch('payload')

    assert_equal 'memory_save', first_recommendation(response).fetch('kind')
    assert_equal 'user_travel_route', payload.fetch('memory_type')
    assert_equal '自宅', payload.fetch('origin_name')
    assert_equal 'home', payload.fetch('origin_kind')
    assert_equal '大阪駅', payload.fetch('destination_name')
    assert_equal 30, payload.fetch('travel_minutes')
  end

  test 'arrival buffer preference memory candidate' do
    response = ai_response('会議は15分前に着きたい')
    payload = first_recommendation(response).fetch('payload')

    assert_equal 'memory_save', first_recommendation(response).fetch('kind')
    assert_equal 'ai_user_preference', payload.fetch('memory_type')
    assert_equal 'arrival_buffer.meeting', payload.fetch('key')
    assert_equal '15', payload.fetch('value')
    assert_equal 'integer', payload.fetch('value_type')
  end

  test 'hospital arrival buffer preference memory candidate' do
    response = ai_response('病院は30分前に着きたい')
    payload = first_recommendation(response).fetch('payload')

    assert_equal 'ai_user_preference', payload.fetch('memory_type')
    assert_equal 'arrival_buffer.hospital', payload.fetch('key')
    assert_equal '30', payload.fetch('value')
  end

  test 'uses saved travel memories for location schedule' do
    response = ai_response(
      '明日10時に大阪駅で会議',
      context: {
        user_places: [
          { kind: 'home', label: '自宅', place_name: '天王寺駅' },
          { kind: 'work', label: '勤務先', place_name: '梅田' }
        ],
        user_travel_routes: [
          { id: 1, origin_name: '自宅', origin_kind: 'home', destination_name: '大阪駅', travel_minutes: 30, transport_mode: 'train' },
          { id: 2, origin_name: '勤務先', origin_kind: 'work', destination_name: '大阪駅', travel_minutes: 15, transport_mode: 'train' }
        ],
        ai_user_preferences: [
          { key: 'arrival_buffer.meeting', value: '15', value_type: 'integer' }
        ]
      }
    )

    recommendations = response.fetch(:recommendations)
    assert_equal 3, recommendations.length

    meeting_only = recommendations[0]
    assert_equal '会議', meeting_only.fetch('title')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(meeting_only.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(meeting_only.fetch('end_at'))
    assert_equal '大阪駅', meeting_only.fetch('payload').fetch('location')

    home_events = recommendations[1].fetch('payload').fetch('events')
    assert_equal '移動: 自宅 → 大阪駅', home_events[0].fetch('title')
    assert_equal Time.iso8601('2026-05-19T09:15:00+09:00'), Time.iso8601(home_events[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T09:45:00+09:00'), Time.iso8601(home_events[0].fetch('end_at'))
    assert_equal '会議', home_events[1].fetch('title')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(home_events[1].fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(home_events[1].fetch('end_at'))

    work_events = recommendations[2].fetch('payload').fetch('events')
    assert_equal '移動: 勤務先 → 大阪駅', work_events[0].fetch('title')
    assert_equal Time.iso8601('2026-05-19T09:30:00+09:00'), Time.iso8601(work_events[0].fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T09:45:00+09:00'), Time.iso8601(work_events[0].fetch('end_at'))
    assert_equal '会議', work_events[1].fetch('title')
  end

  test 'no memory fallback keeps normal location schedule without forced question' do
    response = ai_response('明日10時に大阪駅で会議')
    recommendation = first_recommendation(response)

    assert_equal 1, response.fetch(:recommendations).length
    assert_equal '会議', recommendation.fetch('title')
    assert_equal '大阪駅', recommendation.fetch('payload').fetch('location')
    refute_includes response.fetch(:assistant_message), '出発地'
    refute_includes response.fetch(:assistant_message), '何分前'
  end
end
