# frozen_string_literal: true

require 'test_helper'
require_relative 'test_support'

class SecretaryMutationConfigurationTest < ActiveSupport::TestCase
  include SecretaryMutationTestSupport

  test 'there is no default HMAC key and an explicit active key is required' do
    missing = mutation_configuration(keys: {}, active_kid: nil)
    inactive = mutation_configuration(keys: { 'retained-k1' => MUTATION_HMAC_KEY }, active_kid: 'missing-k2')
    short = mutation_configuration(keys: { 'short-k1' => 'too-short' }, active_kid: 'short-k1')

    [missing, inactive, short].each do |configuration|
      error = assert_raises(SecretaryMutation::Error) { configuration.validate! }
      assert_equal 'unavailable', error.code
    end
  end
end
