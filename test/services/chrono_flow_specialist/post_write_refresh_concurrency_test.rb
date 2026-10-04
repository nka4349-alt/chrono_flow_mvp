# frozen_string_literal: true

require 'test_helper'
require_relative '../secretary_mutation/test_support'
require 'timeout'

class ChronoFlowPostWriteRefreshConcurrencyTest < ActiveSupport::TestCase
  include SecretaryMutationTestSupport
  self.use_transactional_tests = false

  EXPECTED_DATABASE = 'chrono_flow_post_write_refresh_test_20261004'
  ROUTE = '/api/v1/specialists/chrono_flow'

  setup do
    expected_database = ENV['POST_WRITE_REFRESH_EXPECTED_DATABASE']
    skip 'set POST_WRITE_REFRESH_EXPECTED_DATABASE for the dedicated PostgreSQL run' if expected_database.blank?
    assert_equal EXPECTED_DATABASE, expected_database,
      'post-write read concurrency tests require the fixed dedicated database name'
    assert_equal EXPECTED_DATABASE, ActiveRecord::Base.connection_db_config.database
    assert_equal EXPECTED_DATABASE, ActiveRecord::Base.connection.select_value('SELECT current_database()')
    assert_equal 'PostgreSQL', ActiveRecord::Base.connection.adapter_name
    @now = Time.zone.parse('2026-10-04 09:00:00.123456')
    @user = User.create!(name: 'Read race owner', email: "read-race-#{SecureRandom.hex(6)}@example.test",
      password: 'Password-123!', identity_issuer: TEST_IDENTITY_ISSUER,
      identity_subject: "read-race|#{SecureRandom.uuid}")
    @home_subject = SecureRandom.uuid
    @configuration = mutation_configuration.validate!
    @event = Event.create!(created_by: @user, title: '競合予定', start_at: @now + 1.hour,
      end_at: @now + 2.hours, color: '#3b82f6')
    @mutation_claims = { 'sub' => @home_subject, 'identity_issuer' => @user.identity_issuer,
      'identity_subject' => @user.identity_subject }
    service = SecretaryMutation::Proposals.new(configuration: @configuration, clock: -> { @now })
    request = mutation_propose(operation: 'event.update', message: '競合予定のタイトルを変更済み予定に変更')
    ready = service.call(phase: 'propose', request: request, claims: @mutation_claims,
      proposal_id: nil, operation: 'event.update')
    assert_equal 'ready', ready['status']
    @completed = service.call(phase: 'execute', request: mutation_confirm(ready), claims: @mutation_claims,
      proposal_id: ready.fetch('proposal_id'), operation: 'event.update')
    assert_equal 'completed', @completed['status']
    @read_request = request_payload(constraints: { 'refresh_scope' => @completed.fetch('refresh_scope') })
    @fact_id = ChronoFlowSpecialist::FactId.new(secret: 'read-race-fact-id-secret-at-least-thirty-two-bytes')
    @reader = ChronoFlowSpecialist::ScheduleReader.new(fact_id: @fact_id)
  end

  teardown do
    SecretaryMutationProposal.where(user_id: @user&.id).delete_all
    Event.where(created_by_id: @user&.id).find_each(&:destroy!)
    User.where(id: @user&.id).delete_all
  end

  test 'committed suspension during actual event read is rejected by fresh post read validation' do
    result, reader_pid, writer_pid = race_after_read do
      User.find(@user.id).update!(status: 'suspended')
    end
    assert_not_equal reader_pid, writer_pid
    assert_equal 403, result.status
    assert_equal 'insufficient_scope', result.body.dig('error', 'code')
    refute result.body.key?('facts')
    assert_equal 'suspended', @user.reload.status
    assert_equal 1, completed_audit_count
  end

  test 'committed user version change during actual event read invalidates the original security digest' do
    result, reader_pid, writer_pid = race_after_read do
      User.find(@user.id).update!(name: 'Changed while reading', updated_at: @user.updated_at + 1.second)
    end
    assert_not_equal reader_pid, writer_pid
    assert_equal 403, result.status
    assert_equal 'insufficient_scope', result.body.dig('error', 'code')
    refute result.body.key?('facts')
  end

  test 'refresh expiry after event read uses the fresh clock rather than request start' do
    result, reader_pid, writer_pid = race_after_read do
      @now = Time.iso8601(@completed.dig('refresh_scope', 'expires_at'))
    end
    assert_not_equal reader_pid, writer_pid
    assert_equal 403, result.status
    assert_equal 'insufficient_scope', result.body.dig('error', 'code')
    refute result.body.key?('facts')
  end

  test 'count day membership and bounded event rows share one statement snapshot across a timed event commit' do
    snapshot_ready = Queue.new
    release_reader = Queue.new
    results = Queue.new
    failures = Queue.new
    reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        reader_thread = Thread.current
        reader_pid = connection.select_value('SELECT pg_backend_pid()').to_i
        seen = false
        subscriber = lambda do |_name, _start, _finish, _id, payload|
          next unless Thread.current == reader_thread && !seen && payload[:sql].include?('WITH eligible AS MATERIALIZED')
          seen = true
          snapshot_ready << reader_pid
          release_reader.pop
        end
        facts = nil
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          facts = @reader.call(user: User.find(@user.id), request: @read_request, now: @now)
        end
        results << facts
      rescue StandardError => error
        failures << error.class.name
      end
    end
    reader_pid = Timeout.timeout(10) { snapshot_ready.pop }
    writer_pid = ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
    @event.reload.update!(title: '後発予定', start_at: @now + 1.day, end_at: @now + 1.day + 1.hour)
    assert_not_equal reader_pid, writer_pid
    release_reader << true
    assert reader.join(10), 'snapshot read must finish within the local bound'
    assert_empty drain(failures)
    facts = Timeout.timeout(5) { results.pop }
    first_summary = facts.find { |fact| fact['fact_type'] == 'schedule_summary' }.fetch('fields')
    first_event = facts.find { |fact| fact['fact_type'] == 'schedule_event' }.fetch('fields')
    assert_equal 1, first_summary['total_count']
    assert_equal 1, first_summary['today_count']
    assert_equal 1, first_summary['returned_count']
    assert_equal false, first_summary['partial']
    assert_equal '変更済み予定', first_event['title']
    assert_equal 'target_day', first_event['day_relation']
    assert_equal (@now + 1.hour).iso8601(0), first_event['start_at']

    after = @reader.call(user: @user.reload, request: @read_request, now: @now)
    after_summary = after.find { |fact| fact['fact_type'] == 'schedule_summary' }.fetch('fields')
    after_event = after.find { |fact| fact['fact_type'] == 'schedule_event' }.fetch('fields')
    assert_equal 1, after_summary['total_count']
    assert_equal 0, after_summary['today_count']
    assert_equal '後発予定', after_event['title']
    assert_equal 'outside_target_day', after_event['day_relation']
    assert_empty after.warnings
    assert_equal 1, completed_audit_count
  ensure
    release_reader << true if defined?(reader) && reader&.alive?
    reader&.join(10)
  end

  test 'response guard rejects contradictory cardinality counts partial flags and warnings' do
    facts = @reader.call(user: @user, request: @read_request, now: @now)
    summary_index = facts.index { |fact| fact['fact_type'] == 'schedule_summary' }
    builder = ChronoFlowSpecialist::ResponseBuilder.new(
      contracts: ChronoFlowSpecialist::ContractSchemas.new, fact_id: @fact_id
    )
    mutations = [
      ->(copy) { copy[summary_index]['fields']['returned_count'] = 0 },
      ->(copy) { copy[summary_index]['fields']['total_count'] = 2 },
      ->(copy) { copy[summary_index]['fields']['today_count'] = 0 },
      ->(copy) { copy[summary_index]['fields']['partial'] = true },
      ->(copy) { copy << copy.first.deep_dup }
    ]
    mutations.each do |change|
      copy = facts.deep_dup
      change.call(copy)
      guarded = ChronoFlowSpecialist::ScheduleReader::ReadFacts.new(copy)
      error = assert_raises(ChronoFlowSpecialist::Errors::Error) do
        builder.success(request: @read_request, facts: guarded, now: @now)
      end
      assert_equal 'invalid_response_schema', error.code
    end
    %w[schedule_context_truncated schedule_context_event_omitted unexpected_warning].each do |warning|
      guarded = ChronoFlowSpecialist::ScheduleReader::ReadFacts.new(facts.deep_dup, warnings: [warning])
      assert_raises(ChronoFlowSpecialist::Errors::Error) do
        builder.success(request: @read_request, facts: guarded, now: @now)
      end
    end
  end

  private

  def completed_audit_count
    SecretaryMutationAudit.joins(:secretary_mutation_proposal)
      .where(secretary_mutation_proposals: { user_id: @user.id }, event_type: 'mutation_completed').count
  end

  def race_after_read
    read_ready = Queue.new
    release_reader = Queue.new
    results = Queue.new
    failures = Queue.new
    blocked_reader = Object.new
    actual_reader = @reader
    blocked_reader.define_singleton_method(:call) do |**arguments|
      facts = actual_reader.call(**arguments)
      read_ready << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
      release_reader.pop
      facts
    end
    raw = JSON.generate(@read_request)
    token = build_token(now: @now.to_i, claim_overrides: @mutation_claims.merge(
      'capability' => 'schedule_context', 'http_method' => 'POST', 'http_path' => ROUTE,
      'body_sha256' => Digest::SHA256.hexdigest(raw),
      'request_id' => @read_request['request_id'], 'trace_id' => @read_request['trace_id']
    ))
    dependencies = ChronoFlowSpecialist::Dependencies.build(
      configuration: test_configuration, clock: -> { @now },
      jwks_provider: FakeJwksProvider.new(keys: { TEST_KID => test_rsa_key.public_key }),
      replay_store: FakeReplayStore.new,
      refresh_scope_validator: ChronoFlowSpecialist::RefreshScopeValidator.new(configuration: @configuration)
    ).merge(schedule_reader: blocked_reader)
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        results << ChronoFlowSpecialist::Handler.new(**dependencies).call(
          raw_body: raw, headers: request_headers(payload: @read_request, token: token)
        )
      rescue StandardError => error
        failures << error.class.name
      end
    end
    reader_pid = Timeout.timeout(10) { read_ready.pop }
    writer_pid = ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
    yield
    release_reader << true
    assert worker.join(10), 'post read authorization must finish within the local bound'
    assert_empty drain(failures)
    [Timeout.timeout(5) { results.pop }, reader_pid, writer_pid]
  ensure
    release_reader << true if defined?(worker) && worker&.alive?
    worker&.join(10)
  end

  def drain(queue)
    values = []
    values << queue.pop(true) until queue.empty?
    values
  end
end
