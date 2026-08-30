# frozen_string_literal: true

module ChronoFlowSpecialist
  module Dependencies
    TEST_OVERRIDE_KEY = :chrono_flow_specialist_test_dependencies

    module_function

    def current
      override = Thread.current[TEST_OVERRIDE_KEY]
      return override if override

      configuration = Configuration.new
      build(configuration: configuration)
    end

    def with_test(dependencies)
      raise "test dependency injection is test-only" unless Rails.env.test?

      previous = Thread.current[TEST_OVERRIDE_KEY]
      Thread.current[TEST_OVERRIDE_KEY] = dependencies
      begin
        yield
      ensure
        Thread.current[TEST_OVERRIDE_KEY] = previous
      end
    end

    def build(configuration:, jwks_provider: nil, replay_store: nil, clock: -> { Time.current }, fact_secret: nil)
      contracts = ContractSchemas.new
      fact_id = FactId.new(secret: fact_secret || Rails.application.secret_key_base)
      jwks_provider ||= JwksProvider.new(configuration: configuration)
      replay_store ||= ReplayStore.new(configuration: configuration)

      {
        configuration: configuration,
        request_validator: RequestValidator.new(contracts: contracts, clock: clock),
        jwt_authenticator: JwtAuthenticator.new(configuration: configuration, jwks_provider: jwks_provider, clock: clock),
        replay_store: replay_store,
        user_resolver: UserResolver.new,
        schedule_reader: ScheduleReader.new(fact_id: fact_id),
        response_builder: ResponseBuilder.new(contracts: contracts, fact_id: fact_id),
        clock: clock
      }
    end
  end
end
