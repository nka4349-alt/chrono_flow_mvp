# frozen_string_literal: true

module Admin
  class BaseController < ApplicationController
    before_action :require_admin!

    private

    def require_admin!
      return if current_user&.admin?

      forbid!
    end

    def range_start
      case params[:range].to_s
      when '24h' then 24.hours.ago
      when '30d' then 30.days.ago
      when '90d' then 90.days.ago
      else 7.days.ago
      end
    end

    def selected_range
      %w[24h 7d 30d 90d].include?(params[:range].to_s) ? params[:range].to_s : '7d'
    end
  end
end
