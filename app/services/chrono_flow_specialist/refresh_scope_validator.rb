# frozen_string_literal: true

require 'digest'

module ChronoFlowSpecialist
  # The post-write read is a read capability, not another confirmation. It must
  # name the saved receipt scope and still belong to its original security context.
  class RefreshScopeValidator
    ROUTE = '/api/v1/specialists/chrono_flow'
    SCOPE_KEYS = %w[capability expires_at scope_ref security_context_digest].freeze

    def initialize(configuration: nil)
      @configuration = configuration
    end

    def validate!(request:, authentication:, user:, raw_body:, now:)
      scope = request.fetch('constraints').fetch('refresh_scope')
      claims = authentication.claims
      expected_binding = {
        'capability' => 'schedule_context', 'http_method' => 'POST', 'http_path' => ROUTE,
        'body_sha256' => Digest::SHA256.hexdigest(raw_body),
        'request_id' => request.fetch('request_id'), 'trace_id' => request.fetch('trace_id')
      }
      reject! unless expected_binding.all? { |key, value| claims[key] == value }

      user.reload
      reject! unless user.active_for_specialist? &&
        user.identity_issuer == authentication.identity_issuer &&
        user.identity_subject == authentication.identity_subject

      proposals = SecretaryMutationProposal.where(
        user_id: user.id, home_subject: claims.fetch('sub'), status: 'completed',
        identity_issuer: authentication.identity_issuer, identity_subject: authentication.identity_subject
      ).where("refresh_scope ->> 'scope_ref' = ?", scope.fetch('scope_ref')).limit(2).to_a
      reject! unless proposals.one?
      proposal = proposals.first
      reject! unless proposal.executed? && proposal.time_zone == request.fetch('time_zone') &&
        proposal.refresh_scope == scope && now < Time.iso8601(scope.fetch('expires_at'))

      configuration = @configuration || SecretaryMutation::Configuration.new
      configuration.validate!
      digest = SecretaryMutation::Versioner.new(configuration: configuration)
        .security_context_digest(user: user, home_subject: claims.fetch('sub'))
      reject! unless ActiveSupport::SecurityUtils.secure_compare(digest, scope.fetch('security_context_digest'))
      true
    rescue SecretaryMutation::Error
      raise Errors::Error.new(:service_unavailable), cause: nil
    rescue KeyError, ArgumentError, TypeError
      reject!
    end

    private

    def reject!
      raise Errors::Error.new(:insufficient_scope), cause: nil
    end
  end
end
