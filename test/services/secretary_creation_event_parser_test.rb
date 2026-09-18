# frozen_string_literal: true

require 'test_helper'

class SecretaryCreationEventParserTest < ActiveSupport::TestCase
  setup do
    @user = User.new(id: 1, name: 'Test')
    @now = Time.zone.parse('2026-09-20 09:00:00')
  end

  test 'explicit timing is preserved and no default duration or date is guessed' do
    assert_equal 'needs_clarification', parse('今日18時に来客を入れて')[:status]
    assert_equal 'needs_clarification', parse('18時から19時まで来客を入れて')[:status]
    assert_equal 'needs_clarification', parse('明日来客を入れて')[:status]
    result = parse('今日18時に来客を入れて', '1時間')
    assert_equal 'ready', result[:status], result.inspect
    assert_equal '2026-09-20T19:00:00+09:00', result.dig(:details, 'end_at')
  end

  test 'single all day preserves midnight and exclusive next day end' do
    result = parse('明日は終日休暇を予定に入れて')
    assert_equal 'ready', result[:status], result.inspect
    assert_equal true, result.dig(:details, 'all_day')
    assert_equal '休暇', result.dig(:details, 'title')
    assert_equal '2026-09-21T00:00:00+09:00', result.dig(:details, 'start_at')
    assert_equal '2026-09-22T00:00:00+09:00', result.dig(:details, 'end_at')
    SecretaryCreation::Contract.validate_details!(result[:details], provider: 'chrono_flow')
  end

  test 'invalid dates and unsupported multi or recurring requests never become executable' do
    [
      '2月30日18時から19時まで来客を追加', '明日25時から26時まで会議を追加',
      '毎週火曜18時から19時まで会議を追加', '明日18時から19時まで会議をグループに共有して',
      '明日18時から19時まで来客、20時から21時まで夕食を追加',
      '明日18時から19時まで会議を追加して15分前に通知して'
    ].each do |message|
      result = parse(message)
      refute_equal 'ready', result[:status], "#{message}: #{result.inspect}"
      assert_nil result[:details]
    end
  end

  test 'alternative dates or clock times and date ranges require clarification' do
    [
      '明日か明後日18時から19時まで来客を予定に追加',
      '明日18時か19時から1時間会議を追加',
      '明日18時から19時か20時まで会議を追加',
      '月曜または火曜18時から19時まで会議を追加',
      '明日から明後日まで終日休暇を予定に追加'
    ].each do |message|
      result = parse(message)
      assert_equal 'needs_clarification', result[:status], "#{message}: #{result.inspect}"
      assert_nil result[:details]
    end
  end

  private

  def parse(*messages)
    SecretaryCreation::EventParser.call(user: @user, messages: messages, now: @now)
  end
end
