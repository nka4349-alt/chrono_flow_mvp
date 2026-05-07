# frozen_string_literal: true

module Admin
  class DashboardController < BaseController
    def index
      @range = selected_range
      @since = range_start

      @usage_scope = AiUsageEvent.where(created_at: @since..)
      @usage_counts = @usage_scope.group(:status).count
      @total_usage = @usage_scope.count
      @success_count = @usage_counts['success'].to_i
      @fallback_count = @usage_counts['fallback'].to_i
      @failed_count = @usage_counts['failed'].to_i + @usage_counts['timeout'].to_i
      @avg_latency_ms = @usage_scope.where.not(latency_ms: nil).average(:latency_ms)&.round
      @p95_latency_ms = percentile(@usage_scope.where.not(latency_ms: nil).limit(10_000).pluck(:latency_ms), 0.95)
      @recommendation_count = AiRecommendation.where(created_at: @since..).count
      @feedback_counts = normalize_feedback_counts(AiRecommendationFeedback.where(created_at: @since..).group(:action).count)
      @accept_rate = rate(@feedback_counts['accepted_copy'].to_i, @feedback_counts.values.sum)
      @dismiss_rate = rate(@feedback_counts['dismissed'].to_i, @feedback_counts.values.sum)
      @later_rate = rate(@feedback_counts['later'].to_i, @feedback_counts.values.sum)
      @open_problem_report_count = ProblemReport.where(status: %w[open investigating]).count
      @recent_failures = AiUsageEvent.failures.includes(:user, :group, :ai_policy_run).recent_first.limit(10)
      @recent_problem_reports = ProblemReport.includes(:user).open_recent.limit(10)
      @recent_usage_events = AiUsageEvent.includes(:user, :group, :ai_policy_run).recent_first.limit(10)
    end

    private

    def normalize_feedback_counts(raw_counts)
      raw_counts.each_with_object(Hash.new(0)) do |(action, count), result|
        label = if action.is_a?(Integer)
                  AiRecommendationFeedback.actions.key(action).to_s
                else
                  action.to_s
                end
        result[label] += count.to_i
      end
    end

    def percentile(values, fraction)
      compact_values = values.compact.map(&:to_i).sort
      return nil if compact_values.empty?

      index = [(compact_values.length * fraction).ceil - 1, 0].max
      compact_values[index]
    end

    def rate(numerator, denominator)
      return 0.0 if denominator.to_i <= 0

      ((numerator.to_f / denominator.to_f) * 100).round(1)
    end
  end
end
