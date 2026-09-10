# frozen_string_literal: true

module Scheduling
  class RecommendationService
    class InvalidTopK < ArgumentError; end

    Failure = Data.define(:category, :code_hint, :candidate_count) do
      def initialize(category:, code_hint: nil, candidate_count: nil)
        super
        freeze
      end
    end

    Result = Data.define(:status, :candidates, :failure, :bounded_rejection_counts) do
      def initialize(status:, candidates:, failure:, bounded_rejection_counts:)
        copied_candidates = candidates.dup.freeze
        copied_counts = bounded_rejection_counts.each_with_object({}) do |(key, value), result|
          result[key] = value
        end.freeze
        super(status: status, candidates: copied_candidates, failure: failure,
              bounded_rejection_counts: copied_counts)
        freeze
      end

      def feasible?
        status == :feasible
      end

      def error?
        status == :error
      end
    end

    def initialize(context_builder:, candidate_generator:, constraint_filter:, slot_ranker:)
      @context_builder = required_dependency(context_builder, :context_builder)
      @candidate_generator = required_dependency(candidate_generator, :candidate_generator)
      @constraint_filter = required_dependency(constraint_filter, :constraint_filter)
      @slot_ranker = required_dependency(slot_ranker, :slot_ranker)
    end

    def call(user:, search_window:, duration_minutes:, trusted_time_zone:, server_context:, top_k: 3)
      validate_top_k!(top_k)
      context = @context_builder.call(
        user: user,
        search_window: search_window,
        duration_minutes: duration_minutes,
        trusted_time_zone: trusted_time_zone,
        server_context: server_context
      )
      generated = @candidate_generator.call(context: context)
      filtered = @constraint_filter.call(context: context, candidates: generated)
      feasible = filtered.feasible_candidates
      rejection_counts = filtered.bounded_rejection_counts

      if feasible.any?
        ranked = @slot_ranker.call(context: context, candidates: feasible)
        return Result.new(status: :feasible, candidates: ranked.first(top_k), failure: nil,
                          bounded_rejection_counts: rejection_counts)
      end

      terminal = filtered.terminal_failure
      return terminal_result(terminal, rejection_counts) if terminal

      failure_result(:no_feasible_candidate, "NO_FEASIBLE_SLOT", rejection_counts, candidate_count: 0)
    rescue StandardError => error
      failure_from(error)
    end

    private

    def required_dependency(dependency, name)
      raise ArgumentError, "#{name} must respond to call" unless dependency&.respond_to?(:call)
      dependency
    end

    def validate_top_k!(value)
      raise InvalidTopK, "top_k must be an Integer in 1..20" unless value.is_a?(Integer) && (1..20).cover?(value)
    end

    def terminal_result(terminal, rejection_counts)
      category = terminal.respond_to?(:category) ? terminal.category : terminal
      case category&.to_sym
      when :location_required
        failure_result(:location_context_required, "LOCATION_REQUIRED", rejection_counts)
      when :required_travel_unavailable, :travel_time_unavailable
        failure_result(:required_travel_unavailable, "TRAVEL_TIME_UNAVAILABLE", rejection_counts)
      when :no_feasible_slot, :no_feasible_candidate
        failure_result(:no_feasible_candidate, "NO_FEASIBLE_SLOT", rejection_counts, candidate_count: 0)
      else
        failure_result(:context_failure, nil, rejection_counts)
      end
    end

    def failure_from(error)
      if error.is_a?(InvalidTopK)
        failure_result(:invalid_request, nil, {})
      elsif typed_error?(error, "Scheduling::ContextBuilder::LocationRequired")
        failure_result(:location_context_required, "LOCATION_REQUIRED", {})
      elsif typed_error?(error, "Scheduling::ContextBuilder::TravelTimeUnavailable")
        failure_result(:required_travel_unavailable, "TRAVEL_TIME_UNAVAILABLE", {})
      elsif typed_error?(error, "Scheduling::ContextBuilder::OpeningHoursUnavailable")
        failure_result(:opening_hours_unavailable, "OPENING_HOURS_UNAVAILABLE", {})
      elsif typed_error?(error, "Scheduling::ContextBuilder::InvalidDuration")
        failure_result(:invalid_duration, "INVALID_DURATION", {})
      elsif typed_error?(error, "Scheduling::ContextBuilder::InvalidTimeWindow")
        failure_result(:invalid_request, "INVALID_TIME_WINDOW", {})
      elsif scheduling_context_failure?(error)
        failure_result(:context_failure, nil, {})
      else
        failure_result(:unexpected_internal_failure, nil, {})
      end
    end

    def typed_error?(error, class_name)
      error.class.ancestors.any? { |ancestor| ancestor.respond_to?(:name) && ancestor.name == class_name }
    end

    def scheduling_context_failure?(error)
      typed_error?(error, "Scheduling::Context::ValidationError") ||
        typed_error?(error, "Scheduling::ContextBuilder::ValidationError") ||
        typed_error?(error, "Scheduling::ConstraintFilter::IncompleteRankingContext") ||
        typed_error?(error, "Scheduling::SlotRanker::InvalidRankingContext")
    end

    def failure_result(category, code_hint, rejection_counts, candidate_count: nil)
      Result.new(
        status: :error,
        candidates: [],
        failure: Failure.new(category: category, code_hint: code_hint, candidate_count: candidate_count),
        bounded_rejection_counts: rejection_counts
      )
    end
  end
end
