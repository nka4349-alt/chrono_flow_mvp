# frozen_string_literal: true

require "test_helper"
require_relative "test_support"

class ChronoFlowSpecialistScheduleReaderTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  setup do
    @user = create_user("reader")
    @other = create_user("other")
    @reader = ChronoFlowSpecialist::ScheduleReader.new(
      fact_id: ChronoFlowSpecialist::FactId.new(
        secret: "test-fact-id-secret-which-is-at-least-thirty-two-bytes"
      )
    )
  end

  test "returns only personal owner and participant events and excludes every grouped event" do
    owned = create_event(
      title: "Owned",
      owner: @user,
      start_at: Time.zone.parse("2026-08-31 09:00"),
      end_at: Time.zone.parse("2026-08-31 10:00"),
      location: "Room A"
    )
    participated = create_event(
      title: "Participated",
      owner: @other,
      start_at: Time.zone.parse("2026-08-31 11:00"),
      end_at: Time.zone.parse("2026-08-31 12:00")
    )
    EventParticipant.create!(event: participated, user: @user)

    grouped = create_event(
      title: "Grouped",
      owner: @user,
      start_at: Time.zone.parse("2026-08-31 13:00"),
      end_at: Time.zone.parse("2026-08-31 14:00")
    )
    group = Group.create!(name: "Private group", owner_id: @user.id)
    EventGroup.create!(event: grouped, group: group)

    create_event(
      title: "Unrelated",
      owner: @other,
      start_at: Time.zone.parse("2026-08-31 15:00"),
      end_at: Time.zone.parse("2026-08-31 16:00")
    )

    facts = read_schedule

    assert_equal %w[Owned Participated], facts.map { |fact| fact.dig("fields", "title") }
    assert_equal [owned.id, participated.id].length, facts.length
    facts.each do |fact|
      assert_equal %w[fact_type fields id source_updated_at], fact.keys.sort
      assert_equal "schedule_event", fact.fetch("fact_type")
      assert_equal %w[all_day end_at location start_at title], fact.fetch("fields").keys.sort
      assert_match(/\Acf_[A-Za-z0-9_-]+\z/, fact.fetch("id"))
      assert_match(/(?:Z|[+-]\d{2}:\d{2})\z/, fact.fetch("source_updated_at"))
    end
    refute_includes facts.map { |fact| fact.fetch("id") }, owned.id.to_s
  end

  test "caps output at 24 and uses opaque id as the stable final ordering key" do
    25.times do |index|
      create_event(
        title: "Tie #{index}",
        owner: @user,
        start_at: Time.zone.parse("2026-09-01 09:00"),
        end_at: Time.zone.parse("2026-09-01 10:00")
      )
    end

    facts = read_schedule
    ids = facts.map { |fact| fact.fetch("id") }

    assert_equal 24, facts.length
    assert_equal ids.sort, ids
    assert_equal ids.uniq, ids
  end

  test "serializes all day dates in application Time.zone without request-zone conversion" do
    Time.use_zone("Asia/Tokyo") do
      create_event(
        title: "All day",
        owner: @user,
        start_at: Time.zone.local(2026, 9, 1),
        end_at: Time.zone.local(2026, 9, 2),
        all_day: true
      )

      facts = read_schedule(time_zone: "America/New_York")
      fields = facts.fetch(0).fetch("fields")

      assert_equal true, fields.fetch("all_day")
      assert_equal "2026-09-01", fields.fetch("start_at")
      assert_equal "2026-09-02", fields.fetch("end_at")
    end
  end

  test "uses an exact 14-calendar-day half-open window and overlap semantics" do
    create_event(
      title: "Ends at start",
      owner: @user,
      start_at: Time.zone.parse("2026-08-29 23:00"),
      end_at: Time.zone.parse("2026-08-30 00:00")
    )
    create_event(
      title: "Straddles start",
      owner: @user,
      start_at: Time.zone.parse("2026-08-29 23:30"),
      end_at: Time.zone.parse("2026-08-30 00:30")
    )
    create_event(
      title: "Starts at start",
      owner: @user,
      start_at: Time.zone.parse("2026-08-30 00:00"),
      end_at: Time.zone.parse("2026-08-30 01:00")
    )
    create_event(
      title: "Straddles end",
      owner: @user,
      start_at: Time.zone.parse("2026-09-12 23:30"),
      end_at: Time.zone.parse("2026-09-13 00:30")
    )
    create_event(
      title: "Starts at end",
      owner: @user,
      start_at: Time.zone.parse("2026-09-13 00:00"),
      end_at: Time.zone.parse("2026-09-13 01:00")
    )

    titles = read_schedule.map { |fact| fact.dig("fields", "title") }

    assert_equal ["Straddles start", "Starts at start", "Straddles end"], titles
  end

  test "serializes requested-zone numeric offsets correctly across DST" do
    requested_zone = Time.find_zone!("America/New_York")
    create_event(
      title: "Before DST transition",
      owner: @user,
      start_at: requested_zone.local(2026, 10, 31, 9),
      end_at: requested_zone.local(2026, 10, 31, 10)
    )
    create_event(
      title: "After DST transition",
      owner: @user,
      start_at: requested_zone.local(2026, 11, 2, 9),
      end_at: requested_zone.local(2026, 11, 2, 10)
    )

    now = Time.zone.parse("2026-10-31 12:00")
    facts = read_schedule(time_zone: "America/New_York", now: now)
    starts = facts.to_h { |fact| [fact.dig("fields", "title"), fact.dig("fields", "start_at")] }

    assert_equal "2026-10-31T09:00:00-04:00", starts.fetch("Before DST transition")
    assert_equal "2026-11-02T09:00:00-05:00", starts.fetch("After DST transition")
  end

  private

  def read_schedule(time_zone: "Asia/Tokyo", now: test_now)
    @reader.call(
      user: @user,
      request: request_payload(time_zone: time_zone),
      now: now
    )
  end

  def create_user(label)
    suffix = SecureRandom.hex(8)
    User.create!(
      email: "#{label}-#{suffix}@example.test",
      name: label,
      password: "password123",
      status: "active",
      identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "provider|#{label}-#{suffix}"
    )
  end

  def create_event(title:, owner:, start_at:, end_at:, all_day: false, location: nil)
    Event.create!(
      title: title,
      created_by: owner,
      start_at: start_at,
      end_at: end_at,
      all_day: all_day,
      location: location,
      color: "#3b82f6"
    )
  end
end
