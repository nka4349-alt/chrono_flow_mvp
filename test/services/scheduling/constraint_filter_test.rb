# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/scheduling/candidate"
require_relative "../../../app/services/scheduling/constraint_filter"

class SchedulingConstraintFilterTest < ActiveSupport::TestCase
  Context = Struct.new(:trusted_time_zone, :window_start_utc, :window_end_utc, :duration_minutes, :busy_intervals, :blocked_windows, :working_windows, :lunch_policy, :opening_hours_context, :boundary_intervals, :travel_context, :preference_context, keyword_init: true)

  test "uses half-open busy blocked working lunch and opening constraints" do
    candidate = candidate_at(10, 0)
    context = context_for(busy_intervals: [{ start_at_utc: utc_time(9, 30), end_at_utc: utc_time(10, 0) }])
    assert_equal [candidate.start_at_utc], filter(context, candidate).feasible_candidates.map(&:start_at_utc)

    blocked = context_for(blocked_windows: [{ start_at_utc: utc_time(10, 15), end_at_utc: utc_time(11) }])
    assert_empty filter(blocked, candidate).feasible_candidates
    protected_lunch = context_for(lunch_policy: { protect: true, interval: { start_at_utc: utc_time(10, 29), end_at_utc: utc_time(11) } })
    assert_equal 1, filter(protected_lunch, candidate).bounded_rejection_counts[:lunch]
  end

  test "HC-013 distinguishes unset working hours from an explicitly empty allowed set" do
    candidate = candidate_at(10, 0)
    assert_equal 1, filter(context_for(working_windows: nil), candidate).feasible_candidates.length
    result = filter(context_for(working_windows: []), candidate)
    assert_empty result.feasible_candidates
    assert_equal 1, result.bounded_rejection_counts[:working]
  end

  test "evaluates all tied directional routes and max travel plus each leg buffer" do
    candidate = candidate_at(10, 0)
    predecessors = [event(1, 9, 50), event(2, 9, 50)]
    travel = travel_context(
      bindings: { 1 => fixed("A"), 2 => fixed("B") },
      routes: [route("A", "TASK", 12, 20), route("B", "TASK", 25, 0)]
    )
    context = context_for(boundary_intervals: { predecessors: predecessors, successors: [], candidate_events: [] }, travel_context: travel)
    result = filter(context, candidate)

    assert_empty result.feasible_candidates
    assert_nil result.terminal_failure

    safe_candidate = candidate_at(10, 22)
    safe = filter(context, safe_candidate).feasible_candidates.first
    assert_equal 25, safe.ranking_features[:total_travel_minutes]
    assert_equal %i[daily_load fragmentation profile_preference request_preference route_efficiency route_efficiency_enabled route_efficiency_known total_travel_minutes], safe.ranking_features.keys.sort
  end

  test "distinguishes proved same-place zero from unknown and never reuses reverse route" do
    candidate = candidate_at(10, 0)
    previous = event(1, 10, 0)
    same = context_for(boundary_intervals: { predecessors: [previous], successors: [], candidate_events: [] }, travel_context: travel_context(bindings: { 1 => fixed("TASK") }, routes: []))
    assert_equal [candidate.start_at_utc], filter(same, candidate).feasible_candidates.map(&:start_at_utc)

    reverse_only = context_for(boundary_intervals: { predecessors: [previous], successors: [], candidate_events: [] }, travel_context: travel_context(bindings: { 1 => fixed("A") }, routes: [route("TASK", "A", 5, 0)]))
    result = filter(reverse_only, candidate)
    assert_empty result.feasible_candidates
    assert_equal :travel_time_unavailable, result.terminal_failure
  end

  test "distinguishes unresolved subject location from a missing directional route" do
    candidate = candidate_at(10, 0)
    previous = event(1, 10, 0)
    unresolved = { resolution: "unresolved", place_ref: nil }
    location_context = context_for(
      boundary_intervals: { predecessors: [previous], successors: [], candidate_events: [] },
      travel_context: travel_context(bindings: { 1 => unresolved }, routes: [])
    )
    route_context = context_for(
      boundary_intervals: { predecessors: [previous], successors: [], candidate_events: [] },
      travel_context: travel_context(bindings: { 1 => fixed("A") }, routes: [])
    )

    assert_equal :location_required, filter(location_context, candidate).terminal_failure
    assert_equal :travel_time_unavailable, filter(route_context, candidate).terminal_failure
  end


  test "mixed tied location and route unknown uses deterministic precedence in both directions and orders" do
    candidate = candidate_at(10, 0)
    unresolved = { resolution: "unresolved", place_ref: nil }
    bindings = { 1 => unresolved, 2 => fixed("B") }
    travel = travel_context(bindings: bindings, routes: [])
    predecessor_ties = [
      { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9) },
      { event_id: 2, start_at_utc: utc_time(8, 30), end_at_utc: utc_time(9) }
    ]
    successor_ties = [
      { event_id: 1, start_at_utc: utc_time(11), end_at_utc: utc_time(12) },
      { event_id: 2, start_at_utc: utc_time(11), end_at_utc: utc_time(12, 30) }
    ]

    { predecessors: predecessor_ties, successors: successor_ties }.each do |direction, ties|
      [ties, ties.reverse].each do |ordered|
        boundaries = { predecessors: [], successors: [], candidate_events: [] }.merge(direction => ordered)
        result = filter(context_for(boundary_intervals: boundaries, travel_context: travel), candidate)
        assert_equal :location_required, result.terminal_failure, "#{direction} mixed tie precedence"
      end
    end
  end

  test "known-infeasible tied leg takes precedence over unresolved legs in both directions and orders" do
    candidate = candidate_at(10, 0)
    unresolved = { resolution: "unresolved", place_ref: nil }
    predecessor_ties = [
      { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9, 50) },
      { event_id: 2, start_at_utc: utc_time(8, 30), end_at_utc: utc_time(9, 50) }
    ]
    successor_ties = [
      { event_id: 1, start_at_utc: utc_time(10, 40), end_at_utc: utc_time(12) },
      { event_id: 2, start_at_utc: utc_time(10, 40), end_at_utc: utc_time(12, 30) }
    ]

    { predecessors: predecessor_ties, successors: successor_ties }.each do |direction, ties|
      known_route = direction == :predecessors ? route("A", "TASK", 25, 0) : route("TASK", "A", 25, 0)
      [fixed("B"), unresolved].each do |unknown_binding|
        travel = travel_context(bindings: { 1 => fixed("A"), 2 => unknown_binding }, routes: [known_route])
        [ties, ties.reverse].each do |ordered|
          boundaries = { predecessors: [], successors: [], candidate_events: [] }.merge(direction => ordered)
          result = filter(context_for(boundary_intervals: boundaries, travel_context: travel), candidate)
          assert_empty result.feasible_candidates
          assert_nil result.terminal_failure, "#{direction} known-infeasible tie is not an unresolved survivor"
          assert_equal 1, result.bounded_rejection_counts[:travel]
        end
      end
    end
  end

  test "fails closed when zero via travel lacks all-same-place proof" do
    candidate = candidate_at(10, 0)
    previous = { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9) }
    following = { event_id: 2, start_at_utc: utc_time(11), end_at_utc: utc_time(12) }
    travel = travel_context(
      bindings: { 1 => fixed("A"), 2 => fixed("B") },
      routes: [route("A", "TASK", 0, 0), route("TASK", "B", 0, 0), route("A", "B", 0, 0)]
    )
    preference = context_for.preference_context.merge(return_route_preference: true)
    context = context_for(
      boundary_intervals: { predecessors: [previous], successors: [following], candidate_events: [] },
      travel_context: travel,
      preference_context: preference
    )

    assert_raises(Scheduling::ConstraintFilter::IncompleteRankingContext) { filter(context, candidate) }
  end

  test "proves an equal-place direct baseline without a self-route entry" do
    candidate = candidate_at(10, 0)
    previous = { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9) }
    following = { event_id: 2, start_at_utc: utc_time(11), end_at_utc: utc_time(12) }
    travel = travel_context(
      bindings: { 1 => fixed("A"), 2 => fixed("A") },
      routes: [route("A", "TASK", 10, 0), route("TASK", "A", 10, 0)]
    )
    preference = context_for.preference_context.merge(return_route_preference: true)
    context = context_for(
      boundary_intervals: { predecessors: [previous], successors: [following], candidate_events: [] },
      travel_context: travel,
      preference_context: preference
    )

    features = filter(context, candidate).feasible_candidates.first.ranking_features
    assert_equal true, features[:route_efficiency_known]
    assert_equal Rational(0, 1), features[:route_efficiency]
  end

  test "OD-R1-P Q R S derives exact preferred-window ratios after union" do
    candidate = candidate_at(10, 0)
    cases = {
      "P" => [[interval(9, 30, 11, 0)], Rational(1, 1)],
      "Q" => [[interval(10, 0, 10, 15)], Rational(1, 2)],
      "R" => [[interval(11, 0, 12, 0)], Rational(0, 1)],
      "S" => [[interval(9, 50, 10, 10), interval(10, 10, 10, 40)], Rational(1, 1)]
    }
    cases.each do |id, (windows, expected)|
      preferences = context_for.preference_context.merge(profile_preferred_windows: windows)
      assert_equal expected, features_for(context_for(preference_context: preferences), candidate)[:profile_preference], "OD-R1-#{id}"
    end
  end

  test "OD-R1-Y Z AA AB computes exact signed fragmentation" do
    cases = [
      ["Y", custom_candidate(10, 0, 30), interval(10, 0, 12, 0), 0],
      ["Z", custom_candidate(10, 40, 30), interval(10, 0, 11, 30), 1],
      ["AA", custom_candidate(10, 0, 20), interval(10, 0, 10, 20), -1],
      ["AB", custom_candidate(10, 0, 30), interval(10, 0, 11, 0), 0]
    ]
    cases.each do |id, candidate, free, expected|
      preferences = context_for.preference_context.merge(fragmentation_base_intervals: [free])
      context = context_for(duration_minutes: candidate.duration_minutes, preference_context: preferences)
      assert_equal expected, features_for(context, candidate)[:fragmentation], "OD-R1-#{id}"
    end
  end

  test "OD-R1-AC AD AE computes unioned exact 24 23 and 25 hour daily load" do
    candidate = candidate_at(10, 0)
    days = [
      ["AC", utc_time(0), utc_time(0) + 86_400, [interval(8, 0, 9, 0), interval(8, 30, 9, 30)], Rational(1, 16)],
      ["AD", utc_time(0), utc_time(0) + 82_800, [{ start_at_utc: utc_time(8), end_at_utc: utc_time(9) }], Rational(1, 23)],
      ["AE", utc_time(0), utc_time(0) + 90_000, [{ start_at_utc: utc_time(8), end_at_utc: utc_time(9) }], Rational(1, 25)]
    ]
    days.each do |id, day_start, day_end, busy, expected|
      day = { local_date: Date.new(2026, 9, 10), start_at_utc: day_start, end_at_utc: day_end, busy_intervals: busy }
      preferences = context_for.preference_context.merge(daily_load_days: [day])
      assert_equal expected, features_for(context_for(preference_context: preferences), candidate)[:daily_load], "OD-R1-#{id}"
    end
  end

  test "OD-R1-AF weights every half-open local day touched across midnight" do
    start_at = Time.utc(2026, 9, 10, 23, 45)
    candidate = Scheduling::Candidate.new(start_at_utc: start_at, end_at_utc: start_at + 1_800, duration_minutes: 30, stable_sequence: 0)
    day_one = {
      local_date: Date.new(2026, 9, 10), start_at_utc: Time.utc(2026, 9, 10), end_at_utc: Time.utc(2026, 9, 11),
      busy_intervals: [{ start_at_utc: Time.utc(2026, 9, 10, 8), end_at_utc: Time.utc(2026, 9, 10, 10) }]
    }
    day_two = {
      local_date: Date.new(2026, 9, 11), start_at_utc: Time.utc(2026, 9, 11), end_at_utc: Time.utc(2026, 9, 12),
      busy_intervals: [{ start_at_utc: Time.utc(2026, 9, 11, 8), end_at_utc: Time.utc(2026, 9, 11, 9) }]
    }
    preferences = context_for.preference_context.merge(
      daily_load_days: [day_one, day_two],
      coverage: { fragmentation_complete: true, daily_load_complete: true, touched_local_dates: [day_one[:local_date], day_two[:local_date]] }
    )
    context = context_for(
      window_start_utc: Time.utc(2026, 9, 10, 23), window_end_utc: Time.utc(2026, 9, 11, 1),
      working_windows: nil, preference_context: preferences
    )

    assert_equal Rational(1, 16), features_for(context, candidate)[:daily_load]
    reversed = context_for(
      window_start_utc: Time.utc(2026, 9, 10, 23), window_end_utc: Time.utc(2026, 9, 11, 1), working_windows: nil,
      preference_context: preferences.merge(daily_load_days: [day_two, day_one], coverage: preferences[:coverage].merge(touched_local_dates: preferences[:coverage][:touched_local_dates].reverse))
    )
    assert_equal features_for(context, candidate), features_for(reversed, candidate), "OD-R1-AH touched-day order"
  end

  test "OD-R1-AG rejects incomplete fragmentation or daily-load coverage" do
    candidate = candidate_at(10, 0)
    %i[fragmentation_complete daily_load_complete].each do |key|
      coverage = context_for.preference_context[:coverage].merge(key => false)
      preferences = context_for.preference_context.merge(coverage: coverage)
      assert_raises(Scheduling::ConstraintFilter::IncompleteRankingContext) do
        filter(context_for(preference_context: preferences), candidate)
      end
    end
  end


  test "OD-R1-K preserves hard-feasible candidates when optional baselines are missing" do
    candidate = candidate_at(10, 0)
    previous = { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9) }
    successors = [
      { event_id: 2, start_at_utc: utc_time(11), end_at_utc: utc_time(12) },
      { event_id: 3, start_at_utc: utc_time(11), end_at_utc: utc_time(13) }
    ]
    bindings = { 1 => fixed("A"), 2 => fixed("B"), 3 => fixed("C") }
    routes = [route("A", "TASK", 12, 0), route("TASK", "B", 18, 0), route("TASK", "C", 18, 0)]
    preference = context_for.preference_context.merge(return_route_preference: true)

    [successors.first(1), successors].each do |selected|
      context = context_for(
        boundary_intervals: { predecessors: [previous], successors: selected, candidate_events: [] },
        travel_context: travel_context(bindings: bindings, routes: routes), preference_context: preference
      )
      features = features_for(context, candidate)
      assert_nil features[:route_efficiency], "OD-R1-K optional baseline"
      assert_equal false, features[:route_efficiency_known]
    end
  end

  test "OD-R1-U uses exact four-fifths efficiency and thirty travel minutes" do
    candidate = candidate_at(10, 0)
    previous = { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9) }
    following = { event_id: 2, start_at_utc: utc_time(11), end_at_utc: utc_time(12) }
    travel = travel_context(
      bindings: { 1 => fixed("A"), 2 => fixed("B") },
      routes: [route("A", "TASK", 12, 0), route("TASK", "B", 18, 0), route("A", "B", 24, 0)]
    )
    preference = context_for.preference_context.merge(return_route_preference: true)
    features = features_for(context_for(
      boundary_intervals: { predecessors: [previous], successors: [following], candidate_events: [] },
      travel_context: travel, preference_context: preference
    ), candidate)

    assert_equal Rational(4, 5), features[:route_efficiency], "OD-R1-U"
    assert_equal 30, features[:total_travel_minutes], "OD-R1-U"
  end

  test "OD-R1-X disabled return-route state is neutral when false or omitted" do
    candidate = candidate_at(10, 0)
    [false, nil].each do |setting|
      preference = context_for.preference_context.merge(return_route_preference: setting)
      features = features_for(context_for(preference_context: preference), candidate)
      assert_equal [false, false, nil], [features[:route_efficiency_enabled], features[:route_efficiency_known], features[:route_efficiency]], "OD-R1-X"
    end
  end


  test "OD-R1-M N external neighbors reject slots beyond exact travel boundaries" do
    day = Date.new(2026, 9, 7)
    preferences = context_for.preference_context.merge(
      daily_load_days: [{ local_date: day, start_at_utc: Time.utc(2026, 9, 7), end_at_utc: Time.utc(2026, 9, 8), busy_intervals: [] }],
      coverage: { fragmentation_complete: true, daily_load_complete: true, touched_local_dates: [day] }
    )
    base = {
      window_start_utc: Time.utc(2026, 9, 7, 18), window_end_utc: Time.utc(2026, 9, 7, 20),
      working_windows: nil, preference_context: preferences
    }
    m_candidate = Scheduling::Candidate.new(
      start_at_utc: Time.utc(2026, 9, 7, 18), end_at_utc: Time.utc(2026, 9, 7, 18, 30), duration_minutes: 30, stable_sequence: 0
    )
    predecessor = { event_id: 1, start_at_utc: Time.utc(2026, 9, 7, 17), end_at_utc: Time.utc(2026, 9, 7, 17, 50) }
    m_context = context_for(**base, boundary_intervals: { predecessors: [predecessor], successors: [], candidate_events: [] },
      travel_context: travel_context(bindings: { 1 => fixed("A") }, routes: [route("A", "TASK", 25, 0)]))
    assert_empty filter(m_context, m_candidate).feasible_candidates, "OD-R1-M candidate18:00 precedes earliest18:15"

    n_candidate = Scheduling::Candidate.new(
      start_at_utc: Time.utc(2026, 9, 7, 18, 30), end_at_utc: Time.utc(2026, 9, 7, 19), duration_minutes: 30, stable_sequence: 0
    )
    successor = { event_id: 2, start_at_utc: Time.utc(2026, 9, 7, 19, 10), end_at_utc: Time.utc(2026, 9, 7, 20) }
    n_context = context_for(**base, boundary_intervals: { predecessors: [], successors: [successor], candidate_events: [] },
      travel_context: travel_context(bindings: { 2 => fixed("B") }, routes: [route("TASK", "B", 25, 0)]))
    assert_empty filter(n_context, n_candidate).feasible_candidates, "OD-R1-N candidate end19:00 exceeds latest18:45"
  end


  test "OD-R1-U explicit no-movement makes route efficiency not applicable" do
    candidate = candidate_at(10, 0)
    previous = { event_id: 1, start_at_utc: utc_time(8), end_at_utc: utc_time(9) }
    following = { event_id: 2, start_at_utc: utc_time(11), end_at_utc: utc_time(12) }
    travel = travel_context(
      bindings: { 1 => fixed("A"), 2 => fixed("B") },
      routes: [route("A", "B", 24, 0)]
    ).merge(task_binding: { resolution: "explicitly_no_movement", place_ref: nil })
    preference = context_for.preference_context.merge(return_route_preference: true)
    features = features_for(context_for(
      boundary_intervals: { predecessors: [previous], successors: [following], candidate_events: [] },
      travel_context: travel, preference_context: preference
    ), candidate)

    assert_nil features[:route_efficiency], "OD-R1-U no-movement is not applicable"
    assert_equal false, features[:route_efficiency_known]
    assert_equal 0, features[:total_travel_minutes], "OD-R1-U no-movement has no required legs"
  end

  test "OD-R1-L uses per-leg crossed reserve and buffer-only exact boundaries" do
    candidate = candidate_at(10, 0)
    tied = [event(1, 9, 28), event(2, 9, 28)]
    travel = travel_context(bindings: { 1 => fixed("A"), 2 => fixed("B") }, routes: [
      route("A", "TASK", 12, 20), route("B", "TASK", 25, 0)
    ])
    features = features_for(context_for(
      boundary_intervals: { predecessors: tied, successors: [], candidate_events: [] }, travel_context: travel
    ), candidate)
    assert_equal 25, features[:total_travel_minutes], "OD-R1-L before max25"
    too_close = [event(1, 9, 29), event(2, 9, 29)]
    assert_empty filter(context_for(
      boundary_intervals: { predecessors: too_close, successors: [], candidate_events: [] }, travel_context: travel
    ), candidate).feasible_candidates, "OD-R1-L crossed reserve is 32 (not max-plus-max 45)"

    buffer_event = event(3, 9, 45)
    buffer_travel = travel_context(bindings: { 3 => fixed("C") }, routes: [route("C", "TASK", 0, 15)])
    assert_equal 1, filter(context_for(
      boundary_intervals: { predecessors: [buffer_event], successors: [], candidate_events: [] }, travel_context: buffer_travel
    ), candidate).feasible_candidates.length, "OD-R1-L buffer-only15"
    assert_empty filter(context_for(
      boundary_intervals: { predecessors: [event(3, 9, 46)], successors: [], candidate_events: [] }, travel_context: buffer_travel
    ), candidate).feasible_candidates, "OD-R1-L buffer-only gap14"
  end

  test "OD-R1-L applies successor reserve28 and two-sided four-pair minimum" do
    candidate = candidate_at(10, 0)
    predecessors = [event(1, 9, 0), event(2, 9, 0)]
    successors = [
      { event_id: 3, start_at_utc: utc_time(11), end_at_utc: utc_time(12) },
      { event_id: 4, start_at_utc: utc_time(11), end_at_utc: utc_time(13) }
    ]
    routes = [
      route("A", "TASK", 12, 0), route("B", "TASK", 25, 0),
      route("TASK", "C", 18, 10), route("TASK", "D", 10, 0),
      route("A", "C", 18, 0), route("A", "D", 22, 0),
      route("B", "C", 43, 0), route("B", "D", 35, 0)
    ]
    travel = travel_context(bindings: { 1 => fixed("A"), 2 => fixed("B"), 3 => fixed("C"), 4 => fixed("D") }, routes: routes)
    preference = context_for.preference_context.merge(return_route_preference: true)
    features = features_for(context_for(
      boundary_intervals: { predecessors: predecessors, successors: successors, candidate_events: [] },
      travel_context: travel, preference_context: preference
    ), candidate)

    assert_equal 43, features[:total_travel_minutes], "OD-R1-L T43"
    assert_equal Rational(3, 5), features[:route_efficiency], "OD-R1-L four P-by-N pairs minimum"
    exact_successor = { event_id: 3, start_at_utc: utc_time(10, 58), end_at_utc: utc_time(12) }
    exact = filter(context_for(
      boundary_intervals: { predecessors: [], successors: [exact_successor], candidate_events: [] },
      travel_context: travel_context(bindings: { 3 => fixed("C") }, routes: [route("TASK", "C", 18, 10)])
    ), candidate)
    assert_equal 1, exact.feasible_candidates.length, "OD-R1-L successor reserve28"
    too_close_successor = exact_successor.merge(start_at_utc: utc_time(10, 57))
    assert_empty filter(context_for(
      boundary_intervals: { predecessors: [], successors: [too_close_successor], candidate_events: [] },
      travel_context: travel_context(bindings: { 3 => fixed("C") }, routes: [route("TASK", "C", 18, 10)])
    ), candidate).feasible_candidates, "OD-R1-L successor gap27"
  end

  test "HC positive cases enforce busy opening working and duration without revival" do
    candidate = candidate_at(10, 0)
    busy = filter(context_for(busy_intervals: [interval(10, 1, 10, 2)]), candidate)
    opening = filter(context_for(opening_hours_context: { required: true, intervals: [interval(9, 0, 10, 29)] }), candidate)
    working = filter(context_for(working_windows: [interval(10, 1, 11, 0)]), candidate)
    duration = filter(context_for(duration_minutes: 45), candidate)

    assert_equal 1, busy.bounded_rejection_counts[:busy]
    assert_equal 1, opening.bounded_rejection_counts[:opening]
    assert_equal 1, working.bounded_rejection_counts[:working]
    assert_equal 1, duration.bounded_rejection_counts[:duration]
  end


  test "OD-R1-AH AI is invariant to input order and duplicate occupied intervals" do
    candidates = [candidate_at(10, 0), candidate_at(11, 0)]
    occupied = [interval(8, 0, 9, 0), interval(8, 30, 9, 30), interval(8, 0, 9, 0)]
    day = { local_date: Date.new(2026, 9, 10), start_at_utc: utc_time(0), end_at_utc: utc_time(0) + 86_400, busy_intervals: occupied }
    preferences = context_for.preference_context.merge(daily_load_days: [day])
    context = context_for(preference_context: preferences)
    service = Scheduling::ConstraintFilter.new

    forward = service.call(context: context, candidates: candidates).feasible_candidates.to_h { |item| [item.start_at_utc, item.ranking_features] }
    day_reversed = day.merge(busy_intervals: occupied.reverse)
    reversed_context = context_for(preference_context: preferences.merge(daily_load_days: [day_reversed]))
    reversed = service.call(context: reversed_context, candidates: candidates.reverse).feasible_candidates.to_h { |item| [item.start_at_utc, item.ranking_features] }

    assert_equal forward, reversed, "OD-R1-AH input order"
    assert_equal Rational(1, 16), forward.fetch(candidates.first.start_at_utc)[:daily_load], "OD-R1-AI dedup and union"
  end

  test "OD-R1-AC stored all-day occupancy yields exact one" do
    candidate = candidate_at(10, 0)
    day = {
      local_date: Date.new(2026, 9, 10), start_at_utc: utc_time(0), end_at_utc: utc_time(0) + 86_400,
      busy_intervals: [{ start_at_utc: utc_time(0), end_at_utc: utc_time(0) + 86_400 }]
    }
    preferences = context_for.preference_context.merge(daily_load_days: [day])
    assert_equal Rational(1, 1), features_for(context_for(preference_context: preferences), candidate)[:daily_load]
  end


  test "AC-005 stored all-day busy interval rejects overlap but permits midnight adjacency" do
    all_day = {
      event_id: 1, all_day: true, parent_id: nil,
      start_at_utc: Time.utc(2026, 9, 10), end_at_utc: Time.utc(2026, 9, 11)
    }
    overlapping = Scheduling::Candidate.new(
      start_at_utc: Time.utc(2026, 9, 10, 12), end_at_utc: Time.utc(2026, 9, 10, 12, 30), duration_minutes: 30, stable_sequence: 0
    )
    assert_empty filter(context_for(busy_intervals: [all_day]), overlapping).feasible_candidates

    day = Date.new(2026, 9, 11)
    preferences = context_for.preference_context.merge(
      daily_load_days: [{ local_date: day, start_at_utc: Time.utc(2026, 9, 11), end_at_utc: Time.utc(2026, 9, 12), busy_intervals: [] }],
      coverage: { fragmentation_complete: true, daily_load_complete: true, touched_local_dates: [day] }
    )
    adjacent = Scheduling::Candidate.new(
      start_at_utc: Time.utc(2026, 9, 11), end_at_utc: Time.utc(2026, 9, 11, 0, 30), duration_minutes: 30, stable_sequence: 0
    )
    context = context_for(
      window_start_utc: Time.utc(2026, 9, 11), window_end_utc: Time.utc(2026, 9, 11, 1),
      working_windows: nil, busy_intervals: [all_day], preference_context: preferences
    )
    assert_equal 1, filter(context, adjacent).feasible_candidates.length, "AC-005 half-open midnight adjacency"
  end

  test "OD-R1-AK preference cannot revive a busy candidate" do
    candidate = candidate_at(10, 0)
    preferences = context_for.preference_context.merge(profile_preferred_windows: [interval(10, 0, 10, 30)])
    result = filter(context_for(busy_intervals: [interval(10, 0, 10, 30)], preference_context: preferences), candidate)
    assert_empty result.feasible_candidates
    assert_equal 1, result.bounded_rejection_counts[:busy]
  end

  private

  def filter(context, candidate)
    Scheduling::ConstraintFilter.new.call(context: context, candidates: [candidate])
  end

  def features_for(context, candidate)
    filter(context, candidate).feasible_candidates.fetch(0).ranking_features
  end

  def candidate_at(hour, minute)
    Scheduling::Candidate.new(start_at_utc: utc_time(hour, minute), end_at_utc: utc_time(hour, minute) + 1_800, duration_minutes: 30, stable_sequence: 0)
  end

  def custom_candidate(hour, minute, duration)
    start_at = utc_time(hour, minute)
    Scheduling::Candidate.new(start_at_utc: start_at, end_at_utc: start_at + duration * 60, duration_minutes: duration, stable_sequence: 0)
  end

  def interval(start_hour, start_minute, end_hour, end_minute)
    { start_at_utc: utc_time(start_hour, start_minute), end_at_utc: utc_time(end_hour, end_minute) }
  end

  def event(id, end_hour, end_minute)
    { event_id: id, start_at_utc: utc_time(end_hour - 1, end_minute), end_at_utc: utc_time(end_hour, end_minute) }
  end

  def context_for(overrides = {})
    defaults = {
      window_start_utc: utc_time(8), window_end_utc: utc_time(18), duration_minutes: 30,
      trusted_time_zone: "UTC",
      busy_intervals: [], blocked_windows: [], working_windows: [{ start_at_utc: utc_time(8), end_at_utc: utc_time(18) }],
      lunch_policy: { protect: false, interval: nil }, opening_hours_context: { required: false, intervals: [] },
      boundary_intervals: { predecessors: [], successors: [], candidate_events: [] }, travel_context: { required: false },
      preference_context: {
        profile_preferred_windows: :not_configured, request_preferred_windows: :not_configured,
        return_route_preference: false, fragmentation_base_intervals: [],
        daily_load_days: [{ local_date: Date.new(2026, 9, 10), start_at_utc: utc_time(0), end_at_utc: utc_time(23) + 3_600, busy_intervals: [] }],
        coverage: { fragmentation_complete: true, daily_load_complete: true, touched_local_dates: [Date.new(2026, 9, 10)] }
      }
    }
    Context.new(**defaults.merge(overrides))
  end

  def travel_context(bindings:, routes:)
    route_index = routes.to_h { |entry| [[entry[:from_place_ref], entry[:to_place_ref], entry[:route_profile_ref]], entry] }
    { required: true, canonical: { selected_route_profile_ref: "walk" }, task_binding: fixed("TASK"), event_bindings: bindings, route_index: route_index, global_safety_minimum_minutes: 0, user_profile_buffer_minutes: 0, request_scoped_buffer_minutes: 0 }
  end

  def fixed(ref)
    { resolution: "fixed_place", place_ref: ref }
  end

  def route(from, to, travel, buffer)
    { from_place_ref: from, to_place_ref: to, route_profile_ref: "walk", travel_minutes: travel, arrival_buffer_minutes: buffer }
  end

  def utc_time(hour, minute = 0)
    Time.utc(2026, 9, 10, hour, minute)
  end
end
