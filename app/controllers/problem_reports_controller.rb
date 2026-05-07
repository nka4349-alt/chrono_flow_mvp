# frozen_string_literal: true

class ProblemReportsController < ApplicationController
  def new
    @problem_report = current_user.problem_reports.new(
      category: params[:category].presence || 'general',
      priority: 'normal',
      page_url: params[:page_url].presence || request.referer
    )
  end

  def create
    @problem_report = current_user.problem_reports.new(problem_report_params)
    @problem_report.user_agent = request.user_agent.to_s
    normalize_owned_references!(@problem_report)
    @problem_report.metadata = report_metadata
    @problem_report.save!
    redirect_to problem_report_path(@problem_report), notice: '問題報告を送信しました。'
  rescue ActiveRecord::RecordInvalid => e
    @problem_report = e.record
    flash.now[:alert] = @problem_report.errors.full_messages.join(', ')
    render :new, status: :unprocessable_entity
  end

  def show
    @problem_report = current_user.problem_reports.find(params[:id])
  end

  private

  def problem_report_params
    params.require(:problem_report).permit(
      :category,
      :priority,
      :subject,
      :body,
      :page_url,
      :request_id,
      :ai_usage_event_id,
      :ai_recommendation_id
    )
  end

  def normalize_owned_references!(report)
    if report.ai_usage_event_id.present? && !current_user.ai_usage_events.where(id: report.ai_usage_event_id).exists?
      report.ai_usage_event_id = nil
    end

    if report.ai_recommendation_id.present? && !current_user.ai_recommendations.where(id: report.ai_recommendation_id).exists?
      report.ai_recommendation_id = nil
    end
  end

  def report_metadata
    {
      ip: request.remote_ip,
      referer: request.referer,
      user_id: current_user.id,
      user_email: current_user.email
    }
  end
end
