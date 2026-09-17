# frozen_string_literal: true

require 'test_helper'
require 'time'

class AiClientSeptemberTemporalTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-09-14T21:57:59+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  def ai_response(message, context: {})
    client = Ai::Client.new(context: BASE_CONTEXT.merge(context), user_message: message)
    remote_called = false
    client.define_singleton_method(:request_remote) do
      remote_called = true
      raise 'unexpected remote access'
    end
    response = client.call
    refute remote_called, message
    response
  end

  def recommendation_start(recommendation)
    Time.iso8601(recommendation.fetch('start_at'))
  end

  test 'CF-02b next Tuesday means September 22 from Monday evening' do
    response = ai_response('来週火曜の10時から1時間の「CF-02b テスト集中作業」の候補をください。')
    recommendation = response.fetch(:recommendations).sole

    assert_equal '2026-09-22T10:00:00+09:00', recommendation.fetch('start_at')
    assert_equal '2026-09-22T11:00:00+09:00', recommendation.fetch('end_at')
  end

  test 'next week and following week agree throughout the reference week' do
    (14..20).each do |day|
      { '来週' => 22, '翌週' => 22, '再来週' => 29 }.each do |relative_week, expected_day|
        input = "#{relative_week}火曜の10時から1時間の集中作業の候補をください。"
        response = ai_response(input, context: { now: "2026-09-#{day}T21:57:59+09:00" })
        actual_date = recommendation_start(response.fetch(:recommendations).sole).to_date

        assert_equal Date.new(2026, 9, expected_day), actual_date, "#{day}: #{input}"
      end
    end
  end

  test 'CF-02c past explicit focus time requests a future date without candidates' do
    response = ai_response('今日の18時から30分の「CF-02c テスト集中作業」の候補をください。')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '過去'
    assert_includes response.fetch(:assistant_message), '9/14 18:00'
  end

  test 'CF-03 vague next week focus candidates stay in next week and explain defaults' do
    response = ai_response('来週どこかで、架空の「CF-03 テスト集中作業」の時間を作りたいです。候補だけを表示し、保存や通知はしないでください。')

    refute_empty response.fetch(:recommendations)
    response.fetch(:recommendations).each do |recommendation|
      start_at = recommendation_start(recommendation)
      assert_includes Date.new(2026, 9, 21)..Date.new(2026, 9, 27), start_at.to_date
      assert_operator start_at, :>, Time.iso8601(BASE_CONTEXT.fetch(:now))
    end
    assert_match(/未指定|指定がない|仮定/, response.fetch(:assistant_message))
    assert_includes response.fetch(:assistant_message), '90分'
    assert_includes response.fetch(:assistant_message), '9:00'
    assert_includes response.fetch(:assistant_message), '18:00'
  end

  test 'implicit focus windows omit times that already started today' do
    response = ai_response('今日の午後に30分の集中作業の候補をください。', context: { now: '2026-09-14T14:20:00+09:00' })

    refute_empty response.fetch(:recommendations)
    response.fetch(:recommendations).each do |recommendation|
      assert_operator recommendation_start(recommendation), :>=, Time.iso8601('2026-09-14T14:20:00+09:00')
    end
  end

  test 'a finished focus window does not silently move an explicit day' do
    response = ai_response('今日の午後に30分の集中作業の候補をください。')

    assert_empty response.fetch(:recommendations)
    assert_match(/空き枠|過去/, response.fetch(:assistant_message))
  end

  test 'CF-04b invalid 25:30 stays rejected and preserves minutes in its correction example' do
    response = ai_response('2026年9月16日の25:30から30分、架空の「CF-04b テスト時刻確認」の候補をください。候補だけを表示し、保存や通知はしないでください。')

    assert_equal 'rails-local-time-validation-v1', response.fetch(:provider)
    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '25:30'
    assert_includes response.fetch(:assistant_message), '翌日1時30分'
  end

  test 'CF-04a invalid date and CF-04c reversed range remain rejected' do
    {
      '2026年11月31日の10:00から11:00まで、架空の「CF-04a テスト日付確認」の候補をください。候補だけを表示し、保存や通知はしないでください。' => 'rails-local-date-validation-v1',
      '2026年9月16日の11:00から10:00まで、架空の「CF-04c テスト時間範囲確認」の候補をください。同じ日の開始と終了です。候補だけを表示し、保存や通知はしないでください。' => 'rails-local-time-range-validation-v1'
    }.each do |message, provider|
      response = ai_response(message)
      assert_equal provider, response.fetch(:provider)
      assert_empty response.fetch(:recommendations)
    end
  end
end
