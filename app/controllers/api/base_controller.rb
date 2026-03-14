# frozen_string_literal: true

module Api
  class BaseController < ApplicationController
    before_action :require_login!

    private

    # Backward compatible helper (existing controllers call render_error)
    def render_error(message, status: :unprocessable_entity, extra: {})
      render json: { error: message }.merge(extra), status: status
    end

    # Newer helper name (some patches used json_error)
    def json_error(message, status: :unprocessable_entity, extra: {})
      render_error(message, status: status, extra: extra)
    end

    def parse_time(param)
      return nil if param.blank?
      Time.zone.parse(param.to_s)
    rescue StandardError
      nil
    end
  end
end
