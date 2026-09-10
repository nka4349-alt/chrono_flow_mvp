# frozen_string_literal: true

require 'date'
require 'digest'
require 'json'
require 'time'
require 'tzinfo'

module Scheduling
  class ContextBuilder
    class ValidationError < Context::ValidationError; end
    class InvalidTimeWindow < ValidationError; end
    class InvalidDuration < ValidationError; end
    class OpeningHoursUnavailable < ValidationError; end

    SERVER_REQUIRED_KEYS = %i[
      invocation_now authenticated_tenant_scope_ref current_task_ref current_schedule_snapshot_version
      global_safety_minimum_minutes user_profile_buffer_minutes request_scoped_buffer_minutes
      protect_lunch lunch_window blocked_windows working_windows opening_hours_required opening_intervals
      explicit_exact_start canonical_static_travel_context profile_preferred_windows
      request_preferred_windows source_snapshot
    ].freeze
    SERVER_OPTIONAL_KEYS = %i[return_route_preference].freeze
    TRAVEL_KEYS = %i[profile_id tenant_scope_ref task_ref schedule_snapshot_version context_revision
                     selected_route_profile_ref evaluated_at resolved_at fresh_until applicable_window
                     place_bindings route_entries].freeze
    PLACE_KEYS = %i[subject_type subject_ref resolution place_ref].freeze
    ROUTE_REQUIRED_KEYS = %i[from_place_ref to_place_ref route_profile_ref travel_minutes].freeze
    ROUTE_OPTIONAL_KEYS = %i[arrival_buffer_minutes].freeze
    RFC3339 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:[0-5]\d(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/.freeze
    PROJECTION = %i[id start_at end_at all_day parent_id].freeze

    def initialize(event_scope: Event)
      raise ValidationError, 'event_scope must be the Event model' unless event_scope.equal?(Event)

      @event_scope = event_scope.unscoped
    end

    def call(user:, search_window:, duration_minutes:, trusted_time_zone:, server_context:)
      validate_user!(user)
      zone = timezone!(trusted_time_zone)
      window = normalize_hash(search_window, :search_window)
      closed_keys!(window, %i[start_at end_at], :search_window)
      window_start = zoned_instant!(window[:start_at], zone, :start_at)
      window_end = zoned_instant!(window[:end_at], zone, :end_at)
      raise InvalidTimeWindow, 'search window must be increasing' unless window_start < window_end
      raise InvalidDuration, 'duration_minutes must be 1..1440' unless duration_minutes.is_a?(Integer) && (1..1440).cover?(duration_minutes)
      day_bounds = touched_day_bounds!(zone, window_start, window_end)
      server = normalize_hash(server_context, :server_context)
      closed_keys!(server, SERVER_REQUIRED_KEYS, :server_context, optional: SERVER_OPTIONAL_KEYS)
      normalized_server = validate_server!(server, zone, window_start, window_end)

      rows, predecessors, successors = coherent_event_reads(user.id, day_bounds, window_start, window_end)
      rows = normalize_events(rows)
      predecessors = normalize_events(predecessors)
      successors = normalize_events(successors)
      all_events = (rows + predecessors + successors).uniq { |event| event[:event_id] }
      travel = normalize_travel!(normalized_server, all_events, predecessors, successors, window_start, window_end)
      exact_instants = boundary_exact_instants(travel, rows, predecessors, successors, window_start, duration_minutes)

      busy = rows.select { |event| overlap?(event[:start_at_utc], event[:end_at_utc], window_start, window_end) }
      preference = build_preference_context(normalized_server, rows, day_bounds, zone)
      Context.new(
        user_id: user.id, trusted_time_zone: trusted_time_zone,
        window_start_utc: window_start.utc, window_end_utc: window_end.utc,
        duration_minutes: duration_minutes, busy_intervals: busy,
        boundary_intervals: {
          predecessors: predecessors, successors: successors, candidate_events: rows,
          coverage: { overlap_complete: true, predecessor_complete: true, successor_complete: true,
                      exact_instants: exact_instants }
        },
        blocked_windows: normalized_server[:blocked_windows],
        working_windows: normalized_server[:working_windows],
        lunch_policy: { protect: normalized_server[:protect_lunch], interval: normalized_server[:lunch_window] },
        travel_context: travel,
        opening_hours_context: { required: normalized_server[:opening_hours_required], intervals: normalized_server[:opening_intervals] },
        preference_context: preference,
        source_snapshot: normalized_server[:source_snapshot]
      )
    rescue TZInfo::InvalidTimezoneIdentifier, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime => error
      raise InvalidTimeWindow, 'invalid scheduling context'
    rescue ArgumentError => error
      raise error if error.is_a?(ValidationError)
      raise ValidationError, 'invalid scheduling context'
    end

    private

    def validate_user!(user)
      raise ValidationError, 'authenticated persisted user required' unless user.respond_to?(:id) && user.id.is_a?(Integer) && user.persisted?
    end

    def timezone!(name)
      raise InvalidTimeWindow, 'trusted timezone required' unless name.is_a?(String) && !name.empty?
      TZInfo::Timezone.get(name)
    end

    def zoned_instant!(raw, zone, name)
      raise InvalidTimeWindow, "#{name} must use restricted RFC3339" unless raw.is_a?(String) && RFC3339.match?(raw)
      instant = Time.iso8601(raw)
      expected = zone.period_for_utc(instant.getutc).utc_total_offset
      raise InvalidTimeWindow, "#{name} offset does not match trusted timezone" unless instant.utc_offset == expected
      instant.getutc
    rescue ArgumentError
      raise InvalidTimeWindow, "#{name} must use restricted RFC3339"
    end

    def touched_day_bounds!(zone, start_at, end_at)
      first = zone.utc_to_local(start_at).to_date
      local_start = zone.utc_to_local(start_at)
      local_end = zone.utc_to_local(end_at)
      limit_date = local_start.to_date + 14
      limit_tuple = [limit_date.year, limit_date.month, limit_date.day, local_start.hour, local_start.min, local_start.sec, local_start.subsec]
      if (wall_clock_tuple(local_end) <=> limit_tuple) == 1
        raise InvalidTimeWindow, 'search window exceeds fourteen local calendar days'
      end
      exact_midnight = local_end.hour.zero? && local_end.min.zero? && local_end.sec.zero? && local_end.subsec.zero?
      last = exact_midnight ? local_end.to_date.prev_day : local_end.to_date
      dates = (first..last).to_a
      bounds = dates.map do |date|
        start_utc = local_midnight!(zone, date)
        end_utc = local_midnight!(zone, date.next_day)
        { date: date.iso8601, start_at_utc: start_utc, end_at_utc: end_utc }
      end
      { dates: bounds, start_at_utc: bounds.first[:start_at_utc], end_at_utc: bounds.last[:end_at_utc] }
    end

    def local_midnight!(zone, date)
      zone.local_to_utc(Time.new(date.year, date.month, date.day, 0, 0, 0, 0)).utc
    end

    def validate_server!(server, zone, window_start, window_end)
      invocation_now = rfc3339_instant!(server[:invocation_now], :invocation_now)
      %i[authenticated_tenant_scope_ref current_task_ref current_schedule_snapshot_version].each { |key| nonempty!(server[key], key) }
      nonempty!(server[:source_snapshot], :source_snapshot)
      unless server[:current_schedule_snapshot_version] == server[:source_snapshot]
        raise ValidationError, 'current schedule snapshot does not match source snapshot'
      end
      raise ValidationError, 'global safety minimum must be zero' unless server[:global_safety_minimum_minutes] == 0
      %i[user_profile_buffer_minutes request_scoped_buffer_minutes].each { |key| nonnegative_integer_or_nil!(server[key], key) }
      raise ValidationError, 'protect_lunch must be Boolean' unless boolean?(server[:protect_lunch])
      server[:lunch_window] = interval!(server[:lunch_window], zone, :lunch_window, allow_nil: !server[:protect_lunch])
      raise ValidationError, 'lunch interval required when protected' if server[:protect_lunch] && server[:lunch_window].nil?
      server[:blocked_windows] = interval_array!(server[:blocked_windows], zone, :blocked_windows)
      server[:working_windows] = interval_array!(server[:working_windows], zone, :working_windows, allow_nil: true)
      raise ValidationError, 'opening_hours_required must be Boolean' unless boolean?(server[:opening_hours_required])
      if server[:opening_hours_required] && server[:opening_intervals].nil?
        raise OpeningHoursUnavailable, 'opening intervals required'
      end
      server[:opening_intervals] = interval_array!(server[:opening_intervals], zone, :opening_intervals, allow_nil: !server[:opening_hours_required])
      server[:explicit_exact_start] = server[:explicit_exact_start].nil? ? nil : zoned_instant!(server[:explicit_exact_start], zone, :explicit_exact_start)
      server[:profile_preferred_windows] = preference_windows!(server[:profile_preferred_windows], zone, :profile_preferred_windows)
      server[:request_preferred_windows] = preference_windows!(server[:request_preferred_windows], zone, :request_preferred_windows)
      value = server.fetch(:return_route_preference, nil)
      raise ValidationError, 'invalid return_route_preference' unless value.nil? || value == :not_configured || value == 'not_configured' || boolean?(value)
      server[:return_route_preference] = value == true
      server.merge(invocation_now_utc: invocation_now, window_start_utc: window_start, window_end_utc: window_end)
    end

    def coherent_event_reads(user_id, day_bounds, window_start, window_end)
      reader = lambda do
        scope = personal_scope(user_id)
        rows = scope.where('events.start_at < ? AND events.end_at > ?', day_bounds[:end_at_utc], day_bounds[:start_at_utc]).select(*PROJECTION).to_a
        predecessor_max = personal_scope(user_id).where('events.end_at <= ?', window_start).select('MAX(events.end_at)')
        predecessors = personal_scope(user_id).where(end_at: predecessor_max).select(*PROJECTION).to_a
        successor_min = personal_scope(user_id).where('events.start_at >= ?', window_end).select('MIN(events.start_at)')
        successors = personal_scope(user_id).where(start_at: successor_min).select(*PROJECTION).to_a
        [rows, predecessors, successors]
      end
      connection = @event_scope.connection
      if connection.transaction_open?
        isolation = connection.select_value('SHOW transaction_isolation')
        read_only = connection.select_value('SHOW transaction_read_only')
        raise ValidationError, 'existing transaction is not a coherent read-only snapshot' unless isolation == 'repeatable read' && read_only == 'on'
        return reader.call
      end

      connection.transaction(isolation: :repeatable_read, requires_new: true) do
        connection.execute('SET TRANSACTION READ ONLY')
        reader.call
      end
    end

    def personal_scope(user_id)
      table = @event_scope.table_name
      quoted = @event_scope.connection.quote_table_name(table)
      participant = @event_scope.connection.quote_table_name('event_participants')
      @event_scope.where("#{quoted}.created_by_id = :user_id OR EXISTS (SELECT 1 FROM #{participant} ep WHERE ep.event_id = #{quoted}.id AND ep.user_id = :user_id)", user_id: user_id)
    end

    def normalize_events(records)
      records.map do |event|
        start_at = event.start_at&.getutc
        end_at = event.end_at&.getutc
        raise ValidationError, 'selected Event has invalid interval' unless start_at && end_at && start_at < end_at
        { event_id: event.id, start_at_utc: start_at, end_at_utc: end_at,
          all_day: !!event.all_day, parent_id: event.parent_id }
      end.uniq { |event| event[:event_id] }.sort_by { |event| [event[:start_at_utc], event[:end_at_utc], event[:event_id]] }
    end

    def normalize_travel!(server, events, predecessors, successors, window_start, window_end)
      canonical_raw = server[:canonical_static_travel_context]
      required = !canonical_raw.nil?
      if !required && events.any?
        raise ValidationError, 'canonical travel context required when personal event context exists'
      end
      return empty_travel(server) unless required

      canonical = normalize_hash(canonical_raw, :canonical_static_travel_context)
      closed_keys!(canonical, TRAVEL_KEYS, :canonical_static_travel_context)
      raise ValidationError, 'invalid travel profile' unless canonical[:profile_id] == 'p1-canonical-static-travel-context-v1'
      %i[tenant_scope_ref task_ref schedule_snapshot_version selected_route_profile_ref context_revision].each { |key| nonempty!(canonical[key], key) }
      raise ValidationError, 'tenant binding mismatch' unless canonical[:tenant_scope_ref] == server[:authenticated_tenant_scope_ref]
      raise ValidationError, 'task binding mismatch' unless canonical[:task_ref] == server[:current_task_ref]
      raise ValidationError, 'snapshot binding mismatch' unless canonical[:schedule_snapshot_version] == server[:current_schedule_snapshot_version] && canonical[:schedule_snapshot_version] == server[:source_snapshot]
      evaluated = rfc3339_instant!(canonical[:evaluated_at], :evaluated_at)
      resolved = rfc3339_instant!(canonical[:resolved_at], :resolved_at)
      fresh = rfc3339_instant!(canonical[:fresh_until], :fresh_until)
      now = server[:invocation_now_utc]
      raise ValidationError, 'evaluated_at mismatch' unless evaluated == now
      raise ValidationError, 'travel context stale' unless resolved <= now && now < fresh && resolved < fresh

      applicable = canonical_interval!(canonical[:applicable_window], :applicable_window)
      hull_start = ([window_start] + predecessors.map { |event| event[:end_at_utc] }).min
      hull_end = ([window_end] + successors.map { |event| event[:start_at_utc] }).max
      raise ValidationError, 'travel applicability incomplete' unless applicable[:start_at_utc] <= hull_start && applicable[:end_at_utc] >= hull_end

      task_binding, event_bindings, fixed_places = normalize_bindings!(canonical[:place_bindings], server[:current_task_ref], events)
      routes, route_index = normalize_routes!(canonical[:route_entries], canonical[:selected_route_profile_ref], fixed_places)
      normalized_bindings = ([task_binding] + event_bindings.values).sort_by { |item| [item[:subject_type].b, item[:subject_ref].b] }
      normalized = canonical.merge(
        evaluated_at: canonical[:evaluated_at], resolved_at: canonical[:resolved_at], fresh_until: canonical[:fresh_until],
        applicable_window: canonical[:applicable_window], place_bindings: normalized_bindings, route_entries: routes
      )
      expected_revision = "ctx_#{Digest::SHA256.hexdigest(JSON.generate(canonical_sort(normalized.reject { |key, _| %i[context_revision evaluated_at].include?(key) })))}"
      raise ValidationError, 'travel context revision mismatch' unless canonical[:context_revision] == expected_revision
      {
        canonical: normalized, task_ref: server[:current_task_ref], task_binding: task_binding,
        event_bindings: event_bindings, route_index: route_index,
        global_safety_minimum_minutes: server[:global_safety_minimum_minutes],
        user_profile_buffer_minutes: server[:user_profile_buffer_minutes],
        request_scoped_buffer_minutes: server[:request_scoped_buffer_minutes], required: true
      }
    end

    def empty_travel(server)
      { canonical: nil, task_ref: server[:current_task_ref], task_binding: nil, event_bindings: {}, route_index: {},
        global_safety_minimum_minutes: server[:global_safety_minimum_minutes],
        user_profile_buffer_minutes: server[:user_profile_buffer_minutes], request_scoped_buffer_minutes: server[:request_scoped_buffer_minutes], required: false }
    end

    def normalize_bindings!(raw, task_ref, events)
      raise ValidationError, 'place_bindings must be an Array' unless raw.is_a?(Array)
      bindings = raw.map { |item| normalize_hash(item, :place_binding) }
      bindings.each { |item| closed_keys!(item, PLACE_KEYS, :place_binding) }
      identities = bindings.map { |item| [item[:subject_type], item[:subject_ref]] }
      raise ValidationError, 'duplicate place binding' unless identities.uniq.length == identities.length
      bindings.each do |item|
        raise ValidationError, 'invalid binding subject type' unless %w[task event].include?(item[:subject_type])
        nonempty!(item[:subject_ref], :subject_ref)
        raise ValidationError, 'invalid binding resolution' unless %w[fixed_place explicitly_no_movement unresolved].include?(item[:resolution])
        if item[:resolution] == 'fixed_place'
          nonempty!(item[:place_ref], :place_ref)
        elsif !item[:place_ref].nil?
          raise ValidationError, 'non-fixed binding must not have place_ref'
        end
      end
      task = bindings.select { |item| item[:subject_type] == 'task' }
      raise ValidationError, 'exact task binding required' unless task.length == 1 && task.first[:subject_ref] == task_ref
      event_rows = bindings.select { |item| item[:subject_type] == 'event' }
      expected = events.map { |event| event[:event_id].to_s }.sort
      raise ValidationError, 'event binding coverage mismatch' unless event_rows.map { |item| item[:subject_ref] }.sort == expected
      by_id = event_rows.to_h { |item| [Integer(item[:subject_ref], 10), item] }
      fixed = bindings.filter_map { |item| item[:place_ref] if item[:resolution] == 'fixed_place' }.uniq
      [task.first, by_id, fixed]
    rescue ArgumentError
      raise ValidationError, 'event binding reference must be an integer string'
    end

    def normalize_routes!(raw, profile, fixed_places)
      raise ValidationError, 'route_entries must be an Array' unless raw.is_a?(Array)
      routes = raw.map do |item|
        route = normalize_hash(item, :route_entry)
        closed_keys!(route, ROUTE_REQUIRED_KEYS, :route_entry, optional: ROUTE_OPTIONAL_KEYS)
        route[:arrival_buffer_minutes] = 0 unless route.key?(:arrival_buffer_minutes)
        %i[from_place_ref to_place_ref route_profile_ref].each { |key| nonempty!(route[key], key) }
        %i[travel_minutes arrival_buffer_minutes].each { |key| nonnegative_integer!(route[key], key) }
        raise ValidationError, 'route profile mismatch' unless route[:route_profile_ref] == profile
        raise ValidationError, 'unknown route endpoint' unless fixed_places.include?(route[:from_place_ref]) && fixed_places.include?(route[:to_place_ref])
        if route[:travel_minutes].zero? && route[:from_place_ref] != route[:to_place_ref]
          raise ValidationError, 'zero travel requires equal fixed place'
        end
        route
      end
      keys = routes.map { |route| [route[:from_place_ref], route[:to_place_ref], route[:route_profile_ref]] }
      raise ValidationError, 'duplicate route key' unless keys.uniq.length == keys.length
      sorted = routes.sort_by { |route| [route[:from_place_ref].b, route[:to_place_ref].b, route[:route_profile_ref].b] }
      [sorted, sorted.to_h { |route| [[route[:from_place_ref], route[:to_place_ref], route[:route_profile_ref]], route] }]
    end

    def build_preference_context(server, rows, day_bounds, zone)
      day_values = day_bounds[:dates].map do |day|
        clipped = rows.filter_map do |event|
          start_at = [event[:start_at_utc], day[:start_at_utc]].max
          end_at = [event[:end_at_utc], day[:end_at_utc]].min
          { start_at_utc: start_at, end_at_utc: end_at } if start_at < end_at
        end
        union = union_intervals(clipped)
        { local_date: Date.iso8601(day[:date]), start_at_utc: day[:start_at_utc], end_at_utc: day[:end_at_utc],
          busy_intervals: union }
      end
      search_busy = rows.filter_map do |event|
        start_at = [event[:start_at_utc], server[:window_start_utc]].max
        end_at = [event[:end_at_utc], server[:window_end_utc]].min
        { start_at_utc: start_at, end_at_utc: end_at } if start_at < end_at
      end
      allowed = [{ start_at_utc: server[:window_start_utc], end_at_utc: server[:window_end_utc] }]
      allowed = intersect_interval_sets(allowed, server[:working_windows]) unless server[:working_windows].nil?
      allowed = intersect_interval_sets(allowed, server[:opening_intervals]) if server[:opening_hours_required]
      exclusions = search_busy + server[:blocked_windows]
      exclusions << server[:lunch_window] if server[:protect_lunch]
      fragmentation_base = subtract_intervals(allowed, union_intervals(exclusions))
      {
        profile_preferred_windows: server[:profile_preferred_windows],
        request_preferred_windows: server[:request_preferred_windows],
        return_route_preference: server[:return_route_preference],
        fragmentation_base_intervals: fragmentation_base,
        daily_load_days: day_values,
        explicit_exact_start: server[:explicit_exact_start],
        coverage: { fragmentation_complete: true, daily_load_complete: true,
                    touched_local_dates: day_values.map { |day| day[:local_date] } }
      }
    end

    def boundary_exact_instants(travel, candidate_events, predecessors, successors, window_start, duration_minutes)
      instants = [window_start.utc]
      before_events = (candidate_events + predecessors).uniq { |event| event[:event_id] }
      after_events = (candidate_events + successors).uniq { |event| event[:event_id] }
      before_events.group_by { |event| event[:end_at_utc] }.each do |end_at, ties|
        reserve = tied_reserve(travel, ties, before: true)
        instants << (end_at + reserve * 60).utc unless reserve.nil?
      end
      after_events.group_by { |event| event[:start_at_utc] }.each do |start_at, ties|
        reserve = tied_reserve(travel, ties, before: false)
        instants << (start_at - (reserve + duration_minutes) * 60).utc unless reserve.nil?
      end
      instants.uniq.sort
    end

    def tied_reserve(travel, events, before:)
      return 0 unless travel[:required]
      task = travel[:task_binding]
      profile = travel[:canonical][:selected_route_profile_ref]
      values = events.map do |event|
        adjacent = travel[:event_bindings][event[:event_id]]
        from, to = before ? [adjacent, task] : [task, adjacent]
        leg_reserve(travel, from, to, profile)
      end
      return nil if values.any?(&:nil?)
      values.max || 0
    end

    def leg_reserve(travel, from, to, profile)
      return nil unless from && to
      return 0 if [from, to].any? { |binding| binding[:resolution] == 'explicitly_no_movement' }
      return nil unless from[:resolution] == 'fixed_place' && to[:resolution] == 'fixed_place'
      route = travel[:route_index][[from[:place_ref], to[:place_ref], profile]]
      return nil unless from[:place_ref] == to[:place_ref] || route
      buffer = [travel[:global_safety_minimum_minutes], travel[:user_profile_buffer_minutes],
                travel[:request_scoped_buffer_minutes], route&.[](:arrival_buffer_minutes)].compact.max || 0
      (route ? route[:travel_minutes] : 0) + buffer
    end

    def subtract_intervals(free, busy)
      busy.reduce(free) do |parts, cut|
        parts.flat_map do |part|
          next [part] unless overlap?(part[:start_at_utc], part[:end_at_utc], cut[:start_at_utc], cut[:end_at_utc])
          result = []
          result << { start_at_utc: part[:start_at_utc], end_at_utc: cut[:start_at_utc] } if part[:start_at_utc] < cut[:start_at_utc]
          result << { start_at_utc: cut[:end_at_utc], end_at_utc: part[:end_at_utc] } if cut[:end_at_utc] < part[:end_at_utc]
          result
        end
      end
    end

    def intersect_interval_sets(left, right)
      left.product(right).filter_map do |a, b|
        start_at = [a[:start_at_utc], b[:start_at_utc]].max
        end_at = [a[:end_at_utc], b[:end_at_utc]].min
        { start_at_utc: start_at, end_at_utc: end_at } if start_at < end_at
      end.then { |items| union_intervals(items) }
    end

    def preference_windows!(value, zone, name)
      return :not_configured if value == :not_configured || value == 'not_configured'
      union_intervals(interval_array!(value, zone, name))
    end

    def interval_array!(value, zone, name, allow_nil: false)
      return nil if value.nil? && allow_nil
      raise ValidationError, "#{name} must be an Array" unless value.is_a?(Array)
      value.map { |item| interval!(item, zone, name) }
    end

    def interval!(value, zone, name, allow_nil: false)
      return nil if value.nil? && allow_nil
      hash = normalize_hash(value, name)
      closed_keys!(hash, %i[start_at end_at], name)
      start_at = zoned_instant!(hash[:start_at], zone, name)
      end_at = zoned_instant!(hash[:end_at], zone, name)
      raise ValidationError, "#{name} must be increasing" unless start_at < end_at
      { start_at_utc: start_at, end_at_utc: end_at }
    end

    def canonical_interval!(value, name)
      hash = normalize_hash(value, name)
      closed_keys!(hash, %i[start_at end_at], name)
      start_at = rfc3339_instant!(hash[:start_at], name)
      end_at = rfc3339_instant!(hash[:end_at], name)
      raise ValidationError, "#{name} must be increasing" unless start_at < end_at
      { start_at_utc: start_at, end_at_utc: end_at }
    end

    def rfc3339_instant!(value, name)
      raise ValidationError, "#{name} must use restricted RFC3339" unless value.is_a?(String) && RFC3339.match?(value)
      Time.iso8601(value).utc
    rescue ArgumentError
      raise ValidationError, "#{name} must use restricted RFC3339"
    end

    def union_intervals(intervals)
      intervals.sort_by { |item| [item[:start_at_utc], item[:end_at_utc]] }.each_with_object([]) do |item, result|
        if result.empty? || result.last[:end_at_utc] < item[:start_at_utc]
          result << item.dup
        else
          result.last[:end_at_utc] = [result.last[:end_at_utc], item[:end_at_utc]].max
        end
      end
    end

    def canonical_sort(value)
      case value
      when Hash
        value.map { |key, item| [key.to_s, canonical_sort(item)] }.sort_by { |key, _| key.b }.to_h
      when Array
        value.map { |item| canonical_sort(item) }
      else value
      end
    end

    def normalize_hash(value, name)
      raise ValidationError, "#{name} must be a Hash" unless value.is_a?(Hash)
      result = {}
      value.each do |key, item|
        symbol = key.is_a?(String) ? key.to_sym : key
        raise ValidationError, "#{name} has duplicate keys" if result.key?(symbol)
        result[symbol] = item
      end
      result
    end

    def closed_keys!(hash, required, name, optional: [])
      keys = hash.keys
      raise ValidationError, "#{name} has invalid keys" unless (required - keys).empty? && (keys - required - optional).empty?
    end

    def nonempty!(value, name)
      raise ValidationError, "#{name} must be nonempty String" unless value.is_a?(String) && !value.empty?
    end
    def nonnegative_integer!(value, name)
      raise ValidationError, "#{name} must be nonnegative Integer" unless value.is_a?(Integer) && value >= 0
    end

    def nonnegative_integer_or_nil!(value, name)
      nonnegative_integer!(value, name) unless value.nil?
    end
    def boolean?(value) = value == true || value == false
    def overlap?(a_start, a_end, b_start, b_end) = a_start < b_end && a_end > b_start

    def wall_clock_tuple(time)
      [time.year, time.month, time.day, time.hour, time.min, time.sec, time.subsec]
    end
  end
end
