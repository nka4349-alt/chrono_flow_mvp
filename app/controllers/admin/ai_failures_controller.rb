# frozen_string_literal: true

module Admin
  class AiFailuresController < BaseController
    def index
      @range = selected_range
      @since = range_start
      @events = AiUsageEvent.failures.includes(:user, :group, :ai_policy_run).where(created_at: @since..).recent_first.limit(200)
    end
  end
end
