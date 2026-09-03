# frozen_string_literal: true

require 'test_helper'

class ApiV1SpecialistsChronoFlowControllerTest < ActionDispatch::IntegrationTest
  ROUTE = '/api/v1/specialists/chrono_flow'
  Result = Struct.new(:status, :body, :headers, keyword_init: true)

  test 'canonical controller is API-only and does not inherit Cookie session authority' do
    controller = Api::V1::Specialists::ChronoFlowController

    assert_operator controller, :<, ActionController::API
    refute_operator controller, :<, ApplicationController
  end

  test 'POST route forwards only canonical headers and raw body to the handler' do
    raw_body = '{"version":"2.1"}'
    dependencies = { dependency_marker: Object.new }
    invocation = {}
    handler = Object.new
    handler.define_singleton_method(:call) do |raw_body:, headers:|
      invocation[:raw_body] = raw_body
      invocation[:headers] = headers
      Result.new(
        status: 200,
        body: { 'accepted' => true },
        headers: { 'Cache-Control' => 'no-store', 'X-Specialist-Test' => 'applied' }
      )
    end
    factory = lambda do |**actual_dependencies|
      invocation[:dependencies] = actual_dependencies
      handler
    end

    with_replaced_singleton_method(ChronoFlowSpecialist::Dependencies, :current, -> { dependencies }) do
      with_replaced_singleton_method(ChronoFlowSpecialist::Handler, :new, factory) do
        post ROUTE,
             params: raw_body,
             headers: canonical_headers.merge('Cookie' => '_chrono_flow_session=not-authority')
      end
    end

    assert_response :success
    assert_equal dependencies, invocation.fetch(:dependencies)
    assert_equal raw_body.b, invocation.fetch(:raw_body)
    assert_equal canonical_headers, invocation.fetch(:headers)
    refute_includes invocation.fetch(:headers), 'Cookie'
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'applied', response.headers['X-Specialist-Test']
    assert_equal({ 'accepted' => true }, JSON.parse(response.body))
  end

  test 'Accept-Encoding is optional and is forwarded as nil when absent' do
    invocation = {}
    result = Result.new(status: 422, body: { 'error' => 'expected' }, headers: { 'Cache-Control' => 'no-store' })
    handler = Object.new
    handler.define_singleton_method(:call) do |raw_body:, headers:|
      invocation[:headers] = headers
      invocation[:raw_body] = raw_body
      result
    end

    with_replaced_singleton_method(ChronoFlowSpecialist::Dependencies, :current, -> { {} }) do
      with_replaced_singleton_method(ChronoFlowSpecialist::Handler, :new, ->(**) { handler }) do
        post ROUTE, params: '{}', headers: canonical_headers.except('Accept-Encoding')
      end
    end

    assert_response :unprocessable_entity
    assert_nil invocation.dig(:headers, 'Accept-Encoding')
    assert_equal '{}'.b, invocation.fetch(:raw_body)
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'dependency security configuration failure stays a canonical no-store 503' do
    failure = -> { raise ChronoFlowSpecialist::Errors::Error.new(:service_unavailable) }

    with_replaced_singleton_method(ChronoFlowSpecialist::Dependencies, :current, failure) do
      post ROUTE, params: '{}', headers: canonical_headers
    end

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal '2.1', body.fetch('version')
    assert_equal 'service_unavailable', body.dig('error', 'code')
    assert_equal 'request-controller-test', body.fetch('request_id')
    assert_equal 'trace-controller-test', body.fetch('trace_id')
    assert_equal true, body.fetch('retryable')
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'unexpected dependency construction failure stays a canonical no-store 500' do
    failure = -> { raise ArgumentError, 'sensitive construction detail' }

    with_replaced_singleton_method(ChronoFlowSpecialist::Dependencies, :current, failure) do
      post ROUTE, params: '{}', headers: canonical_headers
    end

    assert_response :internal_server_error
    body = JSON.parse(response.body)
    assert_equal 'internal_error', body.dig('error', 'code')
    refute_includes response.body, 'sensitive construction detail'
    assert_equal false, body.fetch('retryable')
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  private

  def with_replaced_singleton_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, &replacement)
    yield
  ensure
    target.define_singleton_method(name, &original)
  end

  def canonical_headers
    {
      'Authorization' => 'Bearer compact-token',
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'X-Request-Id' => 'request-controller-test',
      'X-Trace-Id' => 'trace-controller-test',
      'Accept-Encoding' => 'identity'
    }
  end
end
