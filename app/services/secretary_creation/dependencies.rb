# frozen_string_literal: true

module SecretaryCreation
  module Dependencies
    TEST_KEY = :secretary_creation_test_dependencies
    module_function

    def current
      return Thread.current[TEST_KEY] if Rails.env.test? && Thread.current[TEST_KEY]
      configuration = ChronoFlowSpecialist::Configuration.new
      { enabled: ENV['SECRETARY_CREATION_ENABLED'] == 'true', configuration: configuration,
        jwks_provider: ChronoFlowSpecialist::JwksProvider.new(configuration: configuration),
        replay_store: ReplayStore.new(configuration: configuration),
        clock: -> { Time.current }, parser: EventParser }
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
