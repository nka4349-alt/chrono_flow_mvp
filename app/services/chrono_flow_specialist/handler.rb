# frozen_string_literal: true

module ChronoFlowSpecialist
  class Handler
    DEFAULT_HEADERS = { "Content-Type" => "application/json", "Cache-Control" => "no-store" }.freeze

    def initialize(configuration:, request_validator:, jwt_authenticator:, replay_store:, user_resolver:,
                   schedule_reader:, response_builder:, clock: -> { Time.now })
      @configuration = configuration
      @request_validator = request_validator
      @jwt_authenticator = jwt_authenticator
      @replay_store = replay_store
      @user_resolver = user_resolver
      @schedule_reader = schedule_reader
      @response_builder = response_builder
      @clock = clock
    end

    def call(raw_body:, headers:)
      request_id = header(headers, "X-Request-Id")
      trace_id = header(headers, "X-Trace-Id")
      window_now = @clock.call
      request = @request_validator.validate(raw_body: raw_body, headers: headers, now: window_now)
      @configuration.validate!
      authentication = @jwt_authenticator.authenticate(bearer_token(headers))

      case @replay_store.consume_once(digest: authentication.replay_digest, ttl_seconds: 65)
      when :accepted then nil
      when :replayed then raise Errors::Error.new(:replayed_token)
      else raise Errors::Error.new(:service_unavailable)
      end

      user = @user_resolver.resolve(
        identity_issuer: authentication.identity_issuer,
        identity_subject: authentication.identity_subject
      )
      facts = facts_for(request, user, window_now)
      body = @response_builder.success(request: request, facts: facts, now: @clock.call)
      Errors::Result.new(status: 200, body: body, headers: DEFAULT_HEADERS.dup)
    rescue Errors::Error => error
      error_result(error, request_id, trace_id)
    rescue StandardError
      error_result(Errors::Error.new(:internal_error), request_id, trace_id)
    end

    private

    def facts_for(request, user, now)
      case request.fetch("capability")
      when "schedule_context"
        @schedule_reader.call(user: user, request: request, now: now)
      when "connection_verification"
        [@response_builder.connection_fact(user: user, operation: request.dig("constraints", "operation"))]
      else
        raise Errors::Error.new(:unsupported_capability)
      end
    end

    def bearer_token(headers)
      value = header(headers, "Authorization")
      match = /\ABearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/.match(value.to_s)
      raise Errors::Error.new(:invalid_token) unless match

      match[1]
    end

    def error_result(error, request_id, trace_id)
      body = @response_builder.error(code: error.code, request_id: request_id, trace_id: trace_id)
      headers = DEFAULT_HEADERS.dup
      headers["WWW-Authenticate"] = "Bearer" if error.status == 401
      Errors::Result.new(status: error.status, body: body, headers: headers)
    rescue StandardError
      fallback = Errors::Error.new(:internal_error)
      body = {
        "version" => "2.1",
        "error" => { "code" => fallback.code, "message" => fallback.message },
        "request_id" => request_id.to_s.empty? ? "unknown" : request_id.to_s.first(128),
        "trace_id" => trace_id.to_s.empty? ? "unknown" : trace_id.to_s.first(128),
        "retryable" => false
      }
      Errors::Result.new(status: 500, body: body, headers: DEFAULT_HEADERS.dup)
    end

    def header(headers, name)
      headers[name] || headers[name.downcase] || headers[name.upcase.tr("-", "_")] || headers["HTTP_#{name.upcase.tr('-', '_')}"]
    end
  end
end
