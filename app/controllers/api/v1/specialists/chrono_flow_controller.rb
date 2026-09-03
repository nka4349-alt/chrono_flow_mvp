# frozen_string_literal: true

module Api
  module V1
    module Specialists
      class ChronoFlowController < ActionController::API
        FORWARDED_HEADERS = %w[
          Authorization
          Content-Type
          Accept
          X-Request-Id
          X-Trace-Id
          Accept-Encoding
        ].freeze

        def create
          dependencies = ::ChronoFlowSpecialist::Dependencies.current
          result = ::ChronoFlowSpecialist::Handler
            .new(**dependencies)
            .call(raw_body: request.raw_post.b, headers: specialist_headers)

          result.headers.each { |name, value| response.set_header(name, value) }
          render json: result.body, status: result.status
        rescue ::ChronoFlowSpecialist::Errors::Error => error
          render_boundary_error(error)
        rescue StandardError
          render_boundary_error(::ChronoFlowSpecialist::Errors::Error.new(:internal_error))
        end

        private

        def specialist_headers
          FORWARDED_HEADERS.to_h { |name| [name, request.headers[name]] }
        end

        def render_boundary_error(error)
          response.set_header('Cache-Control', 'no-store')
          response.set_header('WWW-Authenticate', 'Bearer') if error.status == 401
          render json: {
            'version' => '2.1',
            'error' => { 'code' => error.code, 'message' => error.message },
            'request_id' => safe_correlation_id(request.headers['X-Request-Id']),
            'trace_id' => safe_correlation_id(request.headers['X-Trace-Id']),
            'retryable' => error.retryable
          }, status: error.status
        end

        def safe_correlation_id(value)
          candidate = value.to_s
          candidate.match?(/\A\S.{0,127}\z/m) ? candidate : SecureRandom.uuid
        end
      end
    end
  end
end
