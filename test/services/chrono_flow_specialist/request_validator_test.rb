# frozen_string_literal: true

require "test_helper"
require_relative "test_support"

class ChronoFlowSpecialistRequestValidatorTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  setup do
    @validator = ChronoFlowSpecialist::RequestValidator.new(
      contracts: ChronoFlowSpecialist::ContractSchemas.new,
      clock: -> { test_now }
    )
    @token = build_token
  end

  test "accepts exact closed schedule and connection requests" do
    schedule = request_payload

    assert_equal schedule, validate(schedule)
    %w[resolve_user verify_connection].each do |operation|
      connection = request_payload(
        capability: "connection_verification",
        constraints: { "operation" => operation }
      )
      assert_equal connection, validate(connection)
    end
  end

  test "accepts only the computed exact date window" do
    correct = request_payload(
      constraints: { "date_window" => { "start" => "2026-08-30", "end" => "2026-09-13" } }
    )
    wrong = request_payload(
      constraints: { "date_window" => { "start" => "2026-08-30", "end" => "2026-09-14" } }
    )

    assert_equal correct, validate(correct)
    assert_error_code("invalid_request_schema") { validate(wrong) }
  end

  test "duplicate JSON at any depth is malformed JSON" do
    payload = JSON.generate(request_payload)
    duplicate = payload.sub('"constraints":{}', '"constraints":{"nested":{"key":1,"key":2}}')

    assert_error_code("malformed_json") do
      @validator.validate(raw_body: duplicate, headers: request_headers(payload: request_payload, token: @token))
    end
  end

  test "unknown keys context refs and invalid IANA zone are invalid schema" do
    assert_error_code("invalid_request_schema") { validate(request_payload(overrides: { "unknown" => true })) }
    assert_error_code("invalid_request_schema") { validate(request_payload(overrides: { "context_refs" => [{ "user_id" => 1 }] })) }
    assert_error_code("invalid_request_schema") { validate(request_payload(time_zone: "Tokyo")) }
    assert_error_code("invalid_request_schema") { validate(request_payload(overrides: { "time_zone" => 123 })) }
  end

  test "wrong media types and encoding are 415 and oversize is 422" do
    payload = request_payload
    headers = request_headers(payload: payload, token: @token)
    assert_error_code("unsupported_media_type") { validate(payload, headers.merge("Content-Type" => "text/plain")) }
    assert_error_code("unsupported_media_type") { validate(payload, headers.merge("Accept" => "text/html")) }
    assert_error_code("unsupported_media_type") { validate(payload, headers.merge("Accept-Encoding" => "gzip")) }

    huge = " " * (ChronoFlowSpecialist::RequestValidator::MAX_REQUEST_BYTES + 1)
    assert_error_code("invalid_request_schema") { @validator.validate(raw_body: huge, headers: headers) }
  end

  test "missing or malformed Authorization fails before JSON parsing" do
    payload = request_payload
    headers = request_headers(payload: payload, token: @token)

    assert_error_code("invalid_token") do
      @validator.validate(raw_body: "{", headers: headers.merge("Authorization" => nil))
    end
    assert_error_code("invalid_token") do
      @validator.validate(raw_body: "{", headers: headers.merge("Authorization" => "Basic credentials"))
    end
  end

  test "missing correlation headers fail before JSON parsing" do
    payload = request_payload
    headers = request_headers(payload: payload, token: @token)

    %w[X-Request-Id X-Trace-Id].each do |name|
      assert_error_code("invalid_request_schema") do
        @validator.validate(raw_body: "{", headers: headers.merge(name => nil))
      end
    end
  end

  private

  def validate(payload, headers = request_headers(payload: payload, token: @token))
    @validator.validate(raw_body: JSON.generate(payload), headers: headers)
  end

  def assert_error_code(code)
    error = assert_raises(ChronoFlowSpecialist::Errors::Error) { yield }
    assert_equal code, error.code
  end
end
