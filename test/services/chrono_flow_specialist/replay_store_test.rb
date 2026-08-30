# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "test_support"

class ChronoFlowSpecialistReplayStoreTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  FakeClient = Struct.new(:result, :commands, :closed, keyword_init: true) do
    def call(*command)
      commands << command
      raise result if result.is_a?(Exception)

      result
    end

    def close
      self.closed = true
    end
  end

  test "issues one exact SET NX EX 65 command" do
    client = FakeClient.new(result: "OK", commands: [], closed: false)
    store = ChronoFlowSpecialist::ReplayStore.new(
      configuration: test_configuration,
      client_factory: ->(_url) { client }
    )
    digest = "a" * 64

    assert_equal :accepted, store.consume_once(digest: digest, ttl_seconds: 65)
    assert_equal [["SET", digest, "1", "NX", "EX", 65]], client.commands
    assert client.closed
  end

  test "maps existing key and failures without retry" do
    replay_client = FakeClient.new(result: nil, commands: [], closed: false)
    replay = ChronoFlowSpecialist::ReplayStore.new(
      configuration: test_configuration, client_factory: ->(_url) { replay_client }
    )
    failed_client = FakeClient.new(result: IOError.new("secret detail"), commands: [], closed: false)
    failed = ChronoFlowSpecialist::ReplayStore.new(
      configuration: test_configuration, client_factory: ->(_url) { failed_client }
    )

    assert_equal :replayed, replay.consume_once(digest: "b" * 64, ttl_seconds: 65)
    assert_equal :unavailable, failed.consume_once(digest: "c" * 64, ttl_seconds: 65)
    assert_equal 1, failed_client.commands.length
  end

  test "rejects noncanonical digest or TTL before creating a client" do
    calls = 0
    factory = lambda do |_url|
      calls += 1
      raise "must not connect"
    end
    store = ChronoFlowSpecialist::ReplayStore.new(configuration: test_configuration, client_factory: factory)

    assert_equal :unavailable, store.consume_once(digest: "A" * 64, ttl_seconds: 65)
    assert_equal :unavailable, store.consume_once(digest: "a" * 64, ttl_seconds: 64)
    assert_equal 0, calls
  end

  test "client close failure does not overwrite the atomic command result" do
    client = FakeClient.new(result: "OK", commands: [], closed: false)
    client.define_singleton_method(:close) { raise IOError, "close detail" }
    store = ChronoFlowSpecialist::ReplayStore.new(
      configuration: test_configuration,
      client_factory: ->(_url) { client }
    )

    assert_equal :accepted, store.consume_once(digest: "d" * 64, ttl_seconds: 65)
    assert_equal 1, client.commands.length
  end

  test "does not emit replay URL digest raw identity or exception material" do
    replay_url = "rediss://user:credential@replay.example.test/0"
    raw_material = "https://issuer.example.test/\0chrono-flow-specialist\0raw-jti"
    digest = "e" * 64
    client = FakeClient.new(
      result: IOError.new("transport failure #{raw_material}"),
      commands: [],
      closed: false
    )
    configuration = Struct.new(:replay_cache_url).new(replay_url)
    store = ChronoFlowSpecialist::ReplayStore.new(
      configuration: configuration,
      client_factory: ->(_url) { client }
    )

    result, emitted = capture_all_output do
      store.consume_once(digest: digest, ttl_seconds: 65)
    end

    assert_equal :unavailable, result
    assert_equal "", emitted
    [replay_url, digest, raw_material, "raw-jti", "credential", "transport failure"].each do |secret|
      refute_includes emitted, secret
    end
  end

  private

  def capture_all_output
    stdout = StringIO.new
    stderr = StringIO.new
    log = StringIO.new
    previous_stdout = $stdout
    previous_stderr = $stderr
    previous_logger = Rails.logger
    $stdout = stdout
    $stderr = stderr
    Rails.logger = ActiveSupport::Logger.new(log)
    result = yield
    [result, stdout.string + stderr.string + log.string]
  ensure
    Rails.logger = previous_logger
    $stdout = previous_stdout
    $stderr = previous_stderr
  end
end
