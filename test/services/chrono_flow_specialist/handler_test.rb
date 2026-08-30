# frozen_string_literal: true

require "test_helper"
require_relative "test_support"

class ChronoFlowSpecialistHandlerTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  Authentication = Struct.new(:identity_issuer, :identity_subject, :replay_digest, keyword_init: true)
  User = Struct.new(:id, keyword_init: true)

  class Configuration
    def initialize(log)
      @log = log
    end

    def validate!
      @log << :configuration
      self
    end
  end

  class RequestValidator
    def initialize(log, request, expected_now)
      @log = log
      @request = request
      @expected_now = expected_now
    end

    def validate(raw_body:, headers:, now:)
      @log << :request
      raise "raw body was not forwarded" unless raw_body == "serialized request"
      raise "headers were not forwarded" unless headers.is_a?(Hash)
      raise "request clock was not frozen" unless now == @expected_now

      @request
    end
  end

  class Authenticator
    def initialize(log, authentication)
      @log = log
      @authentication = authentication
    end

    def authenticate(token)
      @log << :authentication
      raise "bearer token was not extracted" unless token == "a.b.c"

      @authentication
    end
  end

  class ReplayStore
    def initialize(log, result)
      @log = log
      @result = result
    end

    def consume_once(digest:, ttl_seconds:)
      @log << :replay
      raise "wrong replay digest" unless digest == "a" * 64
      raise "wrong replay TTL" unless ttl_seconds == 65

      @result
    end
  end

  class UserResolver
    def initialize(log, user)
      @log = log
      @user = user
    end

    def resolve(identity_issuer:, identity_subject:)
      @log << :user
      raise "identity issuer changed" unless identity_issuer == "https://identity.example.test/"
      raise "identity subject changed" unless identity_subject == "provider|one"

      @user
    end
  end

  class ScheduleReader
    def initialize(log, facts, expected_now)
      @log = log
      @facts = facts
      @expected_now = expected_now
    end

    def call(user:, request:, now:)
      @log << :domain
      raise "resolved user was not forwarded" unless user.id == 7
      raise "request was not forwarded" unless request["capability"] == "schedule_context"
      raise "clock was not forwarded" unless now == @expected_now

      @facts
    end
  end

  class ResponseBuilder
    def initialize(log)
      @log = log
    end

    def success(request:, facts:, now:)
      @log << :response
      { "request_id" => request.fetch("request_id"), "facts" => facts, "generated_at" => now.iso8601 }
    end

    def error(code:, request_id:, trace_id:)
      @log << :error_response
      {
        "version" => "2.1",
        "error" => { "code" => code.to_s, "message" => "safe" },
        "request_id" => request_id.to_s,
        "trace_id" => trace_id.to_s,
        "retryable" => code.to_s == "service_unavailable"
      }
    end
  end

  setup do
    @log = []
    @request = request_payload
    @headers = request_headers(payload: @request, token: "a.b.c")
    @authentication = Authentication.new(
      identity_issuer: "https://identity.example.test/",
      identity_subject: "provider|one",
      replay_digest: "a" * 64
    )
    @user = User.new(id: 7)
  end

  test "orchestrates validation auth replay user domain and response in exact order" do
    result = build_handler(replay_result: :accepted).call(raw_body: "serialized request", headers: @headers)

    assert_equal 200, result.status
    assert_equal %i[request configuration authentication replay user domain response], @log
    assert_equal "no-store", result.headers["Cache-Control"]
    assert_equal "schedule_event", result.body.fetch("facts").first.fetch("fact_type")
    assert_equal 2, @clock_calls
    assert_equal (test_now + 1.day).iso8601, result.body.fetch("generated_at")
  end

  test "replay is fail closed before user resolution or domain access" do
    result = build_handler(replay_result: :replayed).call(raw_body: "serialized request", headers: @headers)

    assert_equal 401, result.status
    assert_equal "replayed_token", result.body.dig("error", "code")
    assert_equal %i[request configuration authentication replay error_response], @log
    assert_equal "Bearer", result.headers["WWW-Authenticate"]
  end

  test "replay unavailability is 503 before user resolution or domain access" do
    result = build_handler(replay_result: :unavailable).call(raw_body: "serialized request", headers: @headers)

    assert_equal 503, result.status
    assert_equal "service_unavailable", result.body.dig("error", "code")
    assert_equal %i[request configuration authentication replay error_response], @log
  end

  test "missing or malformed bearer is 401 after request validation" do
    @headers.delete("Authorization")
    result = build_handler(replay_result: :accepted).call(raw_body: "serialized request", headers: @headers)

    assert_equal 401, result.status
    assert_equal "invalid_token", result.body.dig("error", "code")
    assert_equal %i[request configuration error_response], @log
    assert_equal "Bearer", result.headers["WWW-Authenticate"]
  end

  private

  def build_handler(replay_result:)
    facts = [{ "id" => "cf_one", "fact_type" => "schedule_event", "fields" => {}, "source_updated_at" => "2026-08-30T12:00:00+09:00" }]
    @clock_calls = 0
    clock = lambda do
      @clock_calls += 1
      test_now + (@clock_calls - 1).days
    end
    ChronoFlowSpecialist::Handler.new(
      configuration: Configuration.new(@log),
      request_validator: RequestValidator.new(@log, @request, test_now),
      jwt_authenticator: Authenticator.new(@log, @authentication),
      replay_store: ReplayStore.new(@log, replay_result),
      user_resolver: UserResolver.new(@log, @user),
      schedule_reader: ScheduleReader.new(@log, facts, test_now),
      response_builder: ResponseBuilder.new(@log),
      clock: clock
    )
  end
end
