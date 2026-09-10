# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/scheduling/candidate_generator"

class SchedulingCandidateGeneratorTest < ActiveSupport::TestCase
  Context = Struct.new(:trusted_time_zone, :window_start_utc, :window_end_utc, :duration_minutes, :blocked_windows, :working_windows, :opening_hours_context, :boundary_intervals, :preference_context, keyword_init: true)

  test "generates quarter-hour grid exact boundaries and stable UTC deduplication" do
    exact = Time.utc(2026, 9, 10, 9, 7)
    context = build_context(boundary_intervals: { coverage: { exact_instants: [exact, exact] } }, preference_context: { explicit_exact_start: exact })
    candidates = Scheduling::CandidateGenerator.new.call(context: context)

    assert_includes candidates.map(&:start_at_utc), exact
    assert_equal candidates.map(&:start_at_utc).uniq, candidates.map(&:start_at_utc)
    assert_equal candidates.map(&:start_at_utc).sort, candidates.map(&:start_at_utc)
    assert_equal((0...candidates.length).to_a, candidates.map(&:stable_sequence))
    assert candidates.all? { |candidate| candidate.end_at_utc - candidate.start_at_utc == 1_800 }
    [0, 15, 30].each { |minute| assert_includes candidates.map(&:start_at_utc), Time.utc(2026, 9, 10, 9, minute), "AC-021 local quarter grid" }
    assert_includes candidates.map(&:start_at_utc), Time.utc(2026, 9, 10, 9, 45), "AC-021 local quarter grid"
    refute_includes candidates.map(&:start_at_utc), Time.utc(2026, 9, 10, 9, 1), "AC-021 off-grid omitted"
  end

  test "retains both fold instants and skips nonexistent local grid points" do
    fold = build_context(zone: "America/New_York", start_at: Time.utc(2026, 11, 1, 4, 45), end_at: Time.utc(2026, 11, 1, 7, 15))
    fold_starts = Scheduling::CandidateGenerator.new.call(context: fold).map(&:start_at_utc)
    assert_includes fold_starts, Time.utc(2026, 11, 1, 5, 0)
    assert_includes fold_starts, Time.utc(2026, 11, 1, 6, 0)

    gap = build_context(zone: "America/New_York", start_at: Time.utc(2026, 3, 8, 6, 45), end_at: Time.utc(2026, 3, 8, 8, 15))
    gap_starts = Scheduling::CandidateGenerator.new.call(context: gap).map(&:start_at_utc)
    assert_includes gap_starts, Time.utc(2026, 3, 8, 7, 15), "03:15 local remains a valid distinct grid point"
    assert_equal gap_starts.uniq, gap_starts
  end

  test "adds the two exact viable boundaries around a blocked interval" do
    blocked = [{ start_at_utc: Time.utc(2026, 9, 10, 9, 37), end_at_utc: Time.utc(2026, 9, 10, 10, 7) }]
    context = build_context(blocked_windows: blocked)
    starts = Scheduling::CandidateGenerator.new.call(context: context).map(&:start_at_utc)

    assert_includes starts, Time.utc(2026, 9, 10, 9, 7)
    assert_includes starts, Time.utc(2026, 9, 10, 10, 7)
  end


  test "OD-R1-M N retains exact external predecessor and successor boundaries" do
    exact = Time.utc(2026, 9, 7, 18, 15)
    context = build_context(
      start_at: Time.utc(2026, 9, 7, 18), end_at: Time.utc(2026, 9, 7, 19),
      boundary_intervals: { coverage: { exact_instants: [exact, exact] } }
    )
    starts = Scheduling::CandidateGenerator.new.call(context: context).map(&:start_at_utc)

    assert_includes starts, exact, "OD-R1-M earliest start 2026-09-07T18:15:00Z"
    assert_equal 1, starts.count(exact), "OD-R1-N latest end 18:45 minus duration gives the same deduplicated start"
  end


  test "AC-007 AC-009 generates only full-duration candidates inside exact bounds" do
    too_short = build_context(start_at: Time.utc(2026, 9, 10, 9), end_at: Time.utc(2026, 9, 10, 9, 29))
    assert_empty Scheduling::CandidateGenerator.new.call(context: too_short), "AC-007 full duration required"

    context = build_context(
      start_at: Time.utc(2026, 9, 10, 9, 7), end_at: Time.utc(2026, 9, 10, 9, 37),
      boundary_intervals: { coverage: { exact_instants: [Time.utc(2026, 9, 10, 9, 6), Time.utc(2026, 9, 10, 9, 7), Time.utc(2026, 9, 10, 9, 8)] } }
    )
    candidates = Scheduling::CandidateGenerator.new.call(context: context)
    assert_equal [Time.utc(2026, 9, 10, 9, 7)], candidates.map(&:start_at_utc), "AC-009 exact adjacency and fit"
    assert candidates.all? { |item| item.start_at_utc >= context.window_start_utc && item.end_at_utc <= context.window_end_utc }
  end


  test "AC-022 retains every literal exact allowed and forbidden boundary without rounding" do
    blocked = [{ start_at_utc: Time.utc(2026, 9, 10, 9, 37), end_at_utc: Time.utc(2026, 9, 10, 10, 7) }]
    working = [{ start_at_utc: Time.utc(2026, 9, 10, 9, 11), end_at_utc: Time.utc(2026, 9, 10, 11, 13) }]
    opening = [{ start_at_utc: Time.utc(2026, 9, 10, 9, 17), end_at_utc: Time.utc(2026, 9, 10, 11, 19) }]
    explicit = Time.utc(2026, 9, 10, 10, 3)
    context = build_context(
      end_at: Time.utc(2026, 9, 10, 12), blocked_windows: blocked, working_windows: working,
      opening_hours_context: { required: true, intervals: opening }, preference_context: { explicit_exact_start: explicit }
    )
    starts = Scheduling::CandidateGenerator.new.call(context: context).map(&:start_at_utc)
    expected = [
      Time.utc(2026, 9, 10, 9, 7), Time.utc(2026, 9, 10, 10, 7),
      Time.utc(2026, 9, 10, 9, 11), Time.utc(2026, 9, 10, 10, 43),
      Time.utc(2026, 9, 10, 9, 17), Time.utc(2026, 9, 10, 10, 49), explicit
    ]
    expected.each { |instant| assert_includes starts, instant, "AC-022 #{instant.iso8601}" }
  end

  private

  def build_context(zone: "UTC", start_at: Time.utc(2026, 9, 10, 9), end_at: Time.utc(2026, 9, 10, 11), blocked_windows: [], working_windows: [], opening_hours_context: { required: false, intervals: [] }, boundary_intervals: {}, preference_context: {})
    Context.new(trusted_time_zone: zone, window_start_utc: start_at, window_end_utc: end_at, duration_minutes: 30, blocked_windows: blocked_windows, working_windows: working_windows, opening_hours_context: opening_hours_context, boundary_intervals: boundary_intervals, preference_context: preference_context)
  end
end
