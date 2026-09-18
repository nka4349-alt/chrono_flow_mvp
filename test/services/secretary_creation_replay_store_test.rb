# frozen_string_literal: true

require 'test_helper'
require_relative 'chrono_flow_specialist/test_support'

class SecretaryCreationReplayStoreTest < ActiveSupport::TestCase
  include ChronoFlowSpecialistTestSupport

  test 'atomic replay reservation covers future issuance plus expiration skew' do
    client = Object.new
    calls = []
    client.define_singleton_method(:call) { |*args| calls << args; 'OK' }
    client.define_singleton_method(:close) { nil }
    store = SecretaryCreation::ReplayStore.new(configuration: test_configuration, client_factory: -> (_) { client })
    digest = 'a' * 64
    assert_equal :accepted, store.consume_once(digest: digest, ttl_seconds: 71)
    assert_equal [['SET', digest, '1', 'NX', 'EX', 71]], calls
    assert_equal :unavailable, store.consume_once(digest: digest, ttl_seconds: 65)
    assert_equal 1, calls.length
  end

  test 'unavailable shared replay backend fails closed' do
    store = SecretaryCreation::ReplayStore.new(configuration: test_configuration, client_factory: -> (_) { raise IOError })
    assert_equal :unavailable, store.consume_once(digest: 'a' * 64, ttl_seconds: 71)
  end
end
