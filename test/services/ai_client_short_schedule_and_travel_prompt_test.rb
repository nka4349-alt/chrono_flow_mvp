# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientShortScheduleAndTravelPromptTest < ActiveSupport::TestCase
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

  def first_recommendation(response)
    response.fetch(:recommendations).first
  end

  test 'one word activity creates open slot candidate' do
    response = ai_response('挨拶')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_operator response.fetch(:recommendations).length, :>=, 1
    assert_equal '挨拶', recommendation.fetch('title')
    assert_equal false, recommendation.fetch('all_day')
    assert_operator start_at, :>, Time.iso8601(BASE_CONTEXT.fetch(:now))
    assert_includes response.fetch(:assistant_message), '時間指定がない'
    assert_includes response.fetch(:assistant_message), '候補'
  end

  test 'one word activity avoids existing event' do
    existing = {
      id: 902,
      title: '朝会',
      start_at: '2026-05-18T09:00:00+09:00',
      end_at: '2026-05-18T10:00:00+09:00',
      all_day: false
    }

    response = ai_response('挨拶', context: { personal_events: [existing] })
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))
    existing_start = Time.iso8601(existing.fetch(:start_at))
    existing_end = Time.iso8601(existing.fetch(:end_at))

    assert_equal '挨拶', recommendation.fetch('title')
    refute_equal existing_start, start_at
    assert end_at <= existing_start || start_at >= existing_end
  end

  test 'generic short content is still rejected' do
    response = ai_response('予定')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '内容'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'short explicit title with date and time creates event' do
    response = ai_response('明日、08:00に挨拶')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal 1, response.fetch(:recommendations).length
    assert_equal '挨拶', recommendation.fetch('title')
    assert_equal '挨拶', payload.fetch('title')
    assert_equal Time.iso8601('2026-05-19T08:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T09:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal false, recommendation.fetch('all_day')
    assert_match(/rails-local-single-explicit/, response.fetch(:provider))
  end

  test 'short explicit title with location creates event' do
    response = ai_response('明日、新しい職場に08:00に挨拶')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal '挨拶', recommendation.fetch('title')
    assert_equal '挨拶', payload.fetch('title')
    assert_equal '新しい職場', payload.fetch('location')
    assert_equal Time.iso8601('2026-05-19T08:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T09:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_equal false, recommendation.fetch('all_day')
  end

  test 'date and content without time creates candidate in open slot' do
    existing = {
      id: 901,
      title: '朝会',
      start_at: '2026-05-19T09:00:00+09:00',
      end_at: '2026-05-19T10:00:00+09:00',
      all_day: false
    }

    response = ai_response('明日挨拶', context: { personal_events: [existing] })
    recommendation = first_recommendation(response)

    assert_operator response.fetch(:recommendations).length, :>=, 1
    assert_equal '挨拶', recommendation.fetch('title')
    assert_equal false, recommendation.fetch('all_day')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_includes response.fetch(:assistant_message), '時間指定がない'
    assert_includes response.fetch(:assistant_message), '候補'
  end

  test 'generic date only still asks clarification' do
    response = ai_response('明日予定入れて')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '内容'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'person only date still asks clarification' do
    response = ai_response('明日田中さん')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '内容'
    assert_includes response.fetch(:assistant_message), '時間'
  end

  test 'time range with made does not become location' do
    response = ai_response('明日10時から11時まで会議')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal '会議', recommendation.fetch('title')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    refute payload.key?('location')
    refute_includes response.fetch(:assistant_message), '移動時間も予定'
    refute_equal 'ま', payload['location']
  end

  test 'plain location schedule does not force travel questions' do
    response = ai_response('明日10時に大阪駅で会議')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal '会議', recommendation.fetch('title')
    assert_equal '大阪駅', payload.fetch('location')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(recommendation.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(recommendation.fetch('end_at'))
    assert_includes response.fetch(:assistant_message), '移動時間30分'
    refute_includes response.fetch(:assistant_message), '出発地'
    refute_includes response.fetch(:assistant_message), '何分前'
    assert_equal 'rails-local-single-explicit-v5', response.fetch(:provider)
  end

  test 'explicit travel duration still creates travel bundle' do
    response = ai_response('明日10時に大阪駅で会議、移動時間30分')
    recommendation = first_recommendation(response)
    events = recommendation.fetch('payload').fetch('events')
    travel = events[0]
    main = events[1]

    assert_equal 2, events.length
    assert_equal '移動: 大阪駅へ', travel.fetch('title')
    assert_equal Time.iso8601('2026-05-19T09:30:00+09:00'), Time.iso8601(travel.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(travel.fetch('end_at'))
    assert_equal '会議', main.fetch('title')
    assert_equal '大阪駅', main.fetch('location')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(main.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(main.fetch('end_at'))
  end

  test 'route and arrival buffer still create travel bundle' do
    response = ai_response('自宅から大阪駅まで45分、明日10時に会議、15分前に到着')
    recommendation = first_recommendation(response)
    events = recommendation.fetch('payload').fetch('events')
    travel = events[0]
    main = events[1]

    assert_equal 2, events.length
    assert_equal '移動: 自宅 → 大阪駅', travel.fetch('title')
    assert_equal Time.iso8601('2026-05-19T09:00:00+09:00'), Time.iso8601(travel.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T09:45:00+09:00'), Time.iso8601(travel.fetch('end_at'))
    assert_equal '会議', main.fetch('title')
    assert_equal Time.iso8601('2026-05-19T10:00:00+09:00'), Time.iso8601(main.fetch('start_at'))
    assert_equal Time.iso8601('2026-05-19T11:00:00+09:00'), Time.iso8601(main.fetch('end_at'))
    assert_equal 15, main.fetch('travel_assist').fetch('arrival_buffer_minutes')
  end
end
