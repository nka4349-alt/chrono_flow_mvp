# frozen_string_literal: true

require "test_helper"

class SchedulingRecommendationServiceTest < ActiveSupport::TestCase
  StubFilterResult = Data.define(:feasible_candidates, :bounded_rejection_counts, :terminal_failure)

  class CallRecorder
    attr_reader :calls

    def initialize(result, name)
      @result = result
      @name = name
      @calls = []
    end

    def call(**arguments)
      @calls << [@name, arguments]
      @result
    end
  end

  class StaticBuilder
    def initialize(context)
      @context = context
    end

    def call(**)
      @context
    end
  end

  class RaisingBuilder
    def initialize(error)
      @error = error
    end

    def call(**)
      raise @error
    end
  end

  test "runs the exact pipeline ranks all candidates then applies top k" do
    context = Object.new.freeze
    generated = [candidate(3), candidate(1), candidate(2)].freeze
    filtered = StubFilterResult.new(
      feasible_candidates: generated,
      bounded_rejection_counts: { busy: 2 }.freeze,
      terminal_failure: nil
    )
    builder = CallRecorder.new(context, :builder)
    generator = CallRecorder.new(generated, :generator)
    filter = CallRecorder.new(filtered, :filter)
    ranker = CallRecorder.new(generated.sort_by(&:stable_sequence).freeze, :ranker)
    service = build_service(builder, generator, filter, ranker)

    result = service.call(**call_arguments, top_k: 2)

    assert_predicate result, :feasible?
    assert_equal [1, 2], result.candidates.map(&:stable_sequence)
    assert_equal({ busy: 2 }, result.bounded_rejection_counts)
    assert_equal context, generator.calls.first.last.fetch(:context)
    assert_equal generated, filter.calls.first.last.fetch(:candidates)
    assert_equal generated, ranker.calls.first.last.fetch(:candidates)
    assert_predicate result, :frozen?
    assert_predicate result.candidates, :frozen?
  end

  test "returns travel unavailable only for an unresolved required travel survivor" do
    result = service_for(feasible: [], terminal: :required_travel_unavailable).call(**call_arguments)

    assert_predicate result, :error?
    assert_equal :required_travel_unavailable, result.failure.category
    assert_equal "TRAVEL_TIME_UNAVAILABLE", result.failure.code_hint
    assert_nil result.failure.candidate_count
  end

  test "maps allowlisted terminal categories without exposing details" do
    expected = {
      location_required: [:location_context_required, "LOCATION_REQUIRED"],
      travel_time_unavailable: [:required_travel_unavailable, "TRAVEL_TIME_UNAVAILABLE"]
    }

    expected.each do |terminal, (category, code)|
      result = service_for(feasible: [], terminal: terminal).call(**call_arguments)
      assert_equal category, result.failure.category
      assert_equal code, result.failure.code_hint
    end
  end

  test "returns no feasible slot only after complete evaluation" do
    [nil, :no_feasible_slot].each do |terminal|
      result = service_for(feasible: [], terminal: terminal).call(**call_arguments)

      assert_equal :no_feasible_candidate, result.failure.category
      assert_equal "NO_FEASIBLE_SLOT", result.failure.code_hint
      assert_equal 0, result.failure.candidate_count
      assert_empty result.candidates
    end
  end

  test "success takes precedence over unresolved failures" do
    feasible = candidate(1)
    result = service_for(feasible: [feasible], terminal: :required_travel_unavailable).call(**call_arguments)

    assert_predicate result, :feasible?
    assert_nil result.failure
    assert_equal [feasible], result.candidates
  end

  test "rejects invalid top k before reading context" do
    builder = CallRecorder.new(Object.new, :builder)
    service = build_service(builder, CallRecorder.new([], :generator),
                            CallRecorder.new(nil, :filter), CallRecorder.new([], :ranker))

    [nil, 0, 21, "3"].each do |top_k|
      result = service.call(**call_arguments, top_k: top_k)
      assert_predicate result, :error?
      assert_equal :invalid_request, result.failure.category
      assert_nil result.failure.code_hint
      assert_empty builder.calls
    end
  end

  test "maps typed context builder failures and sanitizes integrity failures" do
    expected = {
      Scheduling::ContextBuilder::InvalidDuration.new("duration secret") => [:invalid_duration, "INVALID_DURATION"],
      Scheduling::ContextBuilder::InvalidTimeWindow.new("window secret") => [:invalid_request, "INVALID_TIME_WINDOW"],
      Scheduling::ContextBuilder::OpeningHoursUnavailable.new("opening secret") => [:opening_hours_unavailable, "OPENING_HOURS_UNAVAILABLE"],
      Scheduling::ContextBuilder::ValidationError.new("binding secret") => [:context_failure, nil],
      ArgumentError.new("internal argument secret") => [:unexpected_internal_failure, nil]
    }

    expected.each do |error, (category, code)|
      result = build_service(RaisingBuilder.new(error), CallRecorder.new([], :generator),
                             CallRecorder.new(nil, :filter), CallRecorder.new([], :ranker)).call(**call_arguments)
      assert_equal category, result.failure.category
      code.nil? ? assert_nil(result.failure.code_hint) : assert_equal(code, result.failure.code_hint)
      refute_includes result.inspect, "secret"
    end
  end

  test "OD-R1-AK real pipeline cannot revive an infeasible preferred candidate and remains read only offline" do
    context = production_context
    service = build_service(
      StaticBuilder.new(context),
      Scheduling::CandidateGenerator.new,
      Scheduling::ConstraintFilter.new,
      Scheduling::SlotRanker.new
    )
    writes = []
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      writes << payload[:sql] if payload[:sql].match?(/\A\s*(?:INSERT|UPDATE|DELETE)\b/i)
    end
    event_count = Event.count

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      without_network do
        service.call(**call_arguments, top_k: 1)
      end
    end

    assert_predicate result, :feasible?
    assert_equal [Time.utc(2026, 9, 7, 10, 30)], result.candidates.map(&:start_at_utc)
    assert_equal Rational(0, 1), result.candidates.first.ranking_features[:profile_preference]
    assert_empty writes
    assert_equal event_count, Event.count
    assert_predicate result.candidates.first, :frozen?
  end


  test "real production pipeline ranks every feasible candidate before applying top k" do
    context = production_context(block_candidate: false)
    service = build_service(
      StaticBuilder.new(context), Scheduling::CandidateGenerator.new,
      Scheduling::ConstraintFilter.new, Scheduling::SlotRanker.new
    )

    result = service.call(**call_arguments, top_k: 1)

    assert_predicate result, :feasible?
    assert_equal 1, result.candidates.length
    assert_equal Time.utc(2026, 9, 7, 10), result.candidates.first.start_at_utc
    assert_equal Rational(1, 1), result.candidates.first.ranking_features[:profile_preference]
  end

  test "sanitizes unexpected errors without exception or event detail" do
    sensitive = Class.new(StandardError)
    builder = Object.new
    builder.define_singleton_method(:call) { |**| raise sensitive, "secret SQL and event title" }
    service = build_service(builder, CallRecorder.new([], :generator),
                            CallRecorder.new(nil, :filter), CallRecorder.new([], :ranker))

    result = service.call(**call_arguments)

    assert_equal :unexpected_internal_failure, result.failure.category
    refute_includes result.inspect, "secret"
    refute_includes result.inspect, "event title"
  end

  test "defensively copies result collections" do
    feasible = [candidate(1)]
    counts = { busy: 1 }
    result = service_for(feasible: feasible, counts: counts).call(**call_arguments)

    feasible.clear
    counts[:busy] = 99
    assert_equal 1, result.candidates.length
    assert_equal 1, result.bounded_rejection_counts.fetch(:busy)
    assert_raises(FrozenError) { result.candidates << candidate(2) }
    assert_raises(FrozenError) { result.bounded_rejection_counts[:busy] = 2 }
  end

  private

  def service_for(feasible:, terminal: nil, counts: {})
    context = Object.new.freeze
    generated = feasible.dup.freeze
    filtered = StubFilterResult.new(
      feasible_candidates: feasible,
      bounded_rejection_counts: counts,
      terminal_failure: terminal
    )
    build_service(
      CallRecorder.new(context, :builder),
      CallRecorder.new(generated, :generator),
      CallRecorder.new(filtered, :filter),
      CallRecorder.new(feasible.sort_by(&:stable_sequence).freeze, :ranker)
    )
  end

  def build_service(builder, generator, filter, ranker)
    Scheduling::RecommendationService.new(
      context_builder: builder,
      candidate_generator: generator,
      constraint_filter: filter,
      slot_ranker: ranker
    )
  end

  def call_arguments
    {
      user: Object.new,
      search_window: { "start_at" => "2026-09-07T10:00:00Z", "end_at" => "2026-09-07T12:00:00Z" },
      duration_minutes: 30,
      trusted_time_zone: "UTC",
      server_context: {}.freeze
    }
  end

  def candidate(sequence)
    start = Time.utc(2026, 9, 7, 10) + sequence.minutes
    Scheduling::Candidate.new(
      start_at_utc: start,
      end_at_utc: start + 30.minutes,
      duration_minutes: 30,
      stable_sequence: sequence,
      ranking_features: {}
    )
  end

  def production_context(block_candidate: true)
    interval = ->(start_at, end_at) { { start_at_utc: start_at, end_at_utc: end_at } }
    window_start = Time.utc(2026, 9, 7, 10)
    window_end = Time.utc(2026, 9, 7, 11)
    Scheduling::Context.new(
      user_id: 1,
      trusted_time_zone: "UTC",
      window_start_utc: window_start,
      window_end_utc: window_end,
      duration_minutes: 30,
      busy_intervals: [],
      boundary_intervals: {
        predecessors: [], successors: [], candidate_events: [],
        coverage: { overlap_complete: true, predecessor_complete: true, successor_complete: true,
                    exact_instants: [window_start] }
      },
      blocked_windows: block_candidate ? [interval.call(window_start, window_start + 30.minutes)] : [],
      working_windows: [interval.call(window_start, window_end)],
      lunch_policy: { protect: false, interval: nil },
      travel_context: {
        canonical: nil, task_ref: "task-1", task_binding: nil, event_bindings: {}, route_index: {},
        global_safety_minimum_minutes: 0, user_profile_buffer_minutes: nil,
        request_scoped_buffer_minutes: nil, required: false
      },
      opening_hours_context: { required: false, intervals: nil },
      preference_context: {
        profile_preferred_windows: [interval.call(window_start, window_start + 30.minutes)],
        request_preferred_windows: [], return_route_preference: false,
        fragmentation_base_intervals: [interval.call(window_start + 30.minutes, window_end)],
        daily_load_days: [{ local_date: Date.new(2026, 9, 7), start_at_utc: Time.utc(2026, 9, 7),
                            end_at_utc: Time.utc(2026, 9, 8), busy_intervals: [] }],
        explicit_exact_start: nil,
        coverage: { fragmentation_complete: true, daily_load_complete: true,
                    touched_local_dates: [Date.new(2026, 9, 7)] }
      },
      source_snapshot: "snapshot-1"
    )
  end

  def without_network
    singleton = Net::HTTP.singleton_class
    original = Net::HTTP.method(:start)
    singleton.define_method(:start) { |*| raise "external network attempted" }
    yield
  ensure
    singleton.define_method(:start, original) if original
  end
end

class SchedulingRecommendationServiceDatabaseIntegrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @user = User.create!(
      name: "P1 integration owner",
      email: "p1-service-#{SecureRandom.hex(8)}@example.test",
      password: "password123"
    )
    @event = Event.create!(
      title: "private integration event",
      created_by: @user,
      start_at: Time.utc(2026, 9, 7, 10, 30),
      end_at: Time.utc(2026, 9, 7, 11),
      color: "#3b82f6"
    )
  end

  def teardown
    EventParticipant.where(event_id: @event&.id).delete_all
    Event.where(id: @event&.id).delete_all
    User.where(id: @user&.id).delete_all
  end

  test "P1-AC-027 P1-AC-028 P1-AC-029 real database pipeline is immutable read only and offline" do
    service = Scheduling::RecommendationService.new(
      context_builder: Scheduling::ContextBuilder.new,
      candidate_generator: Scheduling::CandidateGenerator.new,
      constraint_filter: Scheduling::ConstraintFilter.new,
      slot_ranker: Scheduling::SlotRanker.new
    )
    before_count = Event.count
    before_fingerprint = event_fingerprint
    prohibited_sql = []
    network_attempts = 0
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      sql = payload[:sql].to_s
      prohibited_sql << sql if sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE|UPSERT|MERGE|CREATE|ALTER|DROP|TRUNCATE|COMMENT|GRANT|REVOKE)\b/i)
    end

    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      without_external_network(-> { network_attempts += 1 }) do
        service.call(**service_arguments)
      end
    end

    assert_predicate result, :feasible?
    assert_operator result.candidates.length, :>, 0
    assert_nil result.failure
    assert_equal before_count, Event.count
    assert_equal before_fingerprint, event_fingerprint
    assert_empty prohibited_sql
    assert_equal 0, network_attempts
  end

  private

  def service_arguments
    {
      user: @user,
      search_window: { start_at: "2026-09-07T10:00:00Z", end_at: "2026-09-07T12:00:00Z" },
      duration_minutes: 30,
      trusted_time_zone: "UTC",
      server_context: {
        invocation_now: "2026-09-07T09:00:00Z",
        authenticated_tenant_scope_ref: "tenant-p1",
        current_task_ref: "task-p1",
        current_schedule_snapshot_version: "snapshot-p1",
        global_safety_minimum_minutes: 0,
        user_profile_buffer_minutes: nil,
        request_scoped_buffer_minutes: nil,
        protect_lunch: false,
        lunch_window: nil,
        blocked_windows: [],
        working_windows: nil,
        opening_hours_required: false,
        opening_intervals: nil,
        explicit_exact_start: nil,
        canonical_static_travel_context: canonical_travel_context,
        profile_preferred_windows: :not_configured,
        request_preferred_windows: [],
        return_route_preference: false,
        source_snapshot: "snapshot-p1"
      }
    }
  end

  def canonical_travel_context
    value = {
      profile_id: "p1-canonical-static-travel-context-v1",
      tenant_scope_ref: "tenant-p1",
      task_ref: "task-p1",
      schedule_snapshot_version: "snapshot-p1",
      context_revision: nil,
      selected_route_profile_ref: "walking",
      evaluated_at: "2026-09-07T09:00:00Z",
      resolved_at: "2026-09-07T08:59:00Z",
      fresh_until: "2026-09-07T10:00:00Z",
      applicable_window: { start_at: "2026-09-07T00:00:00Z", end_at: "2026-09-08T00:00:00Z" },
      place_bindings: [
        { subject_type: "event", subject_ref: @event.id.to_s, resolution: "explicitly_no_movement", place_ref: nil },
        { subject_type: "task", subject_ref: "task-p1", resolution: "explicitly_no_movement", place_ref: nil }
      ],
      route_entries: []
    }
    payload = value.reject { |key, _| %i[context_revision evaluated_at].include?(key) }
    value[:context_revision] = "ctx_#{Digest::SHA256.hexdigest(JSON.generate(canonical_sort(payload)))}"
    value
  end

  def canonical_sort(value)
    case value
    when Hash
      value.map { |key, item| [key.to_s, canonical_sort(item)] }.sort_by { |key, _| key.b }.to_h
    when Array
      value.map { |item| canonical_sort(item) }
    else
      value
    end
  end

  def event_fingerprint
    rows = Event.where(id: @event.id).order(:id).pluck(*Event.column_names.map(&:to_sym))
    Digest::SHA256.hexdigest(Marshal.dump(rows))
  end

  def without_external_network(on_attempt)
    singleton = Net::HTTP.singleton_class
    original = Net::HTTP.method(:start)
    singleton.define_method(:start) do |*|
      on_attempt.call
      raise "external network attempted"
    end
    yield
  ensure
    singleton.define_method(:start, original) if original
  end
end
