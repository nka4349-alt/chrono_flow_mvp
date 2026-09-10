# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/services/scheduling/candidate"

class SchedulingCandidateTest < ActiveSupport::TestCase
  test "builds an immutable exact-duration safe candidate" do
    features = {
      profile_preference: Rational(1, 2), request_preference: Rational(0, 1),
      route_efficiency_enabled: false, route_efficiency_known: false, route_efficiency: nil,
      total_travel_minutes: 0, fragmentation: -1, daily_load: Rational(1, 4)
    }
    candidate = Scheduling::Candidate.new(start_at_utc: Time.utc(2026, 9, 10, 9), end_at_utc: Time.utc(2026, 9, 10, 9, 30), duration_minutes: 30, stable_sequence: 0, ranking_features: features)
    features[:profile_preference] = Rational(0, 1)

    assert candidate.frozen?
    assert candidate.ranking_features.frozen?
    assert_equal Rational(1, 2), candidate.ranking_features[:profile_preference]
    assert_equal 1_800, candidate.end_at_utc - candidate.start_at_utc
  end

  test "rejects shortening invalid duration and sequence" do
    base = { start_at_utc: Time.utc(2026, 9, 10, 9), end_at_utc: Time.utc(2026, 9, 10, 9, 29), duration_minutes: 30, stable_sequence: 0 }
    assert_raises(ArgumentError) { Scheduling::Candidate.new(**base) }
    assert_raises(ArgumentError) { Scheduling::Candidate.new(**base.merge(end_at_utc: Time.utc(2026, 9, 10, 9, 30), duration_minutes: 0)) }
    assert_raises(ArgumentError) { Scheduling::Candidate.new(**base.merge(end_at_utc: Time.utc(2026, 9, 10, 9, 30), stable_sequence: -1)) }
  end

  test "rejects inexact Float ranking data" do
    assert_raises(ArgumentError) do
      Scheduling::Candidate.new(
        start_at_utc: Time.utc(2026, 9, 10, 9), end_at_utc: Time.utc(2026, 9, 10, 9, 30),
        duration_minutes: 30, stable_sequence: 0, ranking_features: { score: [0.5] }
      )
    end
  end

  test "rejects non-UTC internal instants instead of rewriting their offsets" do
    start_at = Time.new(2026, 9, 10, 9, 0, 0, "+09:00")
    assert_raises(ArgumentError) do
      Scheduling::Candidate.new(start_at_utc: start_at, end_at_utc: start_at + 1_800, duration_minutes: 30, stable_sequence: 0)
    end
  end


  test "AC-008 accepts exact duration boundaries one and 1440 and rejects 1441" do
    start_at = Time.utc(2026, 9, 10)
    [1, 1_440].each do |minutes|
      candidate = Scheduling::Candidate.new(
        start_at_utc: start_at, end_at_utc: start_at + minutes * 60,
        duration_minutes: minutes, stable_sequence: 0
      )
      assert_equal minutes * 60, candidate.end_at_utc.to_r - candidate.start_at_utc.to_r
    end
    assert_raises(ArgumentError) do
      Scheduling::Candidate.new(start_at_utc: start_at, end_at_utc: start_at + 1_441 * 60, duration_minutes: 1_441, stable_sequence: 0)
    end
  end


  test "P1-AC-026 rejects learned or model score keys outside the approved exact eight features" do
    approved = {
      profile_preference: Rational(1, 2), request_preference: Rational(1, 4),
      route_efficiency_enabled: true, route_efficiency_known: true,
      route_efficiency: Rational(4, 5), total_travel_minutes: 30,
      fragmentation: 0, daily_load: Rational(1, 16)
    }
    candidate = Scheduling::Candidate.new(
      start_at_utc: Time.utc(2026, 9, 10, 9), end_at_utc: Time.utc(2026, 9, 10, 9, 30),
      duration_minutes: 30, stable_sequence: 0, ranking_features: approved
    )
    assert_equal Scheduling::Candidate::FEATURE_KEYS.sort, candidate.ranking_features.keys.sort

    %i[learned_score model_score llm_score].each do |forbidden_key|
      assert_raises(ArgumentError, "P1-AC-026 rejects #{forbidden_key}") do
        Scheduling::Candidate.new(
          start_at_utc: candidate.start_at_utc, end_at_utc: candidate.end_at_utc,
          duration_minutes: 30, stable_sequence: 0,
          ranking_features: approved.merge(forbidden_key => Rational(0, 1))
        )
      end
    end
  end
end
