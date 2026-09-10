# frozen_string_literal: true

module Scheduling
  class SlotRanker
    FEATURE_KEYS = %i[
      profile_preference
      request_preference
      route_efficiency_enabled
      route_efficiency_known
      route_efficiency
      total_travel_minutes
      fragmentation
      daily_load
    ].freeze

    class InvalidRankingContext < StandardError; end

    def call(context:, candidates:)
      raise InvalidRankingContext, "context is required" if context.nil?
      raise InvalidRankingContext, "candidates must be an Array" unless candidates.is_a?(Array)

      candidates.each { |candidate| validate_candidate!(candidate) }
      candidates.sort_by { |candidate| sort_key(candidate) }.freeze
    end

    private

    def sort_key(candidate)
      features = candidate.ranking_features
      efficiency_missing, efficiency_value = efficiency_key(features)

      [
        -features.fetch(:profile_preference),
        -features.fetch(:request_preference),
        efficiency_missing,
        -efficiency_value,
        features.fetch(:total_travel_minutes),
        features.fetch(:fragmentation),
        features.fetch(:daily_load),
        exact_utc_instant(candidate.start_at_utc),
        candidate.stable_sequence
      ]
    end

    def validate_candidate!(candidate)
      unless defined?(Scheduling::Candidate) && candidate.is_a?(Scheduling::Candidate)
        raise InvalidRankingContext, "candidate has an invalid type"
      end

      features = candidate.ranking_features
      unless features.is_a?(Hash) && features.keys.sort == FEATURE_KEYS.sort
        raise InvalidRankingContext, "ranking features do not have the closed shape"
      end

      validate_ratio!(features.fetch(:profile_preference), :profile_preference)
      validate_ratio!(features.fetch(:request_preference), :request_preference)
      validate_ratio!(features.fetch(:daily_load), :daily_load)
      validate_integer!(features.fetch(:total_travel_minutes), :total_travel_minutes, minimum: 0)
      validate_integer!(features.fetch(:fragmentation), :fragmentation)
      validate_integer!(candidate.stable_sequence, :stable_sequence, minimum: 0)
      exact_utc_instant(candidate.start_at_utc)
      efficiency_key(features)
    end

    def efficiency_key(features)
      enabled = features.fetch(:route_efficiency_enabled)
      known = features.fetch(:route_efficiency_known)
      value = features.fetch(:route_efficiency)
      unless [true, false].include?(enabled) && [true, false].include?(known)
        raise InvalidRankingContext, "route efficiency flags must be Boolean"
      end

      if !enabled
        unless known == false && value.nil?
          raise InvalidRankingContext, "disabled route efficiency must be neutral"
        end
        [0, Rational(0, 1)]
      elsif known
        validate_ratio!(value, :route_efficiency)
        [0, value]
      else
        raise InvalidRankingContext, "unknown route efficiency must be nil" unless value.nil?
        [1, Rational(0, 1)]
      end
    end

    def validate_ratio!(value, name)
      return if value.is_a?(Rational) && value >= 0 && value <= 1

      raise InvalidRankingContext, "#{name} must be an exact Rational in [0,1]"
    end

    def validate_integer!(value, name, minimum: nil)
      valid = value.is_a?(Integer) && (minimum.nil? || value >= minimum)
      raise InvalidRankingContext, "#{name} must be an Integer" unless valid
    end

    def exact_utc_instant(value)
      unless value.is_a?(Time) && value.utc_offset.zero?
        raise InvalidRankingContext, "candidate start must be a UTC Time"
      end
      value.to_r
    end
  end
end
