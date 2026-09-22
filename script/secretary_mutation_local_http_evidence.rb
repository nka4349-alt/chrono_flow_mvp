# frozen_string_literal: true

# Local-only end-to-end evidence for the secretary mutation provider boundary.
#
# Run with the dedicated test database only:
#   RAILS_ENV=test \
#   DATABASE_URL=postgresql:///chrono_flow_mvp_mutation_m1a_test_20260921 \
#   SECRETARY_MUTATION_EVIDENCE_PATH=/new/path/flow_http_evidence.json \
#   bin/rails runner script/secretary_mutation_local_http_evidence.rb
#
# The harness starts only loopback listeners: an ephemeral TLS JWKS endpoint,
# a dedicated Redis process with persistence disabled, and the Rails test
# server. It generates all signing material in a temporary directory and
# removes it when the run finishes.

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'openssl'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'socket'
require 'tempfile'
require 'timeout'

module SecretaryMutationLocalHttpEvidence
  EXPECTED_DATABASE = 'chrono_flow_mvp_mutation_m1a_test_20260921'
  DEFAULT_RAILS_PORT = 32_191
  DEFAULT_JWKS_PORT = 39_191
  DEFAULT_REDIS_PORT = 36_191
  DEFAULT_REDIS_BINARY = '/home/kan/.cache/codex-m1a-redis/root/usr/bin/redis-server'
  DEFAULT_REDIS_LIBRARY_PATH = '/home/kan/.cache/codex-m1a-redis/root/usr/lib/x86_64-linux-gnu'
  TEST_HMAC_KEY = 'flow-mutation-local-http-test-key-32-bytes-minimum'
  TEST_HMAC_KID = 'http-test-k1'
  JWT_KID = 'local-http-rs256-k1'

  module_function

  def run!
    ensure_safe_environment!
    ports = {
      rails: Integer(ENV.fetch('SECRETARY_MUTATION_RAILS_PORT', DEFAULT_RAILS_PORT)),
      jwks: Integer(ENV.fetch('SECRETARY_MUTATION_JWKS_PORT', DEFAULT_JWKS_PORT)),
      redis: Integer(ENV.fetch('SECRETARY_MUTATION_REDIS_PORT', DEFAULT_REDIS_PORT))
    }
    ports.each_value { |port| ensure_loopback_port_available!(port) }

    evidence_path = ENV['SECRETARY_MUTATION_EVIDENCE_PATH']
    if evidence_path && File.exist?(evidence_path)
      abort "refusing to overwrite evidence: #{evidence_path}"
    end

    Dir.mktmpdir('secretary-mutation-http-evidence-') do |temporary_directory|
      signing_key = OpenSSL::PKey::RSA.new(2048)
      _ca_key, ca_certificate, server_key, server_certificate, certificate_revocation_list = build_tls_material
      ca_path = File.join(temporary_directory, 'local-ca.pem')
      File.write(ca_path, ca_certificate.to_pem, mode: 'wb', perm: 0o600)
      certificate_directory = File.join(temporary_directory, 'empty-cert-directory')
      FileUtils.mkdir_p(certificate_directory)
      crl_name = format('%08x.r0', ca_certificate.subject.hash)
      File.write(File.join(certificate_directory, crl_name), certificate_revocation_list.to_pem,
        mode: 'wb', perm: 0o600)
      jwks_body = JSON.generate('keys' => [jwk(signing_key.public_key)])
      jwks_server = LocalTlsJsonServer.new(
        host: '127.0.0.1', port: ports.fetch(:jwks), path: '/jwks.json', body: jwks_body,
        certificate: server_certificate, private_key: server_key
      ).start
      verify_local_jwks!(port: ports.fetch(:jwks), ca_path: ca_path)
      verify_default_trust_subprocess!(
        port: ports.fetch(:jwks), ca_path: ca_path, certificate_directory: certificate_directory
      )

      redis_log = File.join(temporary_directory, 'redis.log')
      rails_log = File.join(temporary_directory, 'rails.log')
      redis_pid = start_redis!(port: ports.fetch(:redis), log_path: redis_log)
      wait_for_port!(ports.fetch(:redis), process_id: redis_pid, log_path: redis_log)

      issuer = "https://127.0.0.1:#{ports.fetch(:jwks)}/local-issuer"
      jwks_uri = "https://127.0.0.1:#{ports.fetch(:jwks)}/jwks.json"
      child_environment = {
        'RAILS_ENV' => 'test',
        'DATABASE_URL' => ENV.fetch('DATABASE_URL'),
        'SECRETARY_MUTATION_ENABLED' => 'true',
        'SECRETARY_MUTATION_HMAC_KEYS' => JSON.generate(
          TEST_HMAC_KID => Base64.strict_encode64(TEST_HMAC_KEY)
        ),
        'SECRETARY_MUTATION_ACTIVE_HMAC_KID' => TEST_HMAC_KID,
        'AI_SECRETARY_SPECIALIST_JWT_ISSUER' => issuer,
        'AI_SECRETARY_SPECIALIST_JWKS_URI' => jwks_uri,
        'AI_SECRETARY_SPECIALIST_REPLAY_CACHE_URL' => "redis://127.0.0.1:#{ports.fetch(:redis)}/13",
        'SSL_CERT_FILE' => ca_path,
        'SSL_CERT_DIR' => certificate_directory,
        'NO_PROXY' => '127.0.0.1,localhost',
        'no_proxy' => '127.0.0.1,localhost',
        'PIDFILE' => File.join(temporary_directory, 'rails.pid')
      }
      rails_pid = start_rails!(environment: child_environment, port: ports.fetch(:rails), log_path: rails_log)
      wait_for_port!(ports.fetch(:rails), process_id: rails_pid, log_path: rails_log)

      result = exercise_boundary!(
        port: ports.fetch(:rails), signing_key: signing_key, issuer: issuer,
        jwks_server: jwks_server, ports: ports
      )
      serialized = JSON.pretty_generate(result) + "\n"
      if evidence_path
        FileUtils.mkdir_p(File.dirname(File.expand_path(evidence_path)))
        File.write(evidence_path, serialized, mode: 'wb', perm: 0o600)
      end
      puts serialized
    rescue StandardError
      warn "local JWKS successful responses: #{jwks_server&.request_count || 0}"
      warn "local JWKS TLS errors: #{jwks_server&.errors&.join(' | ') || 'none'}"
      warn "Rails log:\n#{File.read(rails_log)}" if defined?(rails_log) && rails_log && File.file?(rails_log)
      warn "Redis log:\n#{File.read(redis_log)}" if defined?(redis_log) && redis_log && File.file?(redis_log)
      raise
    ensure
      stop_process(rails_pid) if defined?(rails_pid)
      stop_process(redis_pid) if defined?(redis_pid)
      jwks_server&.stop
    end
  end

  def ensure_safe_environment!
    abort 'RAILS_ENV=test is required' unless Rails.env.test?
    actual = ActiveRecord::Base.connection_db_config.database
    abort "refusing non-dedicated database: #{actual}" unless actual == EXPECTED_DATABASE

    redis_binary = ENV.fetch('SECRETARY_MUTATION_REDIS_SERVER', DEFAULT_REDIS_BINARY)
    abort "Redis binary not found: #{redis_binary}" unless File.file?(redis_binary) && File.executable?(redis_binary)
  end

  def exercise_boundary!(port:, signing_key:, issuer:, jwks_server:, ports:)
    run_id = SecureRandom.hex(8)
    now = Time.current.change(usec: 123_456)
    home_subject = SecureRandom.uuid
    identity_subject = "local-http|#{SecureRandom.uuid}"
    user = User.create!(
      name: 'Local HTTP mutation evidence', email: "flow-mutation-http-#{run_id}@example.test",
      password: 'Local-only-Password-123!', identity_issuer: issuer,
      identity_subject: identity_subject, status: 'active'
    )
    event = Event.create!(
      created_by: user, title: "HTTP境界予定#{run_id}", start_at: now + 1.day,
      end_at: now + 1.day + 1.hour, color: '#3b82f6'
    )

    proposal_count_before = SecretaryMutationProposal.where(user: user).count
    propose_payload = {
      'version' => 'draft-0.1', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'operation' => 'event.update',
      'message' => "HTTP境界予定#{run_id}のタイトルをHTTP境界更新#{run_id}に変更",
      'locale' => 'ja-JP', 'time_zone' => 'Asia/Tokyo', 'proposal_id' => nil,
      'expected_revision' => nil, 'candidate_ref' => nil
    }
    propose_wire = signed_wire(
      signing_key: signing_key, issuer: issuer, home_subject: home_subject,
      identity_subject: identity_subject, operation: 'event.update', phase: 'propose',
      path: '/api/v1/secretary/mutation_proposals', payload: propose_payload
    )

    tampered_body = propose_wire.fetch(:body).sub('HTTP境界更新', '改ざん更新')
    tampered = perform_http(port: port, path: propose_wire.fetch(:path), method: 'POST',
      body: tampered_body, headers: propose_wire.fetch(:headers))
    ensure_response!(tampered, 401, error: 'unauthenticated')
    ensure!(event.reload.title.start_with?('HTTP境界予定'), 'tampered body changed the event')

    proposed = perform_wire(port: port, wire: propose_wire)
    ensure_response!(proposed, 201, status: 'ready')
    ready = JSON.parse(proposed.body)
    SecretaryMutation::Contract.validate_success_response!(ready)

    replayed = perform_wire(port: port, wire: propose_wire)
    ensure_response!(replayed, 401, error: 'unauthenticated')
    ensure!(SecretaryMutationProposal.where(user: user).count == proposal_count_before + 1,
      'replayed propose created another proposal')

    status_path = "/api/v1/secretary/mutation_proposals/#{ready.fetch('proposal_id')}"
    in_progress_wire = signed_wire(
      signing_key: signing_key, issuer: issuer, home_subject: home_subject,
      identity_subject: identity_subject, operation: 'event.update', phase: 'status',
      path: status_path, payload: nil
    )
    lock_reached = Queue.new
    release_lock = Queue.new
    lock_failure = Queue.new
    lock_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          SecretaryMutation::AdvisoryLock.acquire_target!(event_id: event.id)
          SecretaryMutation::AdvisoryLock.acquire_proposal!(public_id: ready.fetch('proposal_id'))
          lock_reached << true
          release_lock.pop
        end
      rescue StandardError => error
        lock_failure << error
        lock_reached << false
      end
    end
    begin
      ensure!(lock_reached.pop, 'could not acquire local execution evidence lock')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      in_progress = perform_wire(port: port, wire: in_progress_wire)
      in_progress_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      ensure_response!(in_progress, 202, error: 'in_progress')
      ensure!(in_progress_elapsed < 2.0, 'status did not return in_progress promptly')
    ensure
      release_lock << true if lock_thread.alive?
      lock_thread.join
    end
    raise lock_failure.pop unless lock_failure.empty?

    confirmation_payload = {
      'version' => 'draft-0.1', 'request_id' => SecureRandom.uuid, 'trace_id' => SecureRandom.uuid,
      'proposal_id' => ready.fetch('proposal_id'), 'revision' => ready.fetch('revision'),
      'operation' => ready.fetch('operation'), 'target_ref' => ready.dig('target', 'target_ref'),
      'target_version' => ready.dig('target', 'target_version'),
      'content_digest' => ready.fetch('content_digest'), 'idempotency_key' => SecureRandom.uuid
    }
    confirm_path = "/api/v1/secretary/mutation_proposals/#{ready.fetch('proposal_id')}/confirm"
    confirm_wire = signed_wire(
      signing_key: signing_key, issuer: issuer, home_subject: home_subject,
      identity_subject: identity_subject, operation: 'event.update', phase: 'execute',
      path: confirm_path, payload: confirmation_payload
    )
    confirmed = perform_wire(port: port, wire: confirm_wire)
    ensure_response!(confirmed, 200, status: 'completed')
    completed = JSON.parse(confirmed.body)
    SecretaryMutation::Contract.validate_success_response!(completed)
    result_id = completed.dig('receipt', 'result_id')

    confirm_replay = perform_wire(port: port, wire: confirm_wire)
    ensure_response!(confirm_replay, 401, error: 'unauthenticated')

    status_wire = signed_wire(
      signing_key: signing_key, issuer: issuer, home_subject: home_subject,
      identity_subject: identity_subject, operation: 'event.update', phase: 'status',
      path: status_path, payload: nil
    )
    recovered = perform_wire(port: port, wire: status_wire)
    ensure_response!(recovered, 200, status: 'completed')
    recovered_body = JSON.parse(recovered.body)
    SecretaryMutation::Contract.validate_success_response!(recovered_body)

    event.reload
    proposal = SecretaryMutationProposal.find_by!(public_id: ready.fetch('proposal_id'))
    ensure!(event.title == "HTTP境界更新#{run_id}", 'provider domain update was not persisted')
    ensure!(recovered_body.dig('receipt', 'result_id') == result_id, 'status receipt did not recover')
    ensure!(proposal.secretary_mutation_audits.where(event_type: 'mutation_completed').count == 1,
      'completion audit count was not one')
    ensure!(proposal.secretary_mutation_outbox_entries.count == 1, 'outbox count was not one')

    {
      'evidence_version' => 1,
      'generated_at' => Time.now.utc.iso8601(6),
      'database' => EXPECTED_DATABASE,
      'loopback_endpoints' => {
        'rails' => "http://127.0.0.1:#{ports.fetch(:rails)}",
        'jwks' => "https://127.0.0.1:#{ports.fetch(:jwks)}/jwks.json",
        'redis' => "redis://127.0.0.1:#{ports.fetch(:redis)}/13"
      },
      'network_scope' => 'loopback_only',
      'jwt' => { 'algorithm' => 'RS256', 'kid' => JWT_KID, 'jwks_fetches' => jwks_server.request_count },
      'checks' => {
        'tampered_body_rejected' => true,
        'propose_http_status' => proposed.code.to_i,
        'propose_replay_rejected' => true,
        'in_progress_http_status' => in_progress.code.to_i,
        'in_progress_prompt_seconds' => in_progress_elapsed.round(6),
        'confirm_http_status' => confirmed.code.to_i,
        'confirm_replay_rejected' => true,
        'status_recovery_http_status' => recovered.code.to_i,
        'status_receipt_matches' => true,
        'domain_write_count' => 1,
        'completion_audit_count' => 1,
        'outbox_count' => 1
      },
      'result' => 'PASS'
    }
  ensure
    cleanup_evidence_records(user) if defined?(user) && user
  end

  def cleanup_evidence_records(user)
    user_id = user.id
    Event.where(created_by_id: user_id).find_each(&:destroy!)
    SecretaryMutationProposal.where(user_id: user_id).delete_all
    User.where(id: user_id).delete_all
  end

  def signed_wire(signing_key:, issuer:, home_subject:, identity_subject:, operation:, phase:, path:, payload:)
    body = payload ? JSON.generate(payload) : ''
    now = Time.now.to_i
    claims = {
      'iss' => issuer, 'aud' => 'chrono-flow-secretary-mutations', 'sub' => home_subject,
      'iat' => now, 'exp' => now + 60, 'jti' => SecureRandom.uuid,
      'scope' => "secretary:chrono_flow:#{operation}:#{phase}",
      'identity_issuer' => issuer, 'identity_subject' => identity_subject,
      'mutation_operation' => operation, 'mutation_phase' => phase,
      'http_method' => phase == 'status' ? 'GET' : 'POST', 'http_path' => path,
      'body_sha256' => Digest::SHA256.hexdigest(body),
      'request_id' => payload&.fetch('request_id', nil) || SecureRandom.uuid,
      'trace_id' => payload&.fetch('trace_id', nil) || SecureRandom.uuid
    }
    header = { 'alg' => 'RS256', 'typ' => 'at+jwt', 'kid' => JWT_KID }
    encoded_header = base64url(JSON.generate(header))
    encoded_claims = base64url(JSON.generate(claims))
    signing_input = "#{encoded_header}.#{encoded_claims}"
    signature = base64url(signing_key.sign(OpenSSL::Digest.new('SHA256'), signing_input))
    {
      path: path, method: phase == 'status' ? 'GET' : 'POST', body: body,
      headers: {
        'Accept' => 'application/json', 'Content-Type' => 'application/json',
        'X-Request-Id' => claims.fetch('request_id'), 'X-Trace-Id' => claims.fetch('trace_id'),
        'Authorization' => "Bearer #{signing_input}.#{signature}"
      }
    }
  end

  def perform_wire(port:, wire:)
    perform_http(port: port, path: wire.fetch(:path), method: wire.fetch(:method),
      body: wire.fetch(:body), headers: wire.fetch(:headers))
  end

  def perform_http(port:, path:, method:, body:, headers:)
    http = Net::HTTP.new('127.0.0.1', port, nil)
    http.open_timeout = 2
    http.read_timeout = 10
    request = method == 'GET' ? Net::HTTP::Get.new(path) : Net::HTTP::Post.new(path)
    headers.each { |name, value| request[name] = value }
    request.body = body unless method == 'GET'
    http.start { |connection| connection.request(request) }
  end

  def ensure_response!(response, expected_status, status: nil, error: nil)
    ensure!(response.code.to_i == expected_status,
      "expected HTTP #{expected_status}, got #{response.code}: #{response.body}")
    body = JSON.parse(response.body)
    ensure!(body['status'] == status, "expected status #{status}: #{body.inspect}") if status
    ensure!(body.dig('error', 'code') == error, "expected error #{error}: #{body.inspect}") if error
  end

  def ensure!(condition, message)
    raise message unless condition
  end

  def verify_local_jwks!(port:, ca_path:)
    http = Net::HTTP.new('127.0.0.1', port, nil)
    http.use_ssl = true
    http.ca_file = ca_path
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    response = http.get('/jwks.json', 'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
    ensure!(response.code.to_i == 200, "local JWKS preflight failed: #{response.code}")
  end

  def verify_default_trust_subprocess!(port:, ca_path:, certificate_directory:)
    code = <<~'RUBY'
      require 'net/http'
      require 'openssl'
      port = Integer(ARGV.fetch(0))
      http = Net::HTTP.new('127.0.0.1', port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      response = http.get('/jwks.json', 'Accept' => 'application/json', 'Accept-Encoding' => 'identity')
      abort "unexpected #{response.code}" unless response.code == '200'
    RUBY
    stdout, stderr, status = Open3.capture3(
      { 'SSL_CERT_FILE' => ca_path, 'SSL_CERT_DIR' => certificate_directory },
      RbConfig.ruby, '-e', code, port.to_s
    )
    ensure!(status.success?, "default trust subprocess failed: #{stdout}#{stderr}")
  end

  def start_redis!(port:, log_path:)
    binary = ENV.fetch('SECRETARY_MUTATION_REDIS_SERVER', DEFAULT_REDIS_BINARY)
    library_path = ENV.fetch('SECRETARY_MUTATION_REDIS_LIBRARY_PATH', DEFAULT_REDIS_LIBRARY_PATH)
    log = File.open(log_path, 'wb', 0o600)
    Process.spawn(
      { 'LD_LIBRARY_PATH' => library_path }, binary,
      '--bind', '127.0.0.1', '--port', port.to_s, '--protected-mode', 'yes',
      '--save', '', '--appendonly', 'no', '--daemonize', 'no',
      out: log, err: log
    )
  ensure
    log&.close
  end

  def start_rails!(environment:, port:, log_path:)
    log = File.open(log_path, 'wb', 0o600)
    Process.spawn(
      environment, Rails.root.join('bin/rails').to_s, 'server', '-e', 'test',
      '-b', '127.0.0.1', '-p', port.to_s,
      chdir: Rails.root.to_s, out: log, err: log
    )
  ensure
    log&.close
  end

  def wait_for_port!(port, process_id:, log_path:)
    Timeout.timeout(20) do
      loop do
        begin
          socket = TCPSocket.new('127.0.0.1', port)
          socket.close
          return
        rescue Errno::ECONNREFUSED
          finished = Process.waitpid(process_id, Process::WNOHANG)
          raise "process #{process_id} exited; see #{log_path}" if finished
          sleep 0.05
        end
      end
    end
  rescue Timeout::Error
    raise "timed out waiting for port #{port}; see #{log_path}"
  end

  def ensure_loopback_port_available!(port)
    server = TCPServer.new('127.0.0.1', port)
    server.close
  rescue Errno::EADDRINUSE
    abort "refusing occupied port #{port}"
  end

  def stop_process(process_id)
    return unless process_id

    Process.kill('TERM', process_id)
    Timeout.timeout(10) { Process.wait(process_id) }
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  rescue Timeout::Error
    warn "spawned process #{process_id} did not exit after TERM"
  end

  def jwk(key)
    {
      'kty' => 'RSA', 'use' => 'sig', 'alg' => 'RS256', 'kid' => JWT_KID,
      'n' => base64url(key.n.to_s(2)), 'e' => base64url(key.e.to_s(2))
    }
  end

  def base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def build_tls_material
    ca_key = OpenSSL::PKey::RSA.new(2048)
    ca = OpenSSL::X509::Certificate.new
    ca.version = 2
    ca.serial = SecureRandom.random_number(2**62)
    ca.subject = OpenSSL::X509::Name.parse('/CN=Secretary Mutation Local Test CA')
    ca.issuer = ca.subject
    ca.public_key = ca_key.public_key
    ca.not_before = Time.now - 60
    ca.not_after = Time.now + 3600
    add_certificate_extensions(ca, issuer: ca, extensions: [
      ['basicConstraints', 'CA:TRUE', true], ['keyUsage', 'keyCertSign,cRLSign', true],
      ['subjectKeyIdentifier', 'hash', false]
    ])
    ca.sign(ca_key, OpenSSL::Digest.new('SHA256'))

    server_key = OpenSSL::PKey::RSA.new(2048)
    server = OpenSSL::X509::Certificate.new
    server.version = 2
    server.serial = SecureRandom.random_number(2**62)
    server.subject = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
    server.issuer = ca.subject
    server.public_key = server_key.public_key
    server.not_before = Time.now - 60
    server.not_after = Time.now + 3600
    add_certificate_extensions(server, issuer: ca, extensions: [
      ['basicConstraints', 'CA:FALSE', true], ['keyUsage', 'digitalSignature,keyEncipherment', true],
      ['extendedKeyUsage', 'serverAuth', false], ['subjectAltName', 'IP:127.0.0.1', false],
      ['subjectKeyIdentifier', 'hash', false], ['authorityKeyIdentifier', 'keyid:always', false]
    ])
    server.sign(ca_key, OpenSSL::Digest.new('SHA256'))

    crl = OpenSSL::X509::CRL.new
    crl.version = 1
    crl.issuer = ca.subject
    crl.last_update = Time.now - 60
    crl.next_update = Time.now + 3600
    crl_factory = OpenSSL::X509::ExtensionFactory.new
    crl_factory.issuer_certificate = ca
    crl.add_extension(crl_factory.create_extension('authorityKeyIdentifier', 'keyid:always', false))
    crl.sign(ca_key, OpenSSL::Digest.new('SHA256'))
    [ca_key, ca, server_key, server, crl]
  end

  def add_certificate_extensions(certificate, issuer:, extensions:)
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = certificate
    factory.issuer_certificate = issuer
    extensions.each do |name, value, critical|
      certificate.add_extension(factory.create_extension(name, value, critical))
    end
  end

  class LocalTlsJsonServer
    attr_reader :request_count, :errors

    def initialize(host:, port:, path:, body:, certificate:, private_key:)
      @path = path
      @body = body
      @request_count = 0
      @errors = []
      @tcp_server = TCPServer.new(host, port)
      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = private_key
      context.min_version = OpenSSL::SSL::TLS1_2_VERSION
      @ssl_server = OpenSSL::SSL::SSLServer.new(@tcp_server, context)
    end

    def start
      @thread = Thread.new do
        loop do
          connection = @ssl_server.accept
          handle(connection)
        rescue IOError, Errno::EBADF
          break
        rescue OpenSSL::SSL::SSLError => error
          @errors << "#{error.class}: #{error.message}"
          next
        end
      end
      self
    end

    def stop
      @tcp_server.close
      @thread&.join(2)
    end

    private

    def handle(connection)
      request_line = connection.gets.to_s
      headers = {}
      while (line = connection.gets)
        break if line == "\r\n"

        name, value = line.split(':', 2)
        headers[name.to_s.downcase] = value.to_s.strip
      end
      method, path, = request_line.split(' ', 3)
      if method == 'GET' && path == @path && headers['accept'] == 'application/json'
        @request_count += 1
        respond(connection, 200, 'OK', @body, 'application/json')
      else
        respond(connection, 404, 'Not Found', '{}', 'application/json')
      end
    ensure
      connection.close
    end

    def respond(connection, status, reason, body, content_type)
      connection.write("HTTP/1.1 #{status} #{reason}\r\n")
      connection.write("Content-Type: #{content_type}\r\n")
      connection.write("Content-Length: #{body.bytesize}\r\n")
      connection.write("Content-Encoding: identity\r\n")
      connection.write("Connection: close\r\n\r\n")
      connection.write(body)
    end
  end
end

SecretaryMutationLocalHttpEvidence.run!
