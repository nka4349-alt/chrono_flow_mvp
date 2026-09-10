# frozen_string_literal: true

require "date"
require "tzinfo"
require_relative "candidate"

module Scheduling
  class CandidateGenerator
    def call(context:)
      raise ArgumentError, "context is required" if context.nil?

      starts = (grid_instants(context) + exact_boundary_instants(context))
        .map(&:getutc)
        .uniq { |instant| instant.to_r }
        .sort_by(&:to_r)

      valid_starts = starts.select do |start_at|
        end_at = Time.at(start_at.to_r + context.duration_minutes * 60).utc
        inside_search_window?(context, start_at, end_at) && full_duration_fit?(context, start_at, end_at)
      end

      valid_starts.map.with_index do |start_at, sequence|
        end_at = Time.at(start_at.to_r + context.duration_minutes * 60).utc
        Candidate.new(
          start_at_utc: start_at,
          end_at_utc: end_at,
          duration_minutes: context.duration_minutes,
          stable_sequence: sequence
        )
      end.freeze
    rescue TZInfo::InvalidTimezoneIdentifier => error
      raise ArgumentError, "invalid trusted time zone: #{error.message}"
    end

    private

    def grid_instants(context)
      zone = TZInfo::Timezone.get(context.trusted_time_zone)
      first_date = zone.utc_to_local(context.window_start_utc.getutc).to_date
      last_date = zone.utc_to_local(context.window_end_utc.getutc).to_date

      (first_date..last_date).flat_map do |date|
        (0...24).flat_map do |hour|
          [0, 15, 30, 45].flat_map do |minute|
            local = Time.utc(date.year, date.month, date.day, hour, minute, 0)
            zone.periods_for_local(local).map do |period|
              Time.at(local.to_r - period.utc_total_offset).utc
            end
          end
        end
      end
    end

    def exact_boundary_instants(context)
      duration = context.duration_minutes * 60
      values = [context.window_start_utc]
      values.concat(blocked_boundaries(context.blocked_windows, duration))
      values.concat(interval_boundaries(context.working_windows, duration))
      values.concat(interval_boundaries(opening_intervals(context), duration))

      boundary = context.boundary_intervals
      values.concat(Array(fetch(fetch(boundary, :coverage), :exact_instants)))

      exact_start = fetch(context.preference_context, :explicit_exact_start)
      values << exact_start if exact_start
      values.select { |value| value.is_a?(Time) }
    end

    def interval_boundaries(intervals, duration)
      Array(intervals).flat_map do |interval|
        start_at = fetch(interval, :start_at_utc)
        end_at = fetch(interval, :end_at_utc)
        [start_at, end_at && Time.at(end_at.to_r - duration).utc].compact
      end
    end

    def blocked_boundaries(intervals, duration)
      Array(intervals).flat_map do |interval|
        start_at = fetch(interval, :start_at_utc)
        end_at = fetch(interval, :end_at_utc)
        [end_at, start_at && Time.at(start_at.to_r - duration).utc].compact
      end
    end

    def opening_intervals(context)
      fetch(context.opening_hours_context, :intervals) || []
    end

    def inside_search_window?(context, start_at, end_at)
      start_at >= context.window_start_utc && end_at <= context.window_end_utc
    end

    def full_duration_fit?(context, start_at, end_at)
      end_at.to_r - start_at.to_r == context.duration_minutes * 60
    end

    def fetch(object, key)
      return nil unless object.respond_to?(:key?)
      return object[key] if object.key?(key)

      object[key.to_s]
    end
  end
end
