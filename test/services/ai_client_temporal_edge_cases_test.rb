# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientTemporalEdgeCasesTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-10T08:00:00+09:00',
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

  test 'evening request uses evening window and requested short duration' do
    response = ai_response('今日の夕方に15分だけメモ整理の時間を入れて')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal 'rails-local-focus-work-v1', response.fetch(:provider)
    assert_equal 'メモ整理', recommendation.fetch('title')
    assert_operator start_at.hour, :>=, 17
    assert_equal 15, ((end_at - start_at) / 60).round
  end

  test 'invalid explicit calendar date is not auto corrected' do
    response = ai_response('5月32日に予定を入れて')

    assert_equal 'rails-local-date-validation-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '5月32日'
    assert_includes response.fetch(:assistant_message), '自動補正せず'
  end

  test 'next month first monday morning is parsed' do
    response = ai_response('来月の第一月曜の朝にレビュー時間を作って')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 6, 1), start_at.to_date
    assert_equal 9, start_at.hour
    assert_equal 'レビュー時間', recommendation.fetch('title')
  end

  test 'end before start requires confirmation instead of overnight conversion' do
    response = ai_response('14時から13時まで会議を入れて')

    assert_equal 'rails-local-time-range-validation-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '終了時刻が開始時刻より前'
  end

  test 'weekday document creation is treated as focus work not stakeholder coordination' do
    response = ai_response('金曜に1時間、資料作成の時間を作って')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal 'rails-local-focus-work-v1', response.fetch(:provider)
    assert_equal Date.new(2026, 5, 15), start_at.to_date
    assert_equal '資料作成', recommendation.fetch('title')
    assert_equal 'focus_work', recommendation.fetch('payload').fetch('intent')
    assert_equal 60, ((end_at - start_at) / 60).round
    refute_includes recommendation.fetch('title'), '関係者調整'
  end

  test 'ambiguous break between unknown events asks for clarification' do
    response = ai_response('予定Aと予定Bの間に休憩を入れたい')

    assert_equal 'rails-local-between-events-clarification-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '予定を特定できません'
  end

  test 'afternoon meeting request starts in afternoon' do
    response = ai_response('参加者はあとで決める打ち合わせを明日午後に入れて')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))

    assert_equal Date.new(2026, 5, 11), start_at.to_date
    assert_operator start_at.hour, :>=, 13
    assert_operator start_at.hour, :<, 18
    assert_includes recommendation.fetch('title'), '打ち合わせ'
  end

  test 'ten minute morning request keeps ten minute duration' do
    response = ai_response('明日の朝イチで10分だけ確認したい')
    recommendation = first_recommendation(response)
    start_at = Time.iso8601(recommendation.fetch('start_at'))
    end_at = Time.iso8601(recommendation.fetch('end_at'))

    assert_equal Date.new(2026, 5, 11), start_at.to_date
    assert_equal 9, start_at.hour
    assert_equal 10, ((end_at - start_at) / 60).round
  end

  test 'past relative date is rejected instead of moved to future' do
    response = ai_response('昨日の15時に予定を入れて')

    assert_equal 'rails-local-past-date-validation-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '過去'
  end
end
