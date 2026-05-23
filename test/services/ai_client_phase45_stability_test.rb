# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientPhase45StabilityTest < ActiveSupport::TestCase
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

  test 'conflict explicit timed event returns warning and alternative' do
    response = ai_response(
      '明日の15時に30分電話',
      context: {
        personal_events: [
          {
            id: 701,
            title: '田中と打ち合わせ',
            start_at: '2026-05-19T15:00:00+09:00',
            end_at: '2026-05-19T16:00:00+09:00',
            all_day: false
          }
        ]
      }
    )
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_includes response.fetch(:assistant_message), '重なります'
    assert_includes response.fetch(:assistant_message), '田中と打ち合わせ'
    assert_equal '電話', recommendation.fetch('title')
    assert_equal Time.zone.parse('2026-05-19T16:00:00+09:00'), start_at
    assert_equal Time.zone.parse('2026-05-19T16:30:00+09:00'), end_at
    assert_equal false, recommendation.fetch('all_day')
  end

  test 'ambiguous date only schedule asks clarification' do
    response = ai_response('明日予定入れて')

    assert_empty response.fetch(:recommendations)
    assert_match(/情報が足りません|内容と時間/, response.fetch(:assistant_message))
  end

  test 'ambiguous person date asks clarification' do
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
    response = ai_response(
      '明日の会議の-10分前に通知',
      context: {
        personal_events: [
          {
            id: 702,
            title: '会議',
            start_at: '2026-05-19T10:00:00+09:00',
            end_at: '2026-05-19T11:00:00+09:00',
            all_day: false
          }
        ]
      }
    )

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '指定できません'
    assert_includes response.fetch(:assistant_message), '正の時間'
  end

  test 'reminder without timing asks clarification' do
    response = ai_response(
      '会議の前に通知して',
      context: {
        personal_events: [
          {
            id: 702,
            title: '会議',
            start_at: '2026-05-19T10:00:00+09:00',
            end_at: '2026-05-19T11:00:00+09:00',
            all_day: false
          }
        ]
      }
    )

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '何分前'
  end

  test 'explicit valid reminder still works' do
    response = ai_response(
      '田中さんとの打ち合わせの1時間前にリマインダー',
      context: {
        personal_events: [
          {
            id: 703,
            title: '田中と打ち合わせ',
            start_at: '2026-05-19T15:00:00+09:00',
            end_at: '2026-05-19T16:00:00+09:00',
            all_day: false
          }
        ]
      }
    )
    recommendation = first_recommendation(response)

    assert_equal 'event_reminder', recommendation.fetch('kind')
    assert_equal 703, recommendation.fetch('source_event_id')
    assert_equal 60, recommendation.fetch('payload').fetch('minutes_before')
  end

  test 'sales title cleanup remains stable' do
    response = ai_response('明日の10時から営業いれて')
    recommendation = first_recommendation(response)

    assert_equal '営業', recommendation.fetch('title')
    assert_equal '営業', recommendation.fetch('payload').fetch('title')
    assert_equal false, recommendation.fetch('all_day')
  end

  test 'delete matching remains stable for tanaka meeting' do
    response = ai_response(
      '田中さんとの打ち合わせを削除',
      context: {
        personal_events: [
          {
            id: 704,
            title: '田中と打ち合わせ',
            start_at: '2026-05-19T15:00:00+09:00',
            end_at: '2026-05-19T16:00:00+09:00',
            all_day: false
          }
        ]
      }
    )
    recommendation = first_recommendation(response)

    assert_equal 'event_delete', recommendation.fetch('kind')
    assert_equal 704, recommendation.fetch('source_event_id')
  end

  test 'ninety minute meeting remains stable' do
    response = ai_response('明日10時から1時間半会議')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal '会議', recommendation.fetch('title')
    assert_equal 90, ((end_at - start_at) / 60).round
  end

  test 'uppercase title cleanup remains stable' do
    response = ai_response('明日PM3時に営業MTG')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal '営業MTG', recommendation.fetch('title')
    assert_equal '営業MTG', recommendation.fetch('payload').fetch('title')
    assert_equal 15, start_at.hour
  end

  test 'zoom title cleanup remains stable' do
    response = ai_response('明日10時にZoom会議')
    recommendation = first_recommendation(response)

    assert_equal 'Zoom会議', recommendation.fetch('title')
    assert_equal 'Zoom会議', recommendation.fetch('payload').fetch('title')
  end

  test 'api title cleanup remains stable' do
    response = ai_response('明日10時にAPI設計レビュー')
    recommendation = first_recommendation(response)

    assert_equal 'API設計レビュー', recommendation.fetch('title')
    assert_equal 'API設計レビュー', recommendation.fetch('payload').fetch('title')
  end
end
