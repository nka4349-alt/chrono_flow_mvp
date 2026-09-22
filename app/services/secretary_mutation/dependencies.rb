# frozen_string_literal: true

require 'secretary_mutation/contract'

module SecretaryMutation
  module Dependencies
    TEST_KEY = :secretary_mutation_test_dependencies
    module_function

    def current
      return Thread.current[TEST_KEY] if Rails.env.test? && Thread.current[TEST_KEY]

      configuration = Configuration.new
      {
        enabled: ENV['SECRETARY_MUTATION_ENABLED'] == 'true',
        configuration: configuration,
        jwks_provider: ChronoFlowSpecialist::JwksProvider.new(configuration: configuration.specialist_configuration),
        replay_store: ReplayStore.new(configuration: configuration.specialist_configuration),
        clock: -> { Time.current }
      }
    end

    def with_test(dependencies)
      raise 'test-only dependency injection' unless Rails.env.test?

      previous = Thread.current[TEST_KEY]
      Thread.current[TEST_KEY] = dependencies
      yield
    ensure
      Thread.current[TEST_KEY] = previous
    end
  end
end
