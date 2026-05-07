# frozen_string_literal: true

class ProblemReportsController < ApplicationController
  def new
    @problem_report = current_user.problem_reports.new(
      category: 'general',
      priority: 'normal',
      page_url: request.referer
    )
  end

  def create
    @problem_report = current_user.problem_reports.new(problem_report_params)
    @problem_report.category = 'general'
    @problem_report.priority = 'normal'
    @problem_report.page_url = submitted_page_url
    @problem_report.user_agent = request.user_agent.to_s
    @problem_report.metadata = report_metadata
    @problem_report.save!

    respond_to do |format|
      format.json { render json: { ok: true, id: @problem_report.id, message: '問題報告を送信しました。' }, status: :created }
      format.html { redirect_to root_path, notice: '問題報告を送信しました。' }
    end
  rescue ActiveRecord::RecordInvalid => e
    @problem_report = e.record
    respond_to do |format|
      format.json { render json: { ok: false, error: @problem_report.errors.full_messages.join(', ') }, status: :unprocessable_entity }
      format.html do
        flash.now[:alert] = @problem_report.errors.full_messages.join(', ')
        render :new, status: :unprocessable_entity
      end
    end
  end

  def show
    @problem_report = current_user.problem_reports.find(params[:id])
  end

  private

  def problem_report_params
    params.require(:problem_report).permit(:subject, :body)
  end

  def submitted_page_url
    params.dig(:problem_report, :page_url).presence || request.referer || root_url
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
