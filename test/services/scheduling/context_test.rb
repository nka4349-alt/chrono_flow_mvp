# frozen_string_literal: true

require 'test_helper'

class Scheduling::ContextTest < ActiveSupport::TestCase
  def test_constructs_defensive_deeply_frozen_value
    busy = [event_interval(1, at(9), at(10))]
    caller_date = Date.new(2026, 9, 10)
    preference = default_preference
    preference[:coverage][:touched_local_dates] = [caller_date]
    context = build_context(busy_intervals: busy, preference_context: preference)
    busy.first[:start_at_utc] = at(12)

    assert_equal at(9), context.busy_intervals.first[:start_at_utc]
    assert_predicate context, :frozen?
    assert_predicate context.busy_intervals, :frozen?
    assert_predicate context.busy_intervals.first, :frozen?
    assert_not_predicate caller_date, :frozen?
    assert_not_same caller_date, context.preference_context[:coverage][:touched_local_dates].first
    assert_predicate context.preference_context[:coverage][:touched_local_dates].first, :frozen?
    assert_raises(FrozenError) { context.preference_context[:coverage][:touched_local_dates] << Date.new(2026, 9, 11) }
  end

  def test_rejects_invalid_and_duplicate_event_intervals
    assert_raises(Scheduling::Context::ValidationError) do
      build_context(busy_intervals: [event_interval(1, at(10), at(10))])
    end
    assert_raises(Scheduling::Context::ValidationError) do
      build_context(busy_intervals: [event_interval(1, at(9), at(10)), event_interval(1, at(11), at(12))])
    end
  end

  def test_preserves_not_configured_empty_zero_false_and_nil
    context = build_context
    assert_equal :not_configured, context.preference_context[:profile_preferred_windows]
    assert_empty context.preference_context[:request_preferred_windows]
    assert_equal false, context.preference_context[:return_route_preference]
    assert_equal 0, context.travel_context[:global_safety_minimum_minutes]
    assert_nil context.travel_context[:user_profile_buffer_minutes]
    assert_nil context.working_windows
  end

  def test_rejects_invalid_iana_zone_and_incomplete_direct_canonical_travel
    assert_raises(Scheduling::Context::ValidationError) { build_context(trusted_time_zone: 'Not/A_Zone') }
    malformed = {
      canonical: {}, task_ref: 'task', task_binding: { subject_type: 'task', subject_ref: 'task', resolution: 'explicitly_no_movement', place_ref: nil },
      event_bindings: {}, route_index: {}, global_safety_minimum_minutes: 0,
      user_profile_buffer_minutes: nil, request_scoped_buffer_minutes: nil, required: true
    }
    assert_raises(Scheduling::Context::ValidationError) { build_context(travel_context: malformed) }
  end

  private

  def build_context(overrides = {})
    values = {
      user_id: 1, trusted_time_zone: 'Asia/Tokyo', window_start_utc: at(9), window_end_utc: at(18), duration_minutes: 30,
      busy_intervals: [],
      boundary_intervals: { predecessors: [], successors: [], candidate_events: [],
                            coverage: { overlap_complete: true, predecessor_complete: true, successor_complete: true, exact_instants: [at(9)] } },
      blocked_windows: [], working_windows: nil, lunch_policy: { protect: false, interval: nil },
      travel_context: { canonical: nil, task_ref: 'task', task_binding: nil, event_bindings: {}, route_index: {},
                        global_safety_minimum_minutes: 0, user_profile_buffer_minutes: nil,
                        request_scoped_buffer_minutes: nil, required: false },
      opening_hours_context: { required: false, intervals: nil },
      preference_context: default_preference,
      source_snapshot: 'snapshot-1'
    }.merge(overrides)
    Scheduling::Context.new(**values)
  end

  def event_interval(id, start_at, end_at)
    { event_id: id, start_at_utc: start_at, end_at_utc: end_at, all_day: false, parent_id: nil }
  end

  def default_preference
    { profile_preferred_windows: :not_configured, request_preferred_windows: [],
      return_route_preference: false, fragmentation_base_intervals: [], daily_load_days: [],
      explicit_exact_start: nil,
      coverage: { fragmentation_complete: true, daily_load_complete: true, touched_local_dates: [] } }
  end

  def at(hour) = Time.utc(2026, 9, 10, hour)
end
