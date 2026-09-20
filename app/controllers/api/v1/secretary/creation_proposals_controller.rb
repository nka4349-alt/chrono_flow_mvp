# frozen_string_literal: true

module Api
  module V1
    module Secretary
      class CreationProposalsController < ActionController::API
        wrap_parameters false
        UUID = ::SecretaryCreation::Contract::UUID
        OPERATIONS = { 'create' => 'propose', 'confirm' => 'create', 'cancel' => 'cancel', 'show' => 'status' }.freeze

        def create = execute
        def confirm = execute
        def cancel = execute
        def show = execute

        private

        def process_action(*)
          # Avoid Rails parsing/logging this sensitive raw JSON before the closed
          # contract boundary (including malformed/duplicate-key requests).
          request.set_header('action_dispatch.request.formats', [Mime[:json]])
          request.define_singleton_method(:filtered_parameters) { {} }
          super
        end

        def execute
          response.set_header('Cache-Control', 'no-store')
          dependencies = ::SecretaryCreation::Dependencies.current
          raise ::SecretaryCreation::Error.new(:unavailable) unless dependencies.fetch(:enabled)
          operation = OPERATIONS.fetch(action_name)
          raw_body = request.raw_post.to_s.b
          raise ::SecretaryCreation::Error.new(:invalid_request) if raw_body.bytesize > 32_768 || !request.query_string.empty?
          correlation_ids = validate_headers!(operation)
          payload = if operation == 'status'
            raise ::SecretaryCreation::Error.new(:invalid_request) unless raw_body.empty? && request.query_string.empty?
            correlation_ids
          else
            # Duplicate detection happens before converting its Hash subclass to
            # the shared contract's exact JSON object type.
            value = ::ChronoFlowSpecialist::StrictJson.parse(raw_body)
            raise ::SecretaryCreation::Error.new(:invalid_request) unless value.is_a?(Hash)
            value = value.to_h
            ::SecretaryCreation::Contract.validate_request!(operation == 'create' ? 'confirm' : operation, value)
            raise ::SecretaryCreation::Error.new(:invalid_request) unless value['request_id'] == correlation_ids['request_id'] && value['trace_id'] == correlation_ids['trace_id']
            value
          end
          proposal_id = request.path_parameters[:proposal_id]
          if proposal_id
            raise ::SecretaryCreation::Error.new(:invalid_request) unless UUID.match?(proposal_id)
            raise ::SecretaryCreation::Error.new(:invalid_request) if operation != 'status' && payload['proposal_id'] != proposal_id
          end
          dependencies.fetch(:configuration).validate!
          token = /\ABearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/.match(request.headers['Authorization'].to_s)&.[](1)
          raise ::SecretaryCreation::Error.new(:unauthenticated) unless token
          authentication = ::SecretaryCreation::JwtAuthenticator.new(
            operation: operation, method: request.request_method, path: request.path, raw_body: raw_body,
            configuration: dependencies.fetch(:configuration), jwks_provider: dependencies.fetch(:jwks_provider), clock: dependencies.fetch(:clock)
          ).authenticate(token)
          replay = dependencies.fetch(:replay_store).consume_once(digest: authentication.replay_digest, ttl_seconds: 71)
          raise ::SecretaryCreation::Error.new(replay == :replayed ? :unauthenticated : :unavailable) unless replay == :accepted
          result = ::SecretaryCreation::Proposals.new(parser: dependencies.fetch(:parser), clock: dependencies.fetch(:clock)).call(
            operation: operation, request: payload, claims: authentication.claims, proposal_id: proposal_id
          )
          render json: result, status: operation == 'propose' && payload['proposal_id'].nil? ? :created : :ok
        rescue ::SecretaryCreation::Error => error
          render_error(error)
        rescue ::ChronoFlowSpecialist::Errors::Error => error
          code = error.code == 'service_unavailable' ? :unavailable : :unauthenticated
          render_error(::SecretaryCreation::Error.new(code))
        rescue ::ChronoFlowSpecialist::StrictJson::ParseError, ::SecretaryCreation::Contract::Invalid
          render_error(::SecretaryCreation::Error.new(:invalid_request))
        rescue StandardError
          render_error(::SecretaryCreation::Error.new(:unavailable))
        end

        def validate_headers!(operation)
          raise ::SecretaryCreation::Error.new(:invalid_request) unless request.headers['Accept'] == 'application/json'
          raise ::SecretaryCreation::Error.new(:invalid_request) if operation != 'status' && request.media_type != 'application/json'

          {
            'request_id' => normalized_correlation_id('X-Request-Id'),
            'trace_id' => normalized_correlation_id('X-Trace-Id')
          }
        end

        def normalized_correlation_id(name)
          value = request.headers[name].to_s
          raise ::SecretaryCreation::Error.new(:invalid_request) unless value.ascii_only? && UUID.match?(value)

          value.encode(Encoding::UTF_8, Encoding::US_ASCII)
        rescue EncodingError
          raise ::SecretaryCreation::Error.new(:invalid_request), cause: nil
        end

        def render_error(error)
          response.set_header('Cache-Control', 'no-store')
          response.set_header('WWW-Authenticate', 'Bearer') if error.status == 401
          render json: {
            'version' => '1.0', 'request_id' => safe_id('X-Request-Id'), 'trace_id' => safe_id('X-Trace-Id'),
            'error' => { 'code' => error.code, 'message' => error.message, 'retryable' => error.retryable? }
          }, status: error.status
        end

        def safe_id(name)
          normalized_correlation_id(name)
        rescue ::SecretaryCreation::Error
          nil
        end
      end
    end
  end
end
