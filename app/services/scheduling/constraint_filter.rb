# frozen_string_literal: true

require "date"
require "tzinfo"

module Scheduling
  class ConstraintFilter
    class IncompleteRankingContext < StandardError; end
    Result = Struct.new(:feasible_candidates, :bounded_rejection_counts, :terminal_failure, keyword_init: true) do
      def initialize(feasible_candidates:, bounded_rejection_counts:, terminal_failure: nil)
        super(
          feasible_candidates: feasible_candidates.dup.freeze,
          bounded_rejection_counts: bounded_rejection_counts.dup.freeze,
          terminal_failure: terminal_failure
        )
        freeze
      end
    end

    REJECTION_KEYS = %i[duration window busy blocked working lunch opening travel].freeze

    def call(context:, candidates:)
      raise ArgumentError, "context is required" if context.nil?
      raise ArgumentError, "candidates must be an Array" unless candidates.is_a?(Array)

      counts = REJECTION_KEYS.to_h { |key| [key, 0] }
      feasible = []
      unresolved_travel_survivors = 0
      unresolved_location_survivors = 0

      candidates.each do |candidate|
        reason = rejection_reason(context, candidate)
        if reason
          count_key = %i[travel_unknown location_unknown].include?(reason) ? :travel : reason
          counts[count_key] += 1
          unresolved_travel_survivors += 1 if reason == :travel_unknown && otherwise_feasible?(context, candidate)
          unresolved_location_survivors += 1 if reason == :location_unknown && otherwise_feasible?(context, candidate)
        else
          feasible << attach_ranking_features(context, candidate)
        end
      end

      terminal = if feasible.empty? && unresolved_location_survivors.positive?
                   :location_required
                 elsif feasible.empty? && unresolved_travel_survivors.positive?
                   :travel_time_unavailable
                 end
      Result.new(feasible_candidates: feasible, bounded_rejection_counts: counts, terminal_failure: terminal)
    end

    private

    def rejection_reason(context, candidate)
      return :duration unless valid_duration?(context, candidate)
      return :window unless contained?(candidate, context.window_start_utc, context.window_end_utc)
      return :busy if overlaps_any?(candidate, context.busy_intervals)
      return :blocked if overlaps_any?(candidate, context.blocked_windows)
      return :working unless context.working_windows.nil? || inside_any?(candidate, context.working_windows)
      return :lunch if protected_lunch_overlap?(context, candidate)
      return :opening unless opening_feasible?(context, candidate)
      travel = travel_evaluation(context, candidate)
      return :location_unknown if travel == :location_unknown
      return :travel_unknown if travel == :unknown
      return :travel if travel == :infeasible

      nil
    end

    def otherwise_feasible?(context, candidate)
      rejection_reason_without_travel(context, candidate).nil?
    end

    def rejection_reason_without_travel(context, candidate)
      return :duration unless valid_duration?(context, candidate)
      return :window unless contained?(candidate, context.window_start_utc, context.window_end_utc)
      return :busy if overlaps_any?(candidate, context.busy_intervals)
      return :blocked if overlaps_any?(candidate, context.blocked_windows)
      return :working unless context.working_windows.nil? || inside_any?(candidate, context.working_windows)
      return :lunch if protected_lunch_overlap?(context, candidate)
      return :opening unless opening_feasible?(context, candidate)
    end

    def valid_duration?(context, candidate)
      candidate.duration_minutes == context.duration_minutes &&
        candidate.end_at_utc.to_r - candidate.start_at_utc.to_r == context.duration_minutes * 60
    end

    def overlaps_any?(candidate, intervals)
      Array(intervals).any? { |interval| candidate.start_at_utc < fetch(interval, :end_at_utc) && candidate.end_at_utc > fetch(interval, :start_at_utc) }
    end

    def inside_any?(candidate, intervals)
      Array(intervals).any? { |interval| contained?(candidate, fetch(interval, :start_at_utc), fetch(interval, :end_at_utc)) }
    end

    def contained?(candidate, start_at, end_at)
      candidate.start_at_utc >= start_at && candidate.end_at_utc <= end_at
    end

    def protected_lunch_overlap?(context, candidate)
      policy = context.lunch_policy
      fetch(policy, :protect) == true && overlaps_any?(candidate, [fetch(policy, :interval)])
    end

    def opening_feasible?(context, candidate)
      opening = context.opening_hours_context
      required = fetch(opening, :required)
      intervals = fetch(opening, :intervals)
      return true unless required
      raise ArgumentError, "required opening hours are unavailable" if intervals.nil?

      inside_any?(candidate, intervals)
    end

    def travel_evaluation(context, candidate)
      travel = context.travel_context
      return :feasible unless fetch(travel, :required)

      outcomes = neighbors_for(context, candidate, :predecessors).map do |event|
        required_leg_outcome(travel, event, :before, candidate)
      end
      outcomes.concat(neighbors_for(context, candidate, :successors).map do |event|
        required_leg_outcome(travel, event, :after, candidate)
      end)

      return :infeasible if outcomes.include?(:infeasible)
      return :location_unknown if outcomes.include?(:location_unknown)
      return :unknown if outcomes.include?(:route_unknown)

      :feasible
    end

    def required_leg_outcome(travel, event, direction, candidate)
      return :location_unknown unless resolved_subjects?(travel, event)

      leg = resolve_leg(travel, event, direction)
      return :route_unknown unless leg

      feasible = if direction == :before
                   candidate.start_at_utc >= fetch(event, :end_at_utc) + leg[:reserve_minutes] * 60
                 else
                   candidate.end_at_utc + leg[:reserve_minutes] * 60 <= fetch(event, :start_at_utc)
                 end
      feasible ? :feasible : :infeasible
    end

    def resolved_subjects?(travel, event)
      [event_binding(travel, fetch(event, :event_id)), fetch(travel, :task_binding)].all? do |binding|
        fixed_place?(binding) || no_movement?(binding)
      end
    end

    def neighbors_for(context, candidate, direction)
      events = Array(fetch(context.boundary_intervals, direction)) + Array(fetch(context.boundary_intervals, :candidate_events))
      events = events.uniq { |event| fetch(event, :event_id) }
      eligible = if direction == :predecessors
                   events.select { |event| fetch(event, :end_at_utc) <= candidate.start_at_utc }
                 else
                   events.select { |event| fetch(event, :start_at_utc) >= candidate.end_at_utc }
                 end
      return [] if eligible.empty?

      edge = direction == :predecessors ? eligible.map { |event| fetch(event, :end_at_utc) }.max : eligible.map { |event| fetch(event, :start_at_utc) }.min
      eligible.select { |event| fetch(event, direction == :predecessors ? :end_at_utc : :start_at_utc) == edge }
    end

    def resolve_leg(travel, event, direction)
      binding = event_binding(travel, fetch(event, :event_id))
      task_binding = fetch(travel, :task_binding)
      return { travel_minutes: 0, reserve_minutes: 0 } if no_movement?(binding) || no_movement?(task_binding)
      return nil unless fixed_place?(binding) && fixed_place?(task_binding)

      from = direction == :before ? place_ref(binding) : place_ref(task_binding)
      to = direction == :before ? place_ref(task_binding) : place_ref(binding)
      minutes = if from == to
                  0
                else
                  route_minutes(travel, from, to)
                end
      return nil unless minutes.is_a?(Integer) && minutes >= 0

      buffer = [
        fetch(travel, :global_safety_minimum_minutes),
        fetch(travel, :user_profile_buffer_minutes),
        fetch(travel, :request_scoped_buffer_minutes),
        route_buffer(travel, from, to)
      ].compact.max || 0
      { travel_minutes: minutes, reserve_minutes: minutes + buffer }
    end

    def attach_ranking_features(context, candidate)
      validate_preference_coverage!(context, candidate)
      before = neighbors_for(context, candidate, :predecessors).filter_map { |event| resolve_leg(context.travel_context, event, :before) }
      after = neighbors_for(context, candidate, :successors).filter_map { |event| resolve_leg(context.travel_context, event, :after) }
      t_before = before.empty? ? 0 : before.map { |leg| leg[:travel_minutes] }.max
      t_after = after.empty? ? 0 : after.map { |leg| leg[:travel_minutes] }.max
      r_before = before.empty? ? 0 : before.map { |leg| leg[:reserve_minutes] }.max
      r_after = after.empty? ? 0 : after.map { |leg| leg[:reserve_minutes] }.max
      route = route_efficiency_features(context, candidate)
      preferences = context.preference_context
      features = {
        profile_preference: preferred_ratio(candidate, fetch(preferences, :profile_preferred_windows)),
        request_preference: preferred_ratio(candidate, fetch(preferences, :request_preferred_windows)),
        route_efficiency_enabled: route[:enabled],
        route_efficiency_known: route[:known],
        route_efficiency: route[:value],
        total_travel_minutes: t_before + t_after,
        fragmentation: fragmentation_delta(candidate, fetch(preferences, :fragmentation_base_intervals), r_before, r_after),
        daily_load: daily_load(candidate, fetch(preferences, :daily_load_days))
      }
      candidate.with_ranking_features(features)
    end

    def preferred_ratio(candidate, intervals)
      return Rational(0, 1) if intervals.nil? || intervals == :not_configured || intervals == "not_configured"

      covered = intersection_length(candidate, union_intervals(intervals))
      covered / (candidate.end_at_utc.to_r - candidate.start_at_utc.to_r)
    end

    def route_efficiency_features(context, candidate)
      enabled = fetch(context.preference_context, :return_route_preference) == true
      return { enabled: false, known: false, value: nil } unless enabled
      return { enabled: true, known: false, value: nil } if no_movement?(fetch(context.travel_context, :task_binding))

      predecessors = neighbors_for(context, candidate, :predecessors)
      successors = neighbors_for(context, candidate, :successors)
      return { enabled: true, known: false, value: nil } if predecessors.empty? || successors.empty?

      values = predecessors.product(successors).map do |previous, following|
        before = resolve_leg(context.travel_context, previous, :before)
        after = resolve_leg(context.travel_context, following, :after)
        return { enabled: true, known: false, value: nil } unless before && after

        previous_binding = event_binding(context.travel_context, fetch(previous, :event_id))
        following_binding = event_binding(context.travel_context, fetch(following, :event_id))
        return { enabled: true, known: false, value: nil } unless fixed_place?(previous_binding) && fixed_place?(following_binding)

        previous_place = place_ref(previous_binding)
        following_place = place_ref(following_binding)
        direct = previous_place == following_place ? 0 : route_minutes(context.travel_context, previous_place, following_place)
        return { enabled: true, known: false, value: nil } unless direct.is_a?(Integer) && direct >= 0

        via = before[:travel_minutes] + after[:travel_minutes]
        if via.zero?
          refs = [place_ref(previous_binding), place_ref(fetch(context.travel_context, :task_binding)), place_ref(following_binding)]
          unless refs.uniq.one? && direct.zero?
            raise IncompleteRankingContext, "zero-via route efficiency lacks same-place proof"
          end
          Rational(1, 1)
        else
          [Rational(direct, via), Rational(1, 1)].min
        end
      end
      { enabled: true, known: true, value: values.min }
    end

    def fragmentation_delta(candidate, base_intervals, r_before, r_after)
      base = union_intervals(base_intervals || [])
      reservation = [candidate.start_at_utc.to_r - r_before * 60, candidate.end_at_utc.to_r + r_after * 60]
      after = base.flat_map do |start_at, end_at|
        next [[start_at, end_at]] if reservation[1] <= start_at || reservation[0] >= end_at

        [[start_at, [reservation[0], end_at].min], [[reservation[1], start_at].max, end_at]].select { |left, right| left < right }
      end
      short_component_count(after) - short_component_count(base)
    end

    def daily_load(candidate, days)
      duration = candidate.end_at_utc.to_r - candidate.start_at_utc.to_r
      Array(days).sum(Rational(0, 1)) do |day|
        day_start = fetch(day, :start_at_utc).to_r
        day_end = fetch(day, :end_at_utc).to_r
        overlap = [[candidate.end_at_utc.to_r, day_end].min - [candidate.start_at_utc.to_r, day_start].max, 0].max
        next Rational(0, 1) if overlap.zero?

        load = fetch(day, :load)
        load ||= Rational(union_intervals(fetch(day, :busy_intervals) || []).sum { |left, right| right - left }, day_end - day_start)
        Rational(overlap, duration) * load
      end
    end

    def union_intervals(intervals)
      values = Array(intervals).map { |interval| [fetch(interval, :start_at_utc).to_r, fetch(interval, :end_at_utc).to_r] }.sort
      values.each_with_object([]) do |(left, right), union|
        if union.empty? || left > union.last[1]
          union << [left, right]
        else
          union.last[1] = [union.last[1], right].max
        end
      end
    end

    def intersection_length(candidate, intervals)
      intervals.sum { |left, right| [[candidate.end_at_utc.to_r, right].min - [candidate.start_at_utc.to_r, left].max, 0].max }
    end

    def validate_preference_coverage!(context, candidate)
      preferences = context.preference_context
      coverage = fetch(preferences, :coverage)
      unless fetch(coverage, :fragmentation_complete) == true && fetch(coverage, :daily_load_complete) == true
        raise IncompleteRankingContext, "ranking coverage is incomplete"
      end

      touched_dates = Array(fetch(coverage, :touched_local_dates))
      days = Array(fetch(preferences, :daily_load_days))
      covered_dates = days.map { |day| fetch(day, :local_date) }
      zone = TZInfo::Timezone.get(context.trusted_time_zone)
      first = zone.utc_to_local(candidate.start_at_utc).to_date
      local_end = zone.utc_to_local(candidate.end_at_utc)
      last = local_end.to_date
      last = last.prev_day if local_end.hour.zero? && local_end.min.zero? && local_end.sec.zero? && local_end.subsec.zero?
      required_dates = (first..last).to_a
      unless (required_dates - touched_dates).empty? && (required_dates - covered_dates).empty?
        raise IncompleteRankingContext, "daily load coverage is incomplete"
      end
    end

    def short_component_count(intervals)
      intervals.count { |left, right| (right - left).positive? && right - left < 1_800 }
    end

    def event_binding(travel, event_id)
      bindings = fetch(travel, :event_bindings)
      return bindings[event_id] || bindings[event_id.to_s] if bindings.is_a?(Hash)

      Array(bindings).find { |binding| fetch(binding, :subject_ref).to_s == event_id.to_s }
    end

    def route_entry(travel, from, to)
      index = fetch(travel, :route_index)
      profile = fetch(fetch(travel, :canonical), :selected_route_profile_ref)
      return index[[from, to, profile]] || index[[from, to]] || index["#{from}\u0000#{to}\u0000#{profile}"] if index.is_a?(Hash)

      Array(index).find do |entry|
        fetch(entry, :from_place_ref) == from && fetch(entry, :to_place_ref) == to &&
          (profile.nil? || fetch(entry, :route_profile_ref) == profile)
      end
    end

    def route_minutes(travel, from, to)
      fetch(route_entry(travel, from, to), :travel_minutes)
    end

    def route_buffer(travel, from, to)
      fetch(route_entry(travel, from, to), :arrival_buffer_minutes) || 0
    end

    def fixed_place?(binding)
      fetch(binding, :resolution).to_s == "fixed_place" && !place_ref(binding).to_s.empty?
    end

    def no_movement?(binding)
      fetch(binding, :resolution).to_s == "explicitly_no_movement"
    end

    def place_ref(binding)
      fetch(binding, :place_ref)
    end

    def fetch(object, key)
      return nil unless object.respond_to?(:key?)
      return object[key] if object.key?(key)

      object[key.to_s]
    end
  end
end
