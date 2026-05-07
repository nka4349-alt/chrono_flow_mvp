# frozen_string_literal: true

module Admin
  class AiUsageEventsController < BaseController
    def index
      @range = selected_range
      @since = range_start
      @status = params[:status].to_s.presence
      @events = AiUsageEvent.includes(:user, :group, :ai_policy_run).where(created_at: @since..).recent_first
      @events = @events.where(status: @status) if @status.present?
      @events = @events.limit(150)
    end

    def show
      @event = AiUsageEvent.includes(:user, :group, :ai_conversation, :ai_policy_run).find(params[:id])
      @problem_reports = @event.problem_reports.includes(:user).recent_first.limit(20)
    end
  end
end
