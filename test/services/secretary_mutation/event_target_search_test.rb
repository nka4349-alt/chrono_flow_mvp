# frozen_string_literal: true

require 'test_helper'

class SecretaryMutationEventTargetSearchTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(name: 'Search owner', email: "search-#{SecureRandom.hex(5)}@example.test",
      password: 'Password-123!', identity_issuer: 'https://identity.example.test/',
      identity_subject: "search|#{SecureRandom.uuid}")
    @now = Time.iso8601('2026-09-21T12:00:00Z')
  end

  test 'closed date window uses half-open interval overlap at both boundaries' do
    zone = ActiveSupport::TimeZone['Asia/Tokyo']
    local_date = @now.in_time_zone(zone).to_date
    first_date = local_date - 366
    last_date = local_date + 731
    start_boundary = zone.local(first_date.year, first_date.month, first_date.day)
    end_date = local_date + 732
    end_boundary = zone.local(end_date.year, end_date.month, end_date.day)

    spanning_start = event_at('開始境界を跨ぐ予定', start_boundary - 1.hour, start_boundary + 1.hour)
    at_start = event_at('開始境界予定', start_boundary, start_boundary + 1.hour)
    ending_at_start = event_at('範囲外終了予定', start_boundary - 1.hour, start_boundary)
    last_included = event_at('最終日予定', zone.local(last_date.year, last_date.month, last_date.day),
      zone.local(last_date.year, last_date.month, last_date.day) + 1.hour)
    starts_at_end = event_at('終了境界外予定', end_boundary, end_boundary + 1.hour)

    rows = search('予定').events
    assert_includes rows, spanning_start
    assert_includes rows, at_start
    assert_includes rows, last_included
    refute_includes rows, ending_at_start
    refute_includes rows, starts_at_end
  end

  test 'IANA zone preserves 23-hour and 25-hour local days and all-day candidate dates' do
    zone = ActiveSupport::TimeZone['America/New_York']
    spring_start = zone.local(2026, 3, 8)
    spring_end = zone.local(2026, 3, 9)
    fall_start = zone.local(2026, 11, 1)
    fall_end = zone.local(2026, 11, 2)
    assert_equal 23.hours, spring_end - spring_start
    assert_equal 25.hours, fall_end - fall_start

    spring = event_at('DST春予定', spring_start, spring_end, all_day: true)
    fall = event_at('DST秋予定', fall_start, fall_end, all_day: true)
    result = SecretaryMutation::EventTargetSearch.new(user: @user, message: 'DST',
      time_zone: 'America/New_York', now: @now).call
    assert_equal [spring.id, fall.id], result.events.map(&:id).sort
    assert_equal({ 'title' => 'DST春予定', 'start_on' => '2026-03-08',
      'end_on' => '2026-03-09', 'all_day' => true },
      SecretaryMutation::EventProjection.display(spring, time_zone: 'America/New_York'))
  end

  test 'all-day search uses stored calendar dates at exact cross-zone boundaries' do
    request_zone = ActiveSupport::TimeZone['America/New_York']
    local_date = @now.in_time_zone(request_zone).to_date
    start_date = local_date - 366
    end_date = local_date + 732
    application_zone = Time.zone
    ending_at_start = event_at('終日境界 start outside',
      application_zone.local((start_date - 1.day).year, (start_date - 1.day).month, (start_date - 1.day).day),
      application_zone.local(start_date.year, start_date.month, start_date.day), all_day: true)
    at_start = event_at('終日境界 start included',
      application_zone.local(start_date.year, start_date.month, start_date.day),
      application_zone.local((start_date + 1.day).year, (start_date + 1.day).month, (start_date + 1.day).day),
      all_day: true)
    last_included = event_at('終日境界 last included',
      application_zone.local((end_date - 1.day).year, (end_date - 1.day).month, (end_date - 1.day).day),
      application_zone.local(end_date.year, end_date.month, end_date.day), all_day: true)
    at_exclusive_end = event_at('終日境界 end outside',
      application_zone.local(end_date.year, end_date.month, end_date.day),
      application_zone.local((end_date + 1.day).year, (end_date + 1.day).month, (end_date + 1.day).day),
      all_day: true)

    result = SecretaryMutation::EventTargetSearch.new(user: @user, message: '終日境界',
      time_zone: 'America/New_York', now: @now).call
    assert_includes result.events, at_start
    assert_includes result.events, last_included
    refute_includes result.events, ending_at_start
    refute_includes result.events, at_exclusive_end
    display = SecretaryMutation::EventProjection.display(at_exclusive_end,
      time_zone: 'America/New_York')
    assert_equal end_date.iso8601, display.fetch('start_on')
    assert_equal (end_date + 1.day).iso8601, display.fetch('end_on')
    assert_equal false, result.truncated
  end

  test 'timed and all-day candidate union stays bounded to six rows for five plus truncation' do
    application_zone = Time.zone
    7.times do |index|
      if index.even?
        date = @now.in_time_zone(application_zone).to_date + index.days
        event_at("混合候補 #{index}", application_zone.local(date.year, date.month, date.day),
          application_zone.local((date + 1.day).year, (date + 1.day).month, (date + 1.day).day), all_day: true)
      else
        event_at("混合候補 #{index}", @now + index.hours, @now + index.hours + 30.minutes)
      end
    end

    result = search('混合候補')
    assert_equal 5, result.events.length
    assert result.truncated
  end

  test 'query applies owner personal relationship predicates before six-row truncation' do
    overlong_title = event_at('候補 overlong title', @now - 4.hours, @now - 3.hours)
    overlong_title.update_column(:title, '長' * 201)
    overlong_description = event_at('候補 overlong description', @now - 3.hours, @now - 2.hours)
    overlong_description.update_column(:description, '説' * 4_001)
    overlong_location = event_at('候補 overlong location', @now - 2.hours, @now - 1.hour)
    overlong_location.update_column(:location, '場' * 201)
    empty_interval = event_at('候補 empty interval', @now - 1.hour, @now)
    empty_interval.update_column(:end_at, empty_interval.start_at)
    eligible = 6.times.map { |index| event_at("候補 #{index}", @now + index.hours, @now + index.hours + 30.minutes) }
    other = User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.test",
      password: 'Password-123!')
    ineligible = event_at('候補 shared', @now + 8.hours, @now + 9.hours)
    EventParticipant.create!(event: ineligible, user: other)
    result = search('候補')
    assert_equal eligible.first(5).map(&:id), result.events.map(&:id)
    assert result.truncated
    refute_includes result.events, ineligible
    refute_includes result.events, overlong_title
    refute_includes result.events, overlong_description
    refute_includes result.events, overlong_location
    refute_includes result.events, empty_interval
  end

  test 'query excludes control-bearing legacy display fields while preserving multiline descriptions' do
    malformed_title = event_at('不正タイトル', @now + 1.hour, @now + 2.hours)
    malformed_title.update_column(:title, "不正\tタイトル")
    malformed_location = event_at('不正場所', @now + 2.hours, @now + 3.hours)
    malformed_location.update_column(:location, "不正\n場所")
    malformed_description = event_at('不正説明', @now + 3.hours, @now + 4.hours)
    malformed_description.update_column(:description, "不正\t説明")
    multiline_description = event_at('正常複数行', @now + 4.hours, @now + 5.hours)
    multiline_description.update_column(:description, "一行目\n二行目")

    result = search('予定')
    refute_includes result.events, malformed_title
    refute_includes result.events, malformed_location
    refute_includes result.events, malformed_description
    assert_includes result.events, multiline_description
    assert_equal false, result.truncated
  end

  test 'C1 legacy titles are excluded before the six-row search limit' do
    6.times do |index|
      malformed = event_at("C1候補 #{index}", @now + index.minutes, @now + index.minutes + 30.minutes)
      malformed.update_column(:title, "C1\u0085候補 #{index}")
    end
    eligible = 6.times.map do |index|
      event_at("正常候補 #{index}", @now + 1.day + index.hours, @now + 1.day + index.hours + 30.minutes)
    end

    result = search('候補')

    assert_equal eligible.first(5).map(&:id), result.events.map(&:id)
    assert_equal true, result.truncated
  end

  test 'disallowed description controls are excluded before limit while LF remains eligible' do
    controls = ["\t", "\r", "\u0085"]
    6.times do |index|
      malformed = event_at("説明制御候補 #{index}", @now + index.minutes,
        @now + index.minutes + 30.minutes)
      malformed.update_column(:description, "不正#{controls.fetch(index % controls.length)}説明")
    end
    eligible = 6.times.map do |index|
      event = event_at("説明正常候補 #{index}", @now + 1.day + index.hours,
        @now + 1.day + index.hours + 30.minutes)
      event.update_column(:description, "一行目\n二行目")
      event
    end

    result = search('候補')

    assert_equal eligible.first(5).map(&:id), result.events.map(&:id)
    assert_equal true, result.truncated
  end

  private

  def search(message)
    SecretaryMutation::EventTargetSearch.new(user: @user, message: message,
      time_zone: 'Asia/Tokyo', now: @now).call
  end

  def event_at(title, start_at, end_at, all_day: false)
    event = Event.create!(created_by: @user, title: title, start_at: start_at,
      end_at: end_at, all_day: all_day, color: '#3b82f6')
    event.update_column(:all_day, true) if all_day && !event.all_day?
    event.reload
  end
end
