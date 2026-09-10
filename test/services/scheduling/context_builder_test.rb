# frozen_string_literal: true

require 'test_helper'

class Scheduling::ContextBuilderTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @user = User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(6)}@example.test", password: 'password123')
    @participant = User.create!(name: 'Participant', email: "participant-#{SecureRandom.hex(6)}@example.test", password: 'password123')
    @other = User.create!(name: 'Other', email: "other-#{SecureRandom.hex(6)}@example.test", password: 'password123')
  end

  def teardown
    EventParticipant.where(user_id: [@user&.id, @participant&.id, @other&.id].compact).delete_all
    Event.where(created_by_id: [@user&.id, @participant&.id, @other&.id].compact).delete_all
    User.where(id: [@user&.id, @participant&.id, @other&.id].compact).delete_all
  end

  test 'reads created and participating personal events, deduplicates, excludes unrelated, and preserves exact boundaries' do
    predecessor = event!(@user, '2026-09-10 08:20:00 UTC', '2026-09-10 08:50:00 UTC')
    tied = event!(@user, '2026-09-10 09:30:00 UTC', '2026-09-10 10:37:00 UTC')
    created = event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:37:00 UTC')
    participating = event!(@participant, '2026-09-10 11:00:00 UTC', '2026-09-10 12:00:00 UTC')
    EventParticipant.create!(event: participating, user: @user)
    EventParticipant.create!(event: created, user: @user)
    event!(@other, '2026-09-10 13:00:00 UTC', '2026-09-10 14:00:00 UTC')
    successor = event!(@user, '2026-09-10 19:00:00 UTC', '2026-09-10 19:30:00 UTC')

    before = Event.order(:id).pluck(:id, :start_at, :end_at, :all_day, :parent_id, :updated_at)
    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }
    arguments = valid_call(with_travel: true)
    context = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { builder.call(**arguments) }

    assert_equal [tied.id, created.id, participating.id].sort, context.busy_intervals.map { |row| row[:event_id] }.sort
    assert_equal [predecessor.id], context.boundary_intervals[:predecessors].map { |row| row[:event_id] }
    assert_equal [successor.id], context.boundary_intervals[:successors].map { |row| row[:event_id] }
    assert_equal 3, sql.count { |statement| statement.match?(/\ASELECT/i) && statement.include?('events') }
    assert_empty sql.grep(/\A\s*(?:INSERT|UPDATE|DELETE|UPSERT|ALTER|CREATE|DROP|TRUNCATE)\b/i)
    assert_equal before, Event.order(:id).pluck(:id, :start_at, :end_at, :all_day, :parent_id, :updated_at)
    assert_includes context.boundary_intervals[:coverage][:exact_instants], Time.utc(2026, 9, 10, 10, 37)
    assert_includes context.boundary_intervals[:coverage][:exact_instants], Time.utc(2026, 9, 10, 18, 30)
    assert_equal [Date.new(2026, 9, 10), Date.new(2026, 9, 11)],
                 context.preference_context[:coverage][:touched_local_dates]
  end

  test 'rejects persisted zero length interval rather than silently dropping it' do
    event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:00:00 UTC')
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**valid_call) }
  end

  test 'rejects unknown server keys, timezone offset mismatch, and more than fourteen local dates' do
    call = valid_call
    call[:server_context] = call[:server_context].merge(unknown: true)
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }

    call = valid_call.merge(search_window: { start_at: '2026-09-10T09:00:00Z', end_at: '2026-09-10T18:00:00+09:00' })
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }

    call = valid_call.merge(search_window: { start_at: '2026-09-01T00:00:00+09:00', end_at: '2026-09-15T00:00:01+09:00' })
    assert_raises(Scheduling::ContextBuilder::InvalidTimeWindow) { builder.call(**call) }

    exact = valid_call(start_at: '2026-09-01T00:00:00+09:00', end_at: '2026-09-15T00:00:00+09:00')
    assert_equal 14, builder.call(**exact).preference_context[:daily_load_days].length
  end

  test 'accepts valid winter summer and fractional instants and rejects leap seconds' do
    winter = valid_call(zone: 'America/New_York', start_at: '2026-01-10T09:00:00.125-05:00', end_at: '2026-01-10T10:00:00.125-05:00')
    summer = valid_call(zone: 'America/New_York', start_at: '2026-07-10T09:00:00-04:00', end_at: '2026-07-10T10:00:00-04:00')
    assert_instance_of Scheduling::Context, builder.call(**winter)
    assert_instance_of Scheduling::Context, builder.call(**summer)
    invalid = valid_call(start_at: '2026-09-10T18:00:60+09:00')
    assert_raises(Scheduling::ContextBuilder::InvalidTimeWindow) { builder.call(**invalid) }
  end

  test 'uses typed duration and opening failures and requires source snapshot' do
    assert_raises(Scheduling::ContextBuilder::InvalidDuration) { builder.call(**valid_call.merge(duration_minutes: 0)) }
    call = valid_call
    call[:server_context] = call[:server_context].merge(opening_hours_required: true, opening_intervals: nil)
    assert_raises(Scheduling::ContextBuilder::OpeningHoursUnavailable) { builder.call(**call) }
    call = valid_call
    call[:server_context] = call[:server_context].merge(source_snapshot: nil)
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
  end

  test 'rejects a schedule snapshot mismatch before any Event read' do
    call = valid_call
    call[:server_context][:source_snapshot] = 'snapshot-other'
    sql = []
    callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] if payload[:sql]&.include?('events') }

    assert_raises(Scheduling::ContextBuilder::ValidationError) do
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { builder.call(**call) }
    end
    assert_empty sql
  end

  test 'rejects a capped or ordered relation as event_scope' do
    assert_raises(Scheduling::ContextBuilder::ValidationError) do
      Scheduling::ContextBuilder.new(event_scope: Event.order(:id).limit(1))
    end
  end

  test 'same-place travel still applies server and optional self-route buffers to exact boundaries' do
    predecessor = event!(@user, '2026-09-10 08:00:00 UTC', '2026-09-10 08:50:00 UTC')
    call = valid_call(with_travel: true)
    call[:server_context][:user_profile_buffer_minutes] = 10
    canonical = call[:server_context][:canonical_static_travel_context]
    canonical[:place_bindings].each do |binding|
      binding[:resolution] = 'fixed_place'
      binding[:place_ref] = 'same-place'
    end
    canonical[:route_entries] = [{ from_place_ref: 'same-place', to_place_ref: 'same-place',
                                   route_profile_ref: 'walking', travel_minutes: 0,
                                   arrival_buffer_minutes: 15 }]
    reseal!(canonical)

    context = builder.call(**call)
    assert_includes context.boundary_intervals[:predecessors].map { |event| event[:event_id] }, predecessor.id
    assert_includes context.boundary_intervals[:coverage][:exact_instants], Time.utc(2026, 9, 10, 9, 5)
    assert_includes Scheduling::CandidateGenerator.new.call(context: context).map(&:start_at_utc), Time.utc(2026, 9, 10, 9, 5)
  end

  test 'OD-R1-A accepts canonical reverse-only data but production filter fails closed for the missing direction' do
    event!(@user, '2026-09-10 17:00:00 UTC', '2026-09-10 17:50:00 UTC')
    call = valid_call(start_at: '2026-09-11T03:00:00+09:00', end_at: '2026-09-11T05:00:00+09:00', with_travel: true)
    canonical = fixed_canonical!(call)
    canonical[:route_entries].select! { |route| route[:from_place_ref] == 'place-task' }
    reseal!(canonical)

    context = builder.call(**call)
    candidates = Scheduling::CandidateGenerator.new.call(context: context)
    result = Scheduling::ConstraintFilter.new.call(context: context, candidates: candidates)
    assert_empty result.feasible_candidates
    assert_equal :travel_time_unavailable, result.terminal_failure
  end

  test 'OD-R1-M N derives and enforces exact predecessor and successor travel boundaries end to end' do
    predecessor = event!(@user, '2026-09-10 17:00:00 UTC', '2026-09-10 17:50:00 UTC')
    successor = event!(@user, '2026-09-10 19:10:00 UTC', '2026-09-10 20:00:00 UTC')
    call = valid_call(start_at: '2026-09-11T03:00:00+09:00', end_at: '2026-09-11T04:00:00+09:00', with_travel: true)
    canonical = fixed_canonical!(call)
    canonical[:route_entries].each do |route|
      if route[:from_place_ref] == "place-event-#{predecessor.id}" && route[:to_place_ref] == 'place-task'
        route[:travel_minutes] = 25
      elsif route[:from_place_ref] == 'place-task' && route[:to_place_ref] == "place-event-#{successor.id}"
        route[:travel_minutes] = 25
      end
    end
    reseal!(canonical)

    context = builder.call(**call)
    assert_includes context.boundary_intervals[:coverage][:exact_instants], Time.utc(2026, 9, 10, 18, 15)
    assert_equal 1, context.boundary_intervals[:coverage][:exact_instants].count { |instant| instant == Time.utc(2026, 9, 10, 18, 15) }
    generated = Scheduling::CandidateGenerator.new.call(context: context)
    assert_includes generated.map(&:start_at_utc), Time.utc(2026, 9, 10, 18, 15)
    assert_equal 1, generated.count { |candidate| candidate.start_at_utc == Time.utc(2026, 9, 10, 18, 15) },
                 'OD-R1-M/N identical literal boundary is UTC-deduplicated'
    result = Scheduling::ConstraintFilter.new.call(context: context, candidates: generated)
    starts = result.feasible_candidates.map(&:start_at_utc)
    assert_not_includes starts, Time.utc(2026, 9, 10, 18, 0), 'OD-R1-M'
    assert_not_includes starts, Time.utc(2026, 9, 10, 18, 30), 'OD-R1-N'
    assert_includes starts, Time.utc(2026, 9, 10, 18, 15)
  end

  test 'requires canonical context when personal event context exists' do
    event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:30:00 UTC')
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**valid_call) }
  end

  test 'derives fragmentation A0 from working opening blocked and protected lunch intervals' do
    call = valid_call(start_at: '2026-09-10T09:00:00+09:00', end_at: '2026-09-10T18:00:00+09:00')
    call[:server_context] = call[:server_context].merge(
      working_windows: [{ start_at: '2026-09-10T10:00:00+09:00', end_at: '2026-09-10T17:00:00+09:00' }],
      opening_hours_required: true,
      opening_intervals: [{ start_at: '2026-09-10T09:00:00+09:00', end_at: '2026-09-10T16:00:00+09:00' }],
      blocked_windows: [{ start_at: '2026-09-10T11:00:00+09:00', end_at: '2026-09-10T12:00:00+09:00' }],
      protect_lunch: true,
      lunch_window: { start_at: '2026-09-10T13:00:00+09:00', end_at: '2026-09-10T14:00:00+09:00' }
    )
    context = builder.call(**call)
    assert_equal [[1, 2], [3, 4], [5, 7]], context.preference_context[:fragmentation_base_intervals].map { |i| [i[:start_at_utc].hour, i[:end_at_utc].hour] }
  end

  test 'has no row cap and retains window-outside touched-day rows for daily load' do
    outside = event!(@user, '2026-09-10 00:00:00 UTC', '2026-09-10 01:00:00 UTC')
    25.times do |index|
      start_at = Time.utc(2026, 9, 10, 9) + index * 600
      event!(@user, start_at.iso8601, (start_at + 300).iso8601)
    end
    context = builder.call(**valid_call(with_travel: true))
    assert_equal 25, context.busy_intervals.length
    assert_not_includes context.busy_intervals.map { |item| item[:event_id] }, outside.id
    daily = context.preference_context[:daily_load_days].find { |day| day[:local_date] == Date.new(2026, 9, 10) }
    assert_includes daily[:busy_intervals], { start_at_utc: Time.utc(2026, 9, 10, 0), end_at_utc: Time.utc(2026, 9, 10, 1) }
  end

  test 'OD-R1-B rejects an identical duplicate directional route key' do
    event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:30:00 UTC')
    call = valid_call(with_travel: true)
    canonical = fixed_canonical!(call)
    canonical[:route_entries] << canonical[:route_entries].first.dup
    reseal!(canonical)
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/duplicate route key/, error.message)
  end

  test 'OD-R1-C rejects a conflicting duplicate directional route key' do
    event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:30:00 UTC')
    call = valid_call(with_travel: true)
    canonical = fixed_canonical!(call)
    canonical[:route_entries] << canonical[:route_entries].first.merge(travel_minutes: 99)
    reseal!(canonical)
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/duplicate route key/, error.message)
  end

  test 'OD-R1-G rejects tenant binding mismatch independently' do
    call = call_with_one_event
    call[:server_context][:canonical_static_travel_context][:tenant_scope_ref] = 'other-tenant'
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
  end

  test 'OD-R1-G rejects task binding mismatch independently' do
    call = call_with_one_event
    call[:server_context][:canonical_static_travel_context][:task_ref] = 'other-task'
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
  end

  test 'OD-R1-G rejects snapshot binding mismatch independently' do
    call = call_with_one_event
    call[:server_context][:canonical_static_travel_context][:schedule_snapshot_version] = 'other-snapshot'
    assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
  end

  test 'OD-R1-H treats fresh_until as an exclusive upper bound' do
    call = call_with_one_event
    canonical = call[:server_context][:canonical_static_travel_context]
    canonical[:fresh_until] = canonical[:evaluated_at]
    reseal!(canonical)
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/stale/, error.message)
  end

  test 'OD-R1-I accepts a fresh context whose applicable schedule window is future-facing' do
    call = call_with_one_event
    call[:server_context][:invocation_now] = '2026-09-10T17:00:00+09:00'
    canonical = call[:server_context][:canonical_static_travel_context]
    canonical[:evaluated_at] = '2026-09-10T17:00:00+09:00'
    canonical[:resolved_at] = '2026-09-10T16:59:00+09:00'
    canonical[:fresh_until] = '2026-09-10T17:30:00+09:00'
    reseal!(canonical)
    assert_instance_of Scheduling::Context, builder.call(**call)
  end

  test 'OD-R1-O rejects selected route profile mismatch' do
    call = call_with_one_event
    canonical = fixed_canonical!(call)
    canonical[:route_entries].first[:route_profile_ref] = 'driving'
    reseal!(canonical)
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/route profile mismatch/, error.message)
  end

  test 'OD-R1-O rejects an unknown canonical route endpoint' do
    call = call_with_one_event
    canonical = fixed_canonical!(call)
    canonical[:route_entries].first[:to_place_ref] = 'unknown-place'
    reseal!(canonical)
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/unknown route endpoint/, error.message)
  end

  test 'OD-R1-O rejects context digest mismatch' do
    call = call_with_one_event
    call[:server_context][:canonical_static_travel_context][:context_revision] = "ctx_#{'0' * 64}"
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/revision mismatch/, error.message)
  end

  test 'OD-R1-O rejects incomplete applicability coverage' do
    call = call_with_one_event
    canonical = call[:server_context][:canonical_static_travel_context]
    canonical[:applicable_window] = { start_at: '2026-09-10T09:00:01Z', end_at: '2026-09-10T18:00:00Z' }
    reseal!(canonical)
    error = assert_raises(Scheduling::ContextBuilder::ValidationError) { builder.call(**call) }
    assert_match(/applicability incomplete/, error.message)
  end

  test 'OD-R1-AH accepts canonical binding and route input order variants with identical normalization' do
    event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:30:00 UTC')
    event!(@user, '2026-09-10 12:00:00 UTC', '2026-09-10 12:30:00 UTC')
    first_call = valid_call(with_travel: true)
    first = fixed_canonical!(first_call)
    reseal!(first)
    second_call = deep_dup(first_call)
    second = second_call[:server_context][:canonical_static_travel_context]
    second[:place_bindings].reverse!
    second[:route_entries].reverse!
    assert_equal first[:context_revision], second[:context_revision]
    first_context = builder.call(**first_call)
    second_context = builder.call(**second_call)
    assert_equal first_context.travel_context, second_context.travel_context
  end

  test 'OD-R1-AI creator plus participant duplicate contributes once to daily busy union' do
    event = event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:30:00 UTC')
    EventParticipant.create!(event: event, user: @user)
    context = builder.call(**valid_call(with_travel: true))
    assert_equal [event.id], context.busy_intervals.map { |item| item[:event_id] }
    day = context.preference_context[:daily_load_days].find { |item| item[:local_date] == Date.new(2026, 9, 10) }
    assert_equal [{ start_at_utc: Time.utc(2026, 9, 10, 10), end_at_utc: Time.utc(2026, 9, 10, 10, 30) }], day[:busy_intervals]
  end

  def test_uses_actual_dst_day_lengths
    spring = valid_call(zone: 'America/New_York', start_at: '2026-03-08T00:00:00-05:00', end_at: '2026-03-09T00:00:00-04:00')
    fall = valid_call(zone: 'America/New_York', start_at: '2026-11-01T00:00:00-04:00', end_at: '2026-11-02T00:00:00-05:00')
    assert_equal 23.hours, day_seconds(builder.call(**spring))
    assert_equal 25.hours, day_seconds(builder.call(**fall))
  end

  private

  def builder = Scheduling::ContextBuilder.new

  def valid_call(zone: 'Asia/Tokyo', start_at: '2026-09-10T18:00:00+09:00', end_at: '2026-09-11T03:00:00+09:00', with_travel: false)
    travel = with_travel ? canonical_travel(start_at) : nil
    {
      user: @user, search_window: { start_at: start_at, end_at: end_at }, duration_minutes: 30, trusted_time_zone: zone,
      server_context: {
        invocation_now: start_at, authenticated_tenant_scope_ref: 'tenant-1', current_task_ref: 'task-1',
        current_schedule_snapshot_version: 'snapshot-1', global_safety_minimum_minutes: 0,
        user_profile_buffer_minutes: nil, request_scoped_buffer_minutes: nil,
        protect_lunch: false, lunch_window: nil, blocked_windows: [], working_windows: nil,
        opening_hours_required: false, opening_intervals: nil, explicit_exact_start: nil,
        canonical_static_travel_context: travel, profile_preferred_windows: :not_configured,
        request_preferred_windows: [], return_route_preference: false, source_snapshot: 'snapshot-1'
      }
    }
  end


  def canonical_travel(invocation_now)
    events = Event.where(created_by_id: [@user.id, @participant.id]).or(Event.where(id: EventParticipant.where(user_id: @user.id).select(:event_id))).distinct
    bindings = [{ subject_type: 'task', subject_ref: 'task-1', resolution: 'explicitly_no_movement', place_ref: nil }]
    bindings.concat(events.order(:id).map { |event| { subject_type: 'event', subject_ref: event.id.to_s, resolution: 'explicitly_no_movement', place_ref: nil } })
    value = {
      profile_id: 'p1-canonical-static-travel-context-v1', tenant_scope_ref: 'tenant-1', task_ref: 'task-1',
      schedule_snapshot_version: 'snapshot-1', context_revision: nil, selected_route_profile_ref: 'walking',
      evaluated_at: Time.iso8601(invocation_now).iso8601, resolved_at: (Time.iso8601(invocation_now) - 60).iso8601,
      fresh_until: (Time.iso8601(invocation_now) + 3600).iso8601,
      applicable_window: { start_at: '2026-09-01T00:00:00Z', end_at: '2026-09-30T00:00:00Z' },
      place_bindings: bindings, route_entries: []
    }
    value[:place_bindings] = value[:place_bindings].sort_by { |item| [item[:subject_type].b, item[:subject_ref].b] }
    payload = value.reject { |key, _| %i[context_revision evaluated_at].include?(key) }
    value[:context_revision] = "ctx_#{Digest::SHA256.hexdigest(JSON.generate(canonical_sort(payload)))}"
    value
  end

  def canonical_sort(value)
    case value
    when Hash then value.map { |key, item| [key.to_s, canonical_sort(item)] }.sort_by { |key, _| key.b }.to_h
    when Array then value.map { |item| canonical_sort(item) }
    else value
    end
  end

  def call_with_one_event
    event!(@user, '2026-09-10 10:00:00 UTC', '2026-09-10 10:30:00 UTC')
    valid_call(with_travel: true)
  end

  def fixed_canonical!(call)
    canonical = call[:server_context][:canonical_static_travel_context]
    canonical[:place_bindings].each do |binding|
      binding[:resolution] = 'fixed_place'
      binding[:place_ref] = binding[:subject_type] == 'task' ? 'place-task' : "place-event-#{binding[:subject_ref]}"
    end
    event_places = canonical[:place_bindings].filter_map { |binding| binding[:place_ref] if binding[:subject_type] == 'event' }
    canonical[:route_entries] = event_places.flat_map do |place|
      [
        { from_place_ref: place, to_place_ref: 'place-task', route_profile_ref: 'walking', travel_minutes: 5, arrival_buffer_minutes: 0 },
        { from_place_ref: 'place-task', to_place_ref: place, route_profile_ref: 'walking', travel_minutes: 6, arrival_buffer_minutes: 0 }
      ]
    end
    reseal!(canonical)
    canonical
  end

  def reseal!(canonical)
    normalized = deep_dup(canonical)
    normalized[:place_bindings].sort_by! { |item| [item[:subject_type].b, item[:subject_ref].b] }
    normalized[:route_entries].each { |route| route[:arrival_buffer_minutes] = 0 unless route.key?(:arrival_buffer_minutes) }
    normalized[:route_entries].sort_by! { |route| [route[:from_place_ref].b, route[:to_place_ref].b, route[:route_profile_ref].b] }
    payload = normalized.reject { |key, _| %i[context_revision evaluated_at].include?(key) }
    canonical[:context_revision] = "ctx_#{Digest::SHA256.hexdigest(JSON.generate(canonical_sort(payload)))}"
  end

  def deep_dup(value)
    Marshal.load(Marshal.dump(value))
  end

  def event!(owner, start_at, end_at)
    Event.create!(title: 'private', created_by: owner, start_at: Time.parse(start_at), end_at: Time.parse(end_at), color: '#3b82f6')
  end

  def day_seconds(context)
    day = context.preference_context[:daily_load_days].first
    day[:end_at_utc] - day[:start_at_utc]
  end
end
