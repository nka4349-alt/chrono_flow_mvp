# frozen_string_literal: true

module Api
  module Specialists
    class ChronoFlowController < BaseController
      def context
        render json: ::Specialists::ChronoFlow::ReadScheduleContext.call(
          user: current_user,
          payload: specialist_context_params
        )
      rescue ::Specialists::ChronoFlow::ReadScheduleContext::ValidationError => e
        render_error(e.message, status: :unprocessable_entity, extra: { field: e.field })
      end

      private

      def specialist_context_params
        params.permit(
          :version,
          :request_id,
          :call_id,
          :trace_id,
          :specialist,
          :mode,
          :capability,
          :time_zone
        ).to_h
      end
    end
  end
end
