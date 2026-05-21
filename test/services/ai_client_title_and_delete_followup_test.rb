# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientTitleAndDeleteFollowupTest < ActiveSupport::TestCase
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
    id: 501,
    title: '田中と打ち合わせ',
    start_at: '2026-05-19T15:00:00+09:00',
    end_at: '2026-05-19T16:00:00+09:00',
    all_day: false
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def first_recommendation(response)
    response.fetch(:recommendations).first
  end

  test 'hiragana irete suffix is removed from event title' do
    response = ai_response('明日の10時から営業いれて')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 5, 19), start_at.to_date
    assert_equal 10, start_at.hour
    assert_equal '営業', recommendation.fetch('title')
    assert_equal '営業', payload.fetch('title')
    assert_includes response.fetch(:assistant_message), '営業'
    refute_includes response.fetch(:assistant_message), '営業いれて'
  end

  test 'kanji irete suffix still works' do
    response = ai_response('明日の10時から営業入れて')
    recommendation = first_recommendation(response)

    assert_equal '営業', recommendation.fetch('title')
    assert_equal '営業', recommendation.fetch('payload').fetch('title')
  end

  test 'delete target matching tolerates san tono versus to wording' do
    response = ai_response(
      '田中さんとの打ち合わせを削除',
      context: { personal_events: [TANAKA_EVENT] }
    )
    recommendation = first_recommendation(response)

    assert_equal 'event_delete', recommendation.fetch('kind')
    assert_equal 501, recommendation.fetch('source_event_id')
  end
end
