# frozen_string_literal: true

require "test_helper"

class SchedulingSlotRankerTest < ActiveSupport::TestCase
  test "OD-R1-T profile ratio precedes request ratio with literal exact values" do
    profile = candidate(sequence: 1, profile: Rational(1, 2), request: 0)
    request = candidate(sequence: 2, profile: Rational(1, 3), request: 1)

    assert_equal [profile, request], rank(profile, request)
  end

  test "unions are represented by literal full half and zero preference ratios" do
    full = candidate(sequence: 1, profile: Rational(1, 1))
    half = candidate(sequence: 2, profile: Rational(1, 2))
    zero = candidate(sequence: 3, profile: Rational(0, 1))

    assert_equal [full, half, zero], rank(zero, half, full)
  end

  test "OD-R1-V and OD-R1-W higher known efficiency wins and known zero precedes unknown" do
    four_fifths = candidate(sequence: 1, efficiency: Rational(4, 5), travel: 30)
    three_fourths = candidate(sequence: 2, efficiency: Rational(3, 4), travel: 10)
    known_zero = candidate(sequence: 3, efficiency: Rational(0, 1), travel: 0)
    unknown = candidate(sequence: 4, efficiency_known: false, efficiency: nil, travel: 0)

    assert_equal [four_fifths, three_fourths, known_zero, unknown],
                 rank(unknown, known_zero, three_fourths, four_fifths)
  end

  test "OD-R1-X disabled return route feature has identical neutral keys" do
    first = candidate(sequence: 1, efficiency_enabled: false, efficiency_known: false, efficiency: nil, travel: 30)
    second = candidate(sequence: 2, efficiency_enabled: false, efficiency_known: false, efficiency: nil, travel: 10)

    assert_equal [second, first], rank(first, second)
  end

  test "orders total travel fragmentation load start and sequence lexicographically" do
    lower_travel = candidate(sequence: 9, travel: 10, fragmentation: 9, load: Rational(1, 1))
    lower_fragmentation = candidate(sequence: 8, travel: 20, fragmentation: -1, load: Rational(1, 1))
    lower_load = candidate(sequence: 7, travel: 20, fragmentation: 0, load: Rational(1, 23))
    later_load = candidate(sequence: 6, travel: 20, fragmentation: 0, load: Rational(1, 25), start: Time.utc(2026, 9, 7, 11))
    earlier = candidate(sequence: 2, travel: 20, fragmentation: 0, load: Rational(1, 25))
    sequence = candidate(sequence: 3, travel: 20, fragmentation: 0, load: Rational(1, 25))

    assert_equal [lower_travel, lower_fragmentation, earlier, sequence, later_load, lower_load],
                 rank(lower_load, sequence, earlier, later_load, lower_fragmentation, lower_travel)
  end

  test "does not mutate input order and returns a frozen array" do
    later = candidate(sequence: 2, start: Time.utc(2026, 9, 7, 10))
    earlier = candidate(sequence: 1)
    input = [later, earlier]

    result = @ranker.call(context: Object.new.freeze, candidates: input)

    assert_equal [later, earlier], input
    assert_equal [earlier, later], result
    assert_predicate result, :frozen?
  end

  test "OD-R1-AJ unrelated candidate preserves existing feature vectors and relative order" do
    first = candidate(sequence: 1, profile: 1, travel: 30, load: Rational(1, 4))
    second = candidate(sequence: 2, profile: Rational(1, 2), travel: 30, load: Rational(1, 4))
    unrelated = candidate(sequence: 3, profile: 0, travel: 5, start: Time.utc(2026, 9, 7, 12))
    baseline_vectors = [first, second].to_h { |value| [value, value.ranking_features] }

    baseline = rank(first, second)
    with_unrelated = rank(unrelated, second, first)

    assert_equal [first, second], baseline
    assert_equal [first, second], with_unrelated.select { |value| [first, second].include?(value) }
    assert_equal baseline_vectors, [first, second].to_h { |value| [value, value.ranking_features] }
  end

  test "OD-R1-AL exact UTC start then stable sequence closes the total order" do
    earlier = candidate(sequence: 9, start: Time.utc(2026, 9, 7, 9, 59, 59))
    same_start_two = candidate(sequence: 2)
    same_start_one = candidate(sequence: 1)
    later = candidate(sequence: 0, start: Time.utc(2026, 9, 7, 10, 0, 1))

    assert_equal [earlier, same_start_one, same_start_two, later],
                 rank(later, same_start_two, earlier, same_start_one)
  end

  test "rejects missing floats strings and inconsistent route tags" do
    invalid_values = [
      default_features.merge(profile_preference: 0.5),
      default_features.merge(total_travel_minutes: "1"),
      default_features.except(:daily_load),
      default_features.merge(route_efficiency_enabled: false, route_efficiency_known: true, route_efficiency: Rational(1, 1)),
      default_features.merge(route_efficiency_enabled: true, route_efficiency_known: false, route_efficiency: Rational(0, 1))
    ]

    invalid_values.each do |features|
      assert_raises(ArgumentError, Scheduling::SlotRanker::InvalidRankingContext) do
        rank(candidate(sequence: 1, features: features))
      end
    end
  end

  setup do
    @ranker = Scheduling::SlotRanker.new
  end

  private

  def rank(*candidates)
    @ranker.call(context: Object.new.freeze, candidates: candidates)
  end

  def candidate(sequence:, profile: 0, request: 0, efficiency_enabled: true, efficiency_known: true,
                efficiency: Rational(1, 1), travel: 0, fragmentation: 0, load: 0,
                start: Time.utc(2026, 9, 7, 10), features: nil)
    ranking = features || default_features.merge(
      profile_preference: Rational(profile),
      request_preference: Rational(request),
      route_efficiency_enabled: efficiency_enabled,
      route_efficiency_known: efficiency_known,
      route_efficiency: efficiency,
      total_travel_minutes: travel,
      fragmentation: fragmentation,
      daily_load: Rational(load)
    )
    Scheduling::Candidate.new(
      start_at_utc: start,
      end_at_utc: start + 30.minutes,
      duration_minutes: 30,
      stable_sequence: sequence,
      ranking_features: ranking
    )
  end

  def default_features
    {
      profile_preference: Rational(0, 1),
      request_preference: Rational(0, 1),
      route_efficiency_enabled: true,
      route_efficiency_known: true,
      route_efficiency: Rational(1, 1),
      total_travel_minutes: 0,
      fragmentation: 0,
      daily_load: Rational(0, 1)
    }
  end
end
