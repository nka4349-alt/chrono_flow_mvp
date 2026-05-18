# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientPrecisionBatch1FollowupTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-17T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  ENGLISH_EVENT = {
    id: 401,
    title: '英語学習',
    start_at: '2026-05-18T17:00:00+09:00',
    end_at: '2026-05-18T18:00:00+09:00',
    all_day: false
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  def first_recommendation(response)
    response.fetch(:recommendations).first
  end

  test 'one and a half hours does not leave half in title' do
    response = ai_response('明日10時から1時間半会議')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal Date.new(2026, 5, 18), start_at.to_date
    assert_equal 10, start_at.hour
    assert_equal 90, ((end_at - start_at) / 60).to_i
    assert_equal '会議', recommendation.fetch('title')
    refute_includes recommendation.fetch('title'), '半'
  end

  test 'erase wording creates delete recommendation instead of new event' do
    response = ai_response('英語学習を消して', context: { personal_events: [ENGLISH_EVENT] })
    recommendation = first_recommendation(response)

    assert_equal 'event_delete', recommendation.fetch('kind')
    assert_equal 401, recommendation.fetch('source_event_id')
    assert_equal '英語学習', recommendation.fetch('payload').fetch('title')
  end

  test 'uppercase title is preserved in recommendation and payload for sales mtg' do
    response = ai_response('明日PM3時に営業MTG')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal '営業MTG', recommendation.fetch('title')
    assert_equal '営業MTG', payload.fetch('title')
    assert_includes response.fetch(:assistant_message), '営業MTG'
    refute_includes response.fetch(:assistant_message), '営業mtg'
  end

  test 'uppercase title is preserved in recommendation and payload for zoom meeting' do
    response = ai_response('明日10時にZoom会議')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal 'Zoom会議', recommendation.fetch('title')
    assert_equal 'Zoom会議', payload.fetch('title')
    assert_includes response.fetch(:assistant_message), 'Zoom会議'
    refute_includes response.fetch(:assistant_message), 'zoom会議'
  end

  test 'uppercase title is preserved in recommendation and payload for api review' do
    response = ai_response('明日10時にAPI設計レビュー')
    recommendation = first_recommendation(response)
    payload = recommendation.fetch('payload')

    assert_equal 'API設計レビュー', recommendation.fetch('title')
    assert_equal 'API設計レビュー', payload.fetch('title')
    assert_includes response.fetch(:assistant_message), 'API設計レビュー'
    refute_includes response.fetch(:assistant_message), 'api設計レビュー'
  end
end
