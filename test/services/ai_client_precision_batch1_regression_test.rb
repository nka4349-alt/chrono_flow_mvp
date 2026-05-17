# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientPrecisionBatch1RegressionTest < ActiveSupport::TestCase
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
    id: 301,
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

  test 'pm time is parsed as afternoon and uppercase title is preserved' do
    response = ai_response('明日PM3時に営業MTG')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 5, 18), start_at.to_date
    assert_equal 15, start_at.hour
    assert_equal '営業MTG', recommendation.fetch('title')
  end

  test 'night time is parsed as evening and date words are removed from title' do
    response = ai_response('あしたのよる8時に読書')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 5, 18), start_at.to_date
    assert_equal 20, start_at.hour
    assert_equal '読書', recommendation.fetch('title')
  end

  test 'three days later is parsed relative to current date' do
    response = ai_response('三日後の朝に資料確認')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 5, 20), start_at.to_date
    assert_equal '資料確認', recommendation.fetch('title')
  end

  test 'one and a half hours duration is parsed as ninety minutes' do
    response = ai_response('明日10時から1時間半会議')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal Date.new(2026, 5, 18), start_at.to_date
    assert_equal 10, start_at.hour
    assert_equal 90, ((end_at - start_at) / 60).to_i
    assert_equal '会議', recommendation.fetch('title')
  end

  test 'delete intent recognizes erase wording' do
    response = ai_response('英語学習を消して', context: { personal_events: [ENGLISH_EVENT] })
    recommendation = first_recommendation(response)

    assert_equal 'event_delete', recommendation.fetch('kind')
    assert_equal 301, recommendation.fetch('source_event_id')
  end

  test 'zoom title preserves original uppercase' do
    response = ai_response('明日10時にZoom会議')
    recommendation = first_recommendation(response)

    assert_equal 'Zoom会議', recommendation.fetch('title')
  end

  test 'api title preserves original uppercase' do
    response = ai_response('明日10時にAPI設計レビュー')
    recommendation = first_recommendation(response)

    assert_equal 'API設計レビュー', recommendation.fetch('title')
  end
end
