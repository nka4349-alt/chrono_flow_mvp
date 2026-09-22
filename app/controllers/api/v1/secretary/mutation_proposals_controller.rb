# frozen_string_literal: true

module Api
  module V1
    module Secretary
      class MutationProposalsController < ActionController::API
        wrap_parameters false

        PHASES = { 'create' => 'propose', 'confirm' => 'execute', 'cancel' => 'cancel', 'show' => 'status' }.freeze
        UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

        def create = execute
        def confirm = execute
        def cancel = execute
        def show = execute

        private

        def process_action(*)
          request.set_header('action_dispatch.request.formats', [Mime[:json]])
          request.define_singleton_method(:filtered_parameters) { {} }
          super
        end

        def execute
          response.set_header('Cache-Control', 'no-store')
          dependencies = ::SecretaryMutation::Dependencies.current
          raise ::SecretaryMutation::Error.new(:unavailable) unless dependencies.fetch(:enabled)

          phase = PHASES.fetch(action_name)
          raw_body = request.raw_post.to_s.b
          raise ::SecretaryMutation::Error.new(:invalid_request) unless request.query_string.empty?
          raise ::SecretaryMutation::Error.new(:invalid_request) if request.headers['Cookie'].present?
          correlation = validate_headers!(phase)
          payload = parse_payload!(phase, raw_body, correlation)
          proposal_id = request.path_parameters[:proposal_id]
          validate_path!(phase, proposal_id, payload)

          configuration = dependencies.fetch(:configuration).validate!
          token = /\ABearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/
            .match(request.headers['Authorization'].to_s)&.[](1)
          raise ::SecretaryMutation::Error.new(:unauthenticated) unless token

          expected_operation = phase == 'status' ? nil : payload.fetch('operation')
          authentication = ::SecretaryMutation::JwtAuthenticator.new(
            expected_operation: expected_operation, phase: phase, method: request.request_method,
            path: request.path, raw_body: raw_body, request_id: correlation.fetch('request_id'),
            trace_id: correlation.fetch('trace_id'), configuration: configuration.specialist_configuration,
            jwks_provider: dependencies.fetch(:jwks_provider), clock: dependencies.fetch(:clock)
          ).authenticate(token)
          replay = dependencies.fetch(:replay_store).consume_once(
            digest: authentication.replay_digest, ttl_seconds: 65
          )
          raise ::SecretaryMutation::Error.new(replay == :replayed ? :unauthenticated : :unavailable) unless replay == :accepted

          operation = authentication.claims.fetch('mutation_operation')
          result = ::SecretaryMutation::Proposals.new(configuration: configuration,
            clock: dependencies.fetch(:clock)).call(
              phase: phase, request: payload, claims: authentication.claims,
              proposal_id: proposal_id, operation: operation
            )
          status = phase == 'propose' && payload.fetch('proposal_id').nil? ? :created : :ok
          render json: result, status: status
        rescue ::SecretaryMutation::Error => error
          render_error(error)
        rescue ::SecretaryMutation::Contract::Invalid, ::ChronoFlowSpecialist::StrictJson::ParseError
          render_error(::SecretaryMutation::Error.new(:invalid_request))
        rescue ::ChronoFlowSpecialist::Errors::Error => error
          code = error.code == 'service_unavailable' ? :unavailable : :unauthenticated
          render_error(::SecretaryMutation::Error.new(code))
        rescue StandardError
          code = defined?(phase) && phase == 'execute' ? :outcome_unknown : :unavailable
          render_error(::SecretaryMutation::Error.new(code))
        end

        def validate_headers!(phase)
          unless request.headers['Accept'] == 'application/json'
            raise ::SecretaryMutation::Error.new(:unsupported, status: 406)
          end
          if phase != 'status' && request.headers['Content-Type'] != 'application/json'
            raise ::SecretaryMutation::Error.new(:unsupported, status: 415)
          end

          {
            'request_id' => canonical_header_uuid('X-Request-Id'),
            'trace_id' => canonical_header_uuid('X-Trace-Id')
          }
        end

        def parse_payload!(phase, raw_body, correlation)
          if phase == 'status'
            raise ::SecretaryMutation::Error.new(:invalid_request) unless raw_body.empty?
            return correlation
          end

          limit = phase == 'propose' ? 16_384 : 8_192
          value = ::SecretaryMutation::Contract.parse_json!(raw_body, max_bytes: limit)
          case phase
          when 'propose' then ::SecretaryMutation::Contract.validate_propose_request!(value)
          when 'execute' then ::SecretaryMutation::Contract.validate_confirm_request!(value)
          when 'cancel' then ::SecretaryMutation::Contract.validate_cancel_request!(value)
          end
          unless value['request_id'] == correlation['request_id'] && value['trace_id'] == correlation['trace_id']
            raise ::SecretaryMutation::Error.new(:invalid_request)
          end
          ::SecretaryMutation::Contract.operation_allowed_for_provider!('chrono_flow', value.fetch('operation'))
          value
        end

        def validate_path!(phase, proposal_id, payload)
          if proposal_id
            raise ::SecretaryMutation::Error.new(:invalid_request) unless UUID.match?(proposal_id)
            if phase != 'status' && payload.fetch('proposal_id') != proposal_id
              raise ::SecretaryMutation::Error.new(:invalid_request)
            end
          elsif phase != 'propose'
            raise ::SecretaryMutation::Error.new(:invalid_request)
          end
        end

        def canonical_header_uuid(name)
          value = request.headers[name].to_s
          raise ::SecretaryMutation::Error.new(:invalid_request) unless value.ascii_only? && UUID.match?(value)

          value.encode(Encoding::UTF_8, Encoding::US_ASCII)
        rescue EncodingError
          raise ::SecretaryMutation::Error.new(:invalid_request), cause: nil
        end

        def render_error(error)
          response.set_header('Cache-Control', 'no-store')
          response.set_header('WWW-Authenticate', 'Bearer') if error.status == 401
          payload = {
            'version' => 'draft-0.1', 'request_id' => safe_id('X-Request-Id'),
            'trace_id' => safe_id('X-Trace-Id'),
            'error' => { 'code' => error.code, 'message' => error.message, 'retryable' => error.retryable? }
          }
          ::SecretaryMutation::Contract.validate_error_response!(payload)
          render json: payload, status: error.status
        rescue ::SecretaryMutation::Contract::Invalid
          head :internal_server_error
        end

        def safe_id(name)
          canonical_header_uuid(name)
        rescue ::SecretaryMutation::Error
          nil
        end
      end
    end
  end
end
