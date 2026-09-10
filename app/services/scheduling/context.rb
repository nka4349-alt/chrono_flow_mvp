# frozen_string_literal: true

require 'date'
require 'digest'
require 'json'
require 'time'
require 'tzinfo'

module Scheduling
  class Context
    class ValidationError < ArgumentError; end

    ATTRIBUTES = %i[user_id trusted_time_zone window_start_utc window_end_utc duration_minutes
                    busy_intervals boundary_intervals blocked_windows working_windows lunch_policy
                    travel_context opening_hours_context preference_context source_snapshot].freeze
    EVENT_KEYS = %i[event_id start_at_utc end_at_utc all_day parent_id].freeze
    BOUNDARY_KEYS = %i[predecessors successors candidate_events coverage].freeze
    INTERVAL_KEYS = %i[start_at_utc end_at_utc].freeze
    BOUNDARY_COVERAGE_KEYS = %i[overlap_complete predecessor_complete successor_complete exact_instants].freeze
    TRAVEL_KEYS = %i[canonical task_ref task_binding event_bindings route_index global_safety_minimum_minutes
                     user_profile_buffer_minutes request_scoped_buffer_minutes required].freeze
    PREFERENCE_KEYS = %i[profile_preferred_windows request_preferred_windows return_route_preference
                         fragmentation_base_intervals daily_load_days explicit_exact_start coverage].freeze
    PREFERENCE_COVERAGE_KEYS = %i[fragmentation_complete daily_load_complete touched_local_dates].freeze
    CANONICAL_KEYS = %i[profile_id tenant_scope_ref task_ref schedule_snapshot_version context_revision
                        selected_route_profile_ref evaluated_at resolved_at fresh_until applicable_window
                        place_bindings route_entries].freeze
    CANONICAL_INTERVAL_KEYS = %i[start_at end_at].freeze
    CANONICAL_ROUTE_KEYS = %i[from_place_ref to_place_ref route_profile_ref travel_minutes arrival_buffer_minutes].freeze
    RFC3339 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/.freeze

    attr_reader(*ATTRIBUTES)

    def initialize(user_id:, trusted_time_zone:, window_start_utc:, window_end_utc:, duration_minutes:,
                   busy_intervals:, boundary_intervals:, blocked_windows:, working_windows:, lunch_policy:,
                   travel_context:, opening_hours_context:, preference_context:, source_snapshot: nil)
      raise ValidationError, 'user_id must be an Integer' unless user_id.is_a?(Integer)
      raise ValidationError, 'trusted_time_zone must be nonempty' unless nonempty_string?(trusted_time_zone)
      begin
        TZInfo::Timezone.get(trusted_time_zone)
      rescue TZInfo::InvalidTimezoneIdentifier
        raise ValidationError, 'trusted_time_zone must be a valid IANA identifier'
      end
      validate_time!(window_start_utc, :window_start_utc)
      validate_time!(window_end_utc, :window_end_utc)
      raise ValidationError, 'window must be increasing' unless window_start_utc < window_end_utc
      raise ValidationError, 'duration_minutes must be 1..1440' unless duration_minutes.is_a?(Integer) && (1..1440).cover?(duration_minutes)
      validate_event_array!(busy_intervals, :busy_intervals)
      validate_boundary!(boundary_intervals)
      validate_interval_array!(blocked_windows, :blocked_windows)
      validate_interval_array!(working_windows, :working_windows) unless working_windows.nil?
      validate_closed_hash!(lunch_policy, %i[protect interval], :lunch_policy)
      raise ValidationError, 'lunch protect must be Boolean' unless boolean?(lunch_policy[:protect])
      if lunch_policy[:protect]
        validate_interval!(lunch_policy[:interval], :lunch_interval)
      elsif !lunch_policy[:interval].nil?
        raise ValidationError, 'lunch interval must be nil when protection is disabled'
      end
      validate_closed_hash!(opening_hours_context, %i[required intervals], :opening_hours_context)
      raise ValidationError, 'opening required must be Boolean' unless boolean?(opening_hours_context[:required])
      if opening_hours_context[:intervals].nil?
        raise ValidationError, 'required opening intervals are missing' if opening_hours_context[:required]
      else
        validate_interval_array!(opening_hours_context[:intervals], :opening_intervals)
      end
      raise ValidationError, 'travel_context must be a Hash' unless travel_context.is_a?(Hash)
      raise ValidationError, 'preference_context must be a Hash' unless preference_context.is_a?(Hash)
      validate_travel!(travel_context, busy_intervals, boundary_intervals, window_start_utc, window_end_utc, source_snapshot)
      validate_preference!(preference_context)
      unless source_snapshot.nil? || nonempty_string?(source_snapshot)
        raise ValidationError, 'source_snapshot must be nil or nonempty String'
      end

      values = ATTRIBUTES.to_h { |name| [name, binding.local_variable_get(name)] }
      values.each { |name, value| instance_variable_set("@#{name}", deep_copy_freeze(value)) }
      freeze
    end

    private

    def validate_boundary!(value)
      validate_closed_hash!(value, BOUNDARY_KEYS, :boundary_intervals)
      %i[predecessors successors candidate_events].each { |key| validate_event_array!(value[key], key) }
      validate_closed_hash!(value[:coverage], BOUNDARY_COVERAGE_KEYS, :boundary_coverage)
      %i[overlap_complete predecessor_complete successor_complete].each do |key|
        raise ValidationError, "#{key} must be true" unless value[:coverage][key] == true
      end
      exact = value[:coverage][:exact_instants]
      raise ValidationError, 'exact_instants must be an Array' unless exact.is_a?(Array)
      exact.each { |instant| validate_time!(instant, :exact_instant) }
      raise ValidationError, 'exact_instants must be unique UTC times' unless exact.all?(&:utc?) && exact.uniq.length == exact.length
    end

    def validate_travel!(value, busy, boundary, window_start, window_end, source_snapshot)
      validate_closed_hash!(value, TRAVEL_KEYS, :travel_context)
      raise ValidationError, 'travel required must be Boolean' unless boolean?(value[:required])
      raise ValidationError, 'event_bindings must be keyed by Integer' unless value[:event_bindings].is_a?(Hash) && value[:event_bindings].keys.all? { |key| key.is_a?(Integer) }
      raise ValidationError, 'route_index must be a Hash' unless value[:route_index].is_a?(Hash)
      if value[:required]
        raise ValidationError, 'required canonical travel is incomplete' unless value[:canonical].is_a?(Hash) && value[:task_binding].is_a?(Hash)
      elsif !value[:canonical].nil? || !value[:task_binding].nil? || !value[:event_bindings].empty? || !value[:route_index].empty?
        raise ValidationError, 'non-required travel must be empty'
      end
      value[:event_bindings].each_value { |binding| validate_binding!(binding) }
      validate_binding!(value[:task_binding]) if value[:task_binding]
      value[:route_index].each do |key, route|
        raise ValidationError, 'invalid directional route key' unless key.is_a?(Array) && key.length == 3 && key.all? { |part| nonempty_string?(part) }
        raise ValidationError, 'invalid route value' unless route.is_a?(Hash) && route[:travel_minutes].is_a?(Integer) && route[:travel_minutes] >= 0 && route[:arrival_buffer_minutes].is_a?(Integer) && route[:arrival_buffer_minutes] >= 0
      end
      %i[global_safety_minimum_minutes user_profile_buffer_minutes request_scoped_buffer_minutes].each do |key|
        item = value[key]
        raise ValidationError, "#{key} must be nil or nonnegative Integer" unless item.nil? || (item.is_a?(Integer) && item >= 0)
      end
      raise ValidationError, 'global safety minimum must be zero' unless value[:global_safety_minimum_minutes] == 0
      validate_canonical_travel!(value, busy, boundary, window_start, window_end, source_snapshot) if value[:required]
    end

    def validate_canonical_travel!(travel, busy, boundary, window_start, window_end, source_snapshot)
      canonical = travel[:canonical]
      validate_closed_hash!(canonical, CANONICAL_KEYS, :canonical_travel)
      raise ValidationError, 'invalid canonical profile' unless canonical[:profile_id] == 'p1-canonical-static-travel-context-v1'
      %i[tenant_scope_ref task_ref schedule_snapshot_version context_revision selected_route_profile_ref].each do |key|
        raise ValidationError, "invalid canonical #{key}" unless nonempty_string?(canonical[key])
      end
      raise ValidationError, 'canonical task mismatch' unless canonical[:task_ref] == travel[:task_ref]
      raise ValidationError, 'canonical snapshot mismatch' unless canonical[:schedule_snapshot_version] == source_snapshot

      evaluated = canonical_time!(canonical[:evaluated_at], :evaluated_at)
      resolved = canonical_time!(canonical[:resolved_at], :resolved_at)
      fresh = canonical_time!(canonical[:fresh_until], :fresh_until)
      raise ValidationError, 'canonical freshness is invalid' unless resolved <= evaluated && evaluated < fresh
      applicable = canonical[:applicable_window]
      validate_closed_hash!(applicable, CANONICAL_INTERVAL_KEYS, :applicable_window)
      applicable_start = canonical_time!(applicable[:start_at], :applicable_start)
      applicable_end = canonical_time!(applicable[:end_at], :applicable_end)
      events = (busy + %i[predecessors successors candidate_events].flat_map { |key| boundary[key] })
        .uniq { |event| event[:event_id] }
      hull_start = ([window_start] + boundary[:predecessors].map { |event| event[:end_at_utc] }).min
      hull_end = ([window_end] + boundary[:successors].map { |event| event[:start_at_utc] }).max
      raise ValidationError, 'canonical applicability is incomplete' unless applicable_start <= hull_start && applicable_end >= hull_end

      bindings = canonical[:place_bindings]
      raise ValidationError, 'canonical place_bindings must be an Array' unless bindings.is_a?(Array)
      unless travel[:task_binding][:subject_type] == 'task' && travel[:task_binding][:subject_ref] == travel[:task_ref]
        raise ValidationError, 'canonical task binding mismatch'
      end
      travel[:event_bindings].each do |event_id, binding|
        unless binding[:subject_type] == 'event' && binding[:subject_ref] == event_id.to_s
          raise ValidationError, 'canonical event binding mismatch'
        end
      end
      normalized_bindings = ([travel[:task_binding]] + travel[:event_bindings].values).sort_by { |item| [item[:subject_type].b, item[:subject_ref].b] }
      raise ValidationError, 'canonical bindings are not normalized' unless bindings == normalized_bindings
      expected_ids = events.map { |event| event[:event_id] }.sort
      raise ValidationError, 'travel event binding coverage mismatch' unless travel[:event_bindings].keys.sort == expected_ids

      routes = canonical[:route_entries]
      raise ValidationError, 'canonical route_entries must be an Array' unless routes.is_a?(Array)
      fixed_places = bindings.filter_map { |binding| binding[:place_ref] if binding[:resolution] == 'fixed_place' }.uniq
      routes.each do |route|
        validate_closed_hash!(route, CANONICAL_ROUTE_KEYS, :canonical_route)
        key = [route[:from_place_ref], route[:to_place_ref], route[:route_profile_ref]]
        raise ValidationError, 'canonical route profile mismatch' unless route[:route_profile_ref] == canonical[:selected_route_profile_ref]
        unless fixed_places.include?(route[:from_place_ref]) && fixed_places.include?(route[:to_place_ref])
          raise ValidationError, 'canonical route endpoint is unknown'
        end
        raise ValidationError, 'canonical route index mismatch' unless travel[:route_index][key] == route
        unless route[:travel_minutes].is_a?(Integer) && route[:travel_minutes] >= 0 &&
               route[:arrival_buffer_minutes].is_a?(Integer) && route[:arrival_buffer_minutes] >= 0
          raise ValidationError, 'canonical route numeric value is invalid'
        end
        raise ValidationError, 'zero travel requires equal endpoint' if route[:travel_minutes].zero? && route[:from_place_ref] != route[:to_place_ref]
      end
      expected_routes = travel[:route_index].sort_by { |key, _| key }.map(&:last)
      raise ValidationError, 'canonical routes are not normalized' unless routes == expected_routes
      payload = canonical.reject { |key, _| %i[context_revision evaluated_at].include?(key) }
      revision = "ctx_#{Digest::SHA256.hexdigest(JSON.generate(canonical_sort(payload)))}"
      raise ValidationError, 'canonical revision mismatch' unless canonical[:context_revision] == revision
    end

    def canonical_time!(value, name)
      raise ValidationError, "#{name} must use restricted RFC3339" unless value.is_a?(String) && RFC3339.match?(value)
      Time.iso8601(value).utc
    rescue ArgumentError
      raise ValidationError, "#{name} must use restricted RFC3339"
    end

    def canonical_sort(value)
      case value
      when Hash then value.map { |key, item| [key.to_s, canonical_sort(item)] }.sort_by { |key, _| key.b }.to_h
      when Array then value.map { |item| canonical_sort(item) }
      else value
      end
    end

    def validate_preference!(value)
      validate_closed_hash!(value, PREFERENCE_KEYS, :preference_context)
      %i[profile_preferred_windows request_preferred_windows].each do |key|
        item = value[key]
        validate_interval_array!(item, key) unless item == :not_configured
      end
      raise ValidationError, 'return_route_preference must be Boolean' unless boolean?(value[:return_route_preference])
      validate_interval_array!(value[:fragmentation_base_intervals], :fragmentation_base_intervals)
      raise ValidationError, 'daily_load_days must be an Array' unless value[:daily_load_days].is_a?(Array)
      value[:daily_load_days].each do |day|
        validate_closed_hash!(day, %i[local_date start_at_utc end_at_utc busy_intervals], :daily_load_day)
        raise ValidationError, 'local_date must be a Date' unless day[:local_date].is_a?(Date)
        validate_time!(day[:start_at_utc], :day_start)
        validate_time!(day[:end_at_utc], :day_end)
        raise ValidationError, 'day interval must be increasing' unless day[:start_at_utc] < day[:end_at_utc]
        validate_interval_array!(day[:busy_intervals], :day_busy_intervals)
      end
      unless value[:explicit_exact_start].nil?
        validate_time!(value[:explicit_exact_start], :explicit_exact_start)
      end
      validate_closed_hash!(value[:coverage], PREFERENCE_COVERAGE_KEYS, :preference_coverage)
      %i[fragmentation_complete daily_load_complete].each do |key|
        raise ValidationError, "#{key} must be true" unless value[:coverage][key] == true
      end
      dates = value[:coverage][:touched_local_dates]
      raise ValidationError, 'touched_local_dates must be Dates' unless dates.is_a?(Array) && dates.all? { |date| date.is_a?(Date) }
    end

    def validate_binding!(binding)
      raise ValidationError, 'invalid place binding' unless binding.is_a?(Hash) && binding.keys.sort == %i[place_ref resolution subject_ref subject_type].sort
      raise ValidationError, 'invalid binding subject' unless %w[event task].include?(binding[:subject_type]) && nonempty_string?(binding[:subject_ref])
      raise ValidationError, 'invalid binding resolution' unless %w[fixed_place explicitly_no_movement unresolved].include?(binding[:resolution])
      fixed = binding[:resolution] == 'fixed_place'
      raise ValidationError, 'invalid binding place_ref' unless fixed ? nonempty_string?(binding[:place_ref]) : binding[:place_ref].nil?
    end

    def validate_event_array!(values, name)
      raise ValidationError, "#{name} must be an Array" unless values.is_a?(Array)
      values.each do |event|
        validate_closed_hash!(event, EVENT_KEYS, name)
        raise ValidationError, 'event_id must be an Integer' unless event[:event_id].is_a?(Integer)
        raise ValidationError, 'all_day must be Boolean' unless boolean?(event[:all_day])
        unless event[:parent_id].nil? || event[:parent_id].is_a?(Integer)
          raise ValidationError, 'parent_id must be nil or Integer'
        end
        validate_time!(event[:start_at_utc], :start_at_utc)
        validate_time!(event[:end_at_utc], :end_at_utc)
        raise ValidationError, 'event interval must be increasing' unless event[:start_at_utc] < event[:end_at_utc]
      end
      raise ValidationError, "#{name} contains duplicate event_id" unless values.map { |v| v[:event_id] }.uniq.length == values.length
    end

    def validate_interval_array!(values, name)
      raise ValidationError, "#{name} must be an Array" unless values.is_a?(Array)
      values.each { |value| validate_interval!(value, name) }
    end

    def validate_interval!(value, name)
      validate_closed_hash!(value, INTERVAL_KEYS, name)
      validate_time!(value[:start_at_utc], :start_at_utc)
      validate_time!(value[:end_at_utc], :end_at_utc)
      raise ValidationError, "#{name} must be increasing" unless value[:start_at_utc] < value[:end_at_utc]
    end

    def validate_closed_hash!(value, keys, name)
      raise ValidationError, "#{name} must be a Hash" unless value.is_a?(Hash)
      actual = value.keys
      raise ValidationError, "#{name} has invalid keys" unless (keys - actual).empty? && (actual - keys).empty?
    end

    def validate_time!(value, name)
      raise ValidationError, "#{name} must be a Time" unless value.is_a?(Time)
      raise ValidationError, "#{name} must be UTC" unless value.utc?
    end

    def nonempty_string?(value) = value.is_a?(String) && !value.empty?
    def boolean?(value) = value == true || value == false

    def deep_copy_freeze(value)
      copy = case value
             when Hash then value.each_with_object({}) { |(key, item), out| out[deep_copy_freeze(key)] = deep_copy_freeze(item) }
             when Array then value.map { |item| deep_copy_freeze(item) }
             when String then value.dup
             when Time then value.dup
             when Date then value.dup
             else value
             end
      copy.freeze
    end
  end
end
