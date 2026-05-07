# frozen_string_literal: true

module Admin
  class ProblemReportsController < BaseController
    def index
      @status = params[:status].to_s.presence
      @reports = ProblemReport.includes(:user, :ai_usage_event, :ai_recommendation).recent_first
      @reports = @reports.where(status: @status) if @status.present?
      @reports = @reports.limit(150)
    end

    def show
      @report = ProblemReport.includes(:user, :ai_usage_event, :ai_recommendation).find(params[:id])
    end

    def update
      @report = ProblemReport.find(params[:id])
      attrs = problem_report_params
      attrs[:resolved_at] = Time.current if attrs[:status].in?(%w[resolved closed]) && @report.resolved_at.blank?
      attrs[:resolved_at] = nil if attrs[:status].present? && !attrs[:status].in?(%w[resolved closed])
      @report.update!(attrs)
      redirect_to admin_problem_report_path(@report), notice: '問題報告を更新しました。'
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_problem_report_path(@report), alert: e.record.errors.full_messages.join(', ')
    end

    private

    def problem_report_params
      params.require(:problem_report).permit(:status, :priority, :category, :admin_notes)
    end
  end
end
