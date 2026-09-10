# frozen_string_literal: true

module Scheduling
  class Candidate
    FEATURE_KEYS = %i[
      profile_preference request_preference route_efficiency_enabled
      route_efficiency_known route_efficiency total_travel_minutes
      fragmentation daily_load
    ].freeze
    attr_reader :start_at_utc, :end_at_utc, :duration_minutes, :stable_sequence,
                :ranking_features

    def initialize(start_at_utc:, end_at_utc:, duration_minutes:, stable_sequence:, ranking_features: {})
      raise ArgumentError, "start_at_utc must be a Time" unless start_at_utc.is_a?(Time)
      raise ArgumentError, "end_at_utc must be a Time" unless end_at_utc.is_a?(Time)
      raise ArgumentError, "candidate instants must be UTC" unless start_at_utc.utc_offset.zero? && end_at_utc.utc_offset.zero?
      raise ArgumentError, "duration_minutes must be an Integer from 1 through 1440" unless duration_minutes.is_a?(Integer) && duration_minutes.between?(1, 1440)
      raise ArgumentError, "stable_sequence must be a non-negative Integer" unless stable_sequence.is_a?(Integer) && stable_sequence >= 0

      start_utc = start_at_utc.getutc
      end_utc = end_at_utc.getutc
      raise ArgumentError, "candidate must have positive duration" unless start_utc < end_utc
      raise ArgumentError, "candidate duration does not match duration_minutes" unless end_utc.to_r - start_utc.to_r == duration_minutes * 60
      raise ArgumentError, "ranking_features must be a Hash" unless ranking_features.is_a?(Hash)
      validate_ranking_features!(ranking_features) unless ranking_features.empty?

      @start_at_utc = start_utc.freeze
      @end_at_utc = end_utc.freeze
      @duration_minutes = duration_minutes
      @stable_sequence = stable_sequence
      @ranking_features = deep_copy_and_freeze(ranking_features)
      freeze
    end

    def with_ranking_features(features)
      self.class.new(
        start_at_utc: start_at_utc,
        end_at_utc: end_at_utc,
        duration_minutes: duration_minutes,
        stable_sequence: stable_sequence,
        ranking_features: features
      )
    end

    private

    def validate_ranking_features!(features)
      raise ArgumentError, "ranking_features have an invalid shape" unless features.keys.sort == FEATURE_KEYS.sort
      %i[profile_preference request_preference daily_load].each do |key|
        value = features[key]
        raise ArgumentError, "#{key} must be an exact Rational in [0,1]" unless value.is_a?(Rational) && value.between?(0, 1)
      end
      raise ArgumentError, "total_travel_minutes must be a nonnegative Integer" unless features[:total_travel_minutes].is_a?(Integer) && features[:total_travel_minutes] >= 0
      raise ArgumentError, "fragmentation must be an Integer" unless features[:fragmentation].is_a?(Integer)

      enabled = features[:route_efficiency_enabled]
      known = features[:route_efficiency_known]
      value = features[:route_efficiency]
      raise ArgumentError, "route efficiency flags must be Boolean" unless [true, false].include?(enabled) && [true, false].include?(known)
      valid = if !enabled
                !known && value.nil?
              elsif known
                value.is_a?(Rational) && value.between?(0, 1)
              else
                value.nil?
              end
      raise ArgumentError, "route efficiency state is incoherent" unless valid
    end

    def deep_copy_and_freeze(value)
      copy = case value
             when Hash
               value.each_with_object({}) { |(key, item), result| result[deep_copy_and_freeze(key)] = deep_copy_and_freeze(item) }
             when Array
               value.map { |item| deep_copy_and_freeze(item) }
             when String
               value.dup
             when Time
               value.dup
             else
               value
             end
      copy.freeze
    end
  end
end
