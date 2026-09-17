# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'time'

class AiClientSeptember17EvalRegressionTest < ActiveSupport::TestCase
  EVALUATION = JSON.parse(File.read(Rails.root.join('test/fixtures/ai_september17_eval.json'))).freeze
  CONTEXT = EVALUATION.fetch('context').deep_symbolize_keys.freeze
  INPUTS = EVALUATION.fetch('cases').freeze

  def response_for(case_id)
    response = nil
    remote_called = false
    client = Ai::Client.new(context: CONTEXT, user_message: INPUTS.fetch(case_id))
    client.define_singleton_method(:request_remote) do
      remote_called = true
      raise 'Unexpected remote request for a local schedule regression'
    end

    Time.use_zone('Asia/Tokyo') do
      travel_to(Time.zone.parse(CONTEXT.fetch(:now))) do
        assert_no_difference('Event.count', case_id) { response = client.call }
      end
    end

    refute remote_called, "#{case_id}: should be resolved locally"
    assert_empty response.fetch(:tool_invocations), "#{case_id}: candidate requests must not invoke actions"
    response
  end

  def assert_event(event, title: nil, start_at:, end_at:)
    assert_equal title, event.fetch('title') unless title.nil?
    assert_equal Time.iso8601(start_at), Time.iso8601(event.fetch('start_at'))
    assert_equal Time.iso8601(end_at), Time.iso8601(event.fetch('end_at'))
    assert_operator Time.iso8601(event.fetch('end_at')), :>, Time.iso8601(event.fetch('start_at'))
    assert_equal false, event.fetch('all_day')

    return unless event.key?('payload')

    assert_event(event.fetch('payload'), title: title, start_at: start_at, end_at: end_at)
  end

  def assert_past_notice(response)
    assert_match(/過去|すでに|既に/, response.fetch(:assistant_message))
    assert_match(/18(?::00|時)/, response.fetch(:assistant_message))
  end

  test 'evaluation fixture preserves all submitted originals and the full long input' do
    assert_equal 16, INPUTS.length
    assert_equal 1000, INPUTS.fetch('CF-07b').length
    assert_equal '2026-09-17T19:28:35+09:00', CONTEXT.fetch(:now)
    assert_equal 'Asia/Tokyo', CONTEXT.fetch(:timezone)
    assert INPUTS.fetch('CF-07b').start_with?('2026年9月20日の15:00から15:30まで、架空の「CF-07b テスト長文集中作業」')
    assert INPUTS.fetch('CF-07b').end_with?('候補だけを表示し、保存や通知はしないでください。')
  end

  test 'CF-01 keeps the explicit title and successful tomorrow time range' do
    response = response_for('CF-01')

    assert_equal 1, response.fetch(:recommendations).length
    assert_event(response.fetch(:recommendations).sole,
                 title: 'CF-01 テスト集中作業',
                 start_at: '2026-09-18T15:00:00+09:00', end_at: '2026-09-18T15:30:00+09:00')
  end

  test 'CF-02 separates two schedules and preserves the future schedule while identifying the past one' do
    response = response_for('CF-02')
    recommendations = response.fetch(:recommendations)

    assert_includes [1, 2], recommendations.length
    assert_past_notice(response)
    future = recommendations.select { |event| event.fetch('title') == 'CF-02 テスト集中作業' }
    assert_equal 1, future.length
    assert_event(future.sole, title: 'CF-02 テスト集中作業',
                 start_at: '2026-09-22T10:00:00+09:00', end_at: '2026-09-22T11:00:00+09:00')

    remaining = recommendations - future
    if remaining.any?
      assert_event(remaining.sole, title: 'CF-02 テスト休憩',
                   start_at: '2026-09-17T18:00:00+09:00', end_at: '2026-09-17T18:30:00+09:00')
    else
      assert_includes response.fetch(:assistant_message), 'CF-02 テスト休憩'
    end
  end

  test 'CF-03 original PASS criterion keeps candidate times and stated duration within next week' do
    response = response_for('CF-03')
    message = response.fetch(:assistant_message)
    recommendations = response.fetch(:recommendations)

    if recommendations.empty?
      assert_match(/来週|9[\/月]21/, message)
      assert_match(/何|教えて|指定|希望/, message)
    else
      # The original evaluation accepted a stated duration; explaining why 90
      # minutes was chosen was a P3 suggestion, not a new pass requirement.
      assert_match(/\d+(?:分|時間)/, message)
      recommendations.each do |event|
        starts = Time.iso8601(event.fetch('start_at'))
        ends = Time.iso8601(event.fetch('end_at'))
        assert_operator starts, :>=, Time.iso8601('2026-09-21T00:00:00+09:00')
        assert_operator ends, :<=, Time.iso8601('2026-09-28T00:00:00+09:00')
        assert_operator ends, :>, starts
      end
    end
  end

  test 'CF-04a continues to reject impossible dates without shifting the date' do
    response = response_for('CF-04a')

    assert_empty response.fetch(:recommendations)
    assert_match(/存在しない|無効|正しい日付/, response.fetch(:assistant_message))
    assert_includes response.fetch(:assistant_message), '11月31日'
  end

  test 'CF-04b original PASS criterion rejects invalid clocks without making candidates' do
    response = response_for('CF-04b')

    assert_empty response.fetch(:recommendations)
    assert_includes response.fetch(:assistant_message), '25:30'
    assert_match(/無効|正しい時刻/, response.fetch(:assistant_message))
  end

  test 'CF-04c continues to reject a reversed same day time range' do
    response = response_for('CF-04c')

    assert_empty response.fetch(:recommendations)
    assert_match(/終了時刻が開始時刻より前|終了.*開始.*早/, response.fetch(:assistant_message))
  end

  %w[CF-05 CF-05R].each do |case_id|
    test "#{case_id} interprets mixed language timing and supplementary candidate instructions" do
      response = response_for(case_id)

      assert_equal 1, response.fetch(:recommendations).length
      assert_event(response.fetch(:recommendations).sole, title: "#{case_id} テスト休憩",
                   start_at: '2026-09-18T14:00:00+09:00', end_at: '2026-09-18T14:20:00+09:00')
      assert_match(/候補|休憩|提案/, response.fetch(:assistant_message))
      refute_match(/リマインダーを設定する予定を特定できません|時間が不足/, response.fetch(:assistant_message))
    end
  end

  test 'CF-06 preserves the weekly title and shows the range of all sixteen occurrences' do
    response = response_for('CF-06')
    recommendations = response.fetch(:recommendations)

    assert_equal 1, recommendations.length
    recommendation = recommendations.sole
    payload = recommendation.fetch('payload')
    events = payload.fetch('events')
    assert_equal 'weekly', payload.fetch('recurrence_kind')
    assert_equal 16, events.length
    assert_match(/\ACF-06 テストストレッチ(?:[（(]毎週[）)])?\z/, recommendation.fetch('title'))
    expected_dates = 8.times.flat_map do |week|
      [Date.new(2026, 9, 22) + week * 7, Date.new(2026, 9, 24) + week * 7]
    end.sort.map(&:iso8601)

    assert_equal expected_dates, payload.fetch('target_dates')
    assert_equal expected_dates, events.map { |event| Time.iso8601(event.fetch('start_at')).to_date.iso8601 }
    events.zip(expected_dates).each do |event, date|
      assert_event(event, title: 'CF-06 テストストレッチ',
                   start_at: "#{date}T07:00:00+09:00", end_at: "#{date}T07:10:00+09:00")
    end

    message = response.fetch(:assistant_message)
    assert_includes message, '16'
    assert_match(/火曜/, message)
    assert_match(/木曜/, message)
    assert_match(/9[\/月]22|2026-09-22/, message)
    assert_match(/11[\/月]12|2026-11-12/, message)
    refute_match(/保存や通知はしない|候補を提案してください/, recommendation.fetch('title'))
  end

  test 'CF-07b keeps the explicit title and successful time range in the full thousand character input' do
    response = response_for('CF-07b')

    assert_equal 1, response.fetch(:recommendations).length
    assert_event(response.fetch(:recommendations).sole, title: 'CF-07b テスト長文集中作業',
                 start_at: '2026-09-20T15:00:00+09:00', end_at: '2026-09-20T15:30:00+09:00')
  end

  test 'CF-08 keeps the original successful count and time range at the service boundary' do
    response = response_for('CF-08')

    assert_equal 1, response.fetch(:recommendations).length
    # Loading indicators and Enter suppression are covered by UI tests; this
    # service check does not claim to reproduce the browser interaction.
    assert_event(response.fetch(:recommendations).sole,
                 start_at: '2026-09-21T16:00:00+09:00', end_at: '2026-09-21T16:30:00+09:00')
  end

  test 'CF-09 explains unsupported operations without asking for an execution target' do
    response = response_for('CF-09')

    assert_empty response.fetch(:recommendations)
    assert_match(/対応|サポート|でき|可能/, response.fetch(:assistant_message))
    refute_match(/リマインダーを設定する予定を特定できません|予定名または日時を指定/, response.fetch(:assistant_message))
    refute_match(/通知しました|保存しました|実行しました/, response.fetch(:assistant_message))
  end

  %w[CF-02a CF-02c].each do |case_id|
    test "#{case_id} handles an explicit past time without turning supplementary copy into a schedule" do
      response = response_for(case_id)
      recommendations = response.fetch(:recommendations)

      assert_past_notice(response)
      assert_operator recommendations.length, :<=, 1
      refute_match(/候補の表示だけを希望しますの時間が不足/, response.fetch(:assistant_message))
      if recommendations.any?
        title = case_id == 'CF-02a' ? 'CF-02a テスト休憩' : 'CF-02c テスト集中作業'
        assert_event(recommendations.sole, title: title,
                     start_at: '2026-09-17T18:00:00+09:00', end_at: '2026-09-17T18:30:00+09:00')
      end
    end
  end

  {
    'CF-02b' => '2026-09-22',
    'CF-02d' => '2026-09-25'
  }.each do |case_id, date|
    test "#{case_id} original PASS criterion resolves next weekday in the next calendar week" do
      response = response_for(case_id)

      assert_equal 1, response.fetch(:recommendations).length
      assert_event(response.fetch(:recommendations).sole,
                   start_at: "#{date}T10:00:00+09:00", end_at: "#{date}T11:00:00+09:00")
    end
  end

  # These checks extend the explicit-name regression from CF-01 and CF-07b.
  # Their baseline failures must not turn the original four PASS results into
  # additional browser-evaluation failures.
  %w[CF-03 CF-08 CF-02b CF-02d].each do |case_id|
    test "#{case_id} additional title check preserves the explicit name beyond its original PASS criterion" do
      response = response_for(case_id)
      recommendations = response.fetch(:recommendations)

      if case_id == 'CF-03' && recommendations.empty?
        assert_match(/何|教えて|指定|希望/, response.fetch(:assistant_message))
      else
        assert_not_empty recommendations
        recommendations.each do |event|
          assert_equal "#{case_id} テスト集中作業", event.fetch('title')
          assert_equal "#{case_id} テスト集中作業", event.fetch('payload').fetch('title')
        end
      end
    end
  end
end
