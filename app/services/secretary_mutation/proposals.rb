# frozen_string_literal: true

module SecretaryMutation
  class Proposals
    DeferredFailure = Struct.new(:error, keyword_init: true)

    EXECUTION_TTL = 5.minutes
    UNEXECUTED_STATUS_TTL = 30.days
    RECEIPT_DETAIL_TTL = 30.days
    IDEMPOTENCY_TTL = 400.days
    REFRESH_TTL = 600.seconds

    def initialize(configuration:, clock:, before_session_lock: nil, before_user_lock: nil,
                   after_preview: nil, after_advisory_lock: nil, before_event_lock: nil)
      @configuration = configuration
      @clock = clock
      @versioner = Versioner.new(configuration: configuration)
      @before_session_lock = before_session_lock
      @before_user_lock = before_user_lock
      @after_preview = after_preview
      @after_advisory_lock = after_advisory_lock
      @before_event_lock = before_event_lock
    end

    def call(phase:, request:, claims:, proposal_id:, operation:)
      deferred_error = nil
      result = User.transaction do
        user = User.find_by(identity_issuer: claims.fetch('identity_issuer'), identity_subject: claims.fetch('identity_subject'))
        raise Error.new(:forbidden) unless user&.active_for_specialist?

        new_proposal = phase == 'propose' && request.fetch('proposal_id').nil?
        unless phase == 'status'
          @before_session_lock&.call(phase, user.id, claims.fetch('sub'))
          AdvisoryLock.acquire_session!(user_id: user.id, home_subject: claims.fetch('sub'))
          user = lock_and_reauthorize_user!(user, claims, nonblocking: false, phase: phase)
        end
        initial_now = @clock.call if new_proposal
        proposal = locate_or_initialize!(phase, request, claims, proposal_id, operation, user, initial_now)
        user = lock_and_reauthorize_user!(user, claims, nonblocking: true, phase: phase) if phase == 'status'
        now = initial_now || @clock.call
        if proposal.persisted? && now >= proposal.status_available_until
          raise Error.new(:not_found)
        end
        if proposal.persisted? && !proposal.executed? && now >= proposal.execution_expires_at && !proposal.terminal?
          expire!(proposal, now)
        end
        if phase == 'status' && receipt_detail_expired?(proposal, now)
          tombstone!(proposal, now)
        end

        response = case phase
        when 'propose'
          if proposal.status == 'expired'
            deferred_error = Error.new(:expired)
            nil
          else
            propose!(proposal, request, user, claims, now)
          end
        when 'execute'
          if proposal.status == 'expired'
            deferred_error = Error.new(:expired)
            nil
          else
            confirm!(proposal, request, user, now)
          end
        when 'cancel'
          if proposal.status == 'expired'
            deferred_error = Error.new(:expired)
            nil
          else
            cancel!(proposal, request, now)
          end
        when 'status'
          build_response(proposal, request, now)
        else
          raise Error.new(:invalid_request)
        end
        if response.is_a?(DeferredFailure)
          deferred_error = response.error
          nil
        else
          response
        end
      end
      raise deferred_error if deferred_error

      result
    rescue ActiveRecord::RecordNotUnique => error
      code = unique_constraint(error) == 'secretary_mutation_actor_idempotency' ? :idempotency_conflict : :conflict
      raise Error.new(code), cause: nil
    rescue ActiveRecord::StaleObjectError
      raise Error.new(:conflict), cause: nil
    end

    private

    def lock_and_reauthorize_user!(user, claims, nonblocking:, phase:)
      @before_user_lock&.call(phase, user.id)
      scope = User.where(
        id: user.id, identity_issuer: claims.fetch('identity_issuer'),
        identity_subject: claims.fetch('identity_subject')
      )
      locked = nonblocking ? scope.lock('FOR UPDATE NOWAIT').first : scope.lock.first
      raise Error.new(:forbidden) unless locked&.active_for_specialist?

      locked
    rescue ActiveRecord::LockWaitTimeout
      raise Error.new(:unavailable), cause: nil
    end

    def locate_or_initialize!(phase, request, claims, path_id, operation, user, now)
      if phase == 'propose' && request.fetch('proposal_id').nil?
        raise Error.new(:invalid_request) unless path_id.nil? && operation == request.fetch('operation')
        open_count = SecretaryMutationProposal.where(user_id: user.id, home_subject: claims.fetch('sub'))
          .where.not(status: SecretaryMutationProposal::TERMINAL_STATUSES)
          .where('execution_expires_at > ?', now).count
        raise Error.new(:conflict) if open_count >= 5

        return SecretaryMutationProposal.new(
          user: user, public_id: SecureRandom.uuid, home_subject: claims.fetch('sub'),
          identity_issuer: user.identity_issuer, identity_subject: user.identity_subject,
          operation: operation, locale: request.fetch('locale'), time_zone: request.fetch('time_zone'),
          status: 'needs_target', revision: 1, execution_expires_at: execution_expiry(now),
          status_available_until: execution_expiry(now) + UNEXECUTED_STATUS_TTL,
          messages: [], candidate_mappings: [], changed_fields: []
        )
      end

      id = path_id || request['proposal_id']
      scope = SecretaryMutationProposal.where(
        user_id: user.id, public_id: id, home_subject: claims.fetch('sub'),
        identity_issuer: user.identity_issuer, identity_subject: user.identity_subject,
        operation: operation
      )
      preview = scope.first
      raise Error.new(:not_found) unless preview

      event_id = transition_event_id(preview, phase, request)
      @after_preview&.call(phase, preview.public_id, event_id)
      locked = if phase == 'status'
        target_available = event_id.nil? || AdvisoryLock.try_target(event_id: event_id)
        target_available && AdvisoryLock.try_proposal(public_id: preview.public_id)
      else
        AdvisoryLock.acquire_target!(event_id: event_id) if event_id
        AdvisoryLock.acquire_proposal!(public_id: preview.public_id)
      end
      raise Error.new(:in_progress) unless locked
      @after_advisory_lock&.call(phase, preview.public_id, event_id)

      proposal = scope.lock.first
      raise Error.new(:not_found) unless proposal
      if phase == 'status' && transition_event_id(proposal, phase, request) != event_id
        raise Error.new(:in_progress)
      end

      proposal
    end

    def transition_event_id(proposal, phase, request)
      return nil if phase == 'status' && proposal.executed?
      return proposal.target_event_id if proposal.target_event_id
      return nil unless phase == 'propose' && request['candidate_ref']
      return nil if truncated_candidate_search?(proposal)

      proposal.candidate_mappings.find do |item|
        item['candidate_ref'] == request['candidate_ref'] && item['revision'] == proposal.revision
      end&.[]('event_id')
    end

    def propose!(proposal, request, user, claims, now)
      previous_execution_expires_at = proposal.execution_expires_at
      previous_search_truncated = truncated_candidate_search?(proposal)
      if proposal.persisted?
        require_revision!(proposal, request.fetch('expected_revision'))
        raise Error.new(:proposal_changed) if proposal.terminal?
        proposal.revision += 1
      end
      messages = proposal.messages + [request.fetch('message')]
      raise Error.new(:invalid_request) if messages.length > 12 || messages.sum(&:length) > 12_000
      proposal.messages = messages

      selected = selected_event(proposal, request, user, previous_execution_expires_at, now)
      selected ||= retained_target(proposal, user)
      proposal.execution_expires_at = execution_expiry(now)
      proposal.status_available_until = proposal.execution_expires_at + UNEXECUTED_STATUS_TTL
      unless selected
        search_message = previous_search_truncated ? request.fetch('message') : messages.join("\n")
        search = EventTargetSearch.new(user: user, message: search_message,
          time_zone: proposal.time_zone, now: now).call
        if search.events.length != 1 || search.truncated
          assign_needs_target!(proposal, search, claims)
          proposal.save!
          audit!(proposal, 'proposal_needs_target', now)
          return build_response(proposal, request, now)
        end
        selected = search.events.first
      end

      assign_plan!(proposal, selected, now)
      proposal.save!
      audit!(proposal, "proposal_#{proposal.status}", now)
      build_response(proposal, request, now)
    end

    def selected_event(proposal, request, user, previous_execution_expires_at, now)
      candidate_ref = request['candidate_ref']
      return nil unless candidate_ref
      return nil if truncated_candidate_search?(proposal)

      previous_revision = proposal.revision - 1
      mapping = proposal.candidate_mappings.find do |item|
        item['candidate_ref'] == candidate_ref && item['revision'] == previous_revision &&
          item['proposal_id'] == proposal.public_id &&
          item['operation'] == proposal.operation && item['home_subject'] == proposal.home_subject &&
          item['identity_issuer'] == proposal.identity_issuer && item['identity_subject'] == proposal.identity_subject &&
          item['execution_expires_at'] == timestamp(previous_execution_expires_at)
      end
      raise Error.new(:target_changed) unless mapping
      raise Error.new(:expired) if Time.iso8601(mapping.fetch('execution_expires_at')) <= now

      event = Event.find_by(id: mapping.fetch('event_id'))
      raise Error.new(:target_changed) unless event && EventProjection.eligible?(event, user)
      current = @versioner.target_version(event, time_zone: proposal.time_zone,
        reference: mapping.fetch('target_version'))
      raise Error.new(:target_changed) unless secure_equal?(current, mapping.fetch('target_version'))

      event
    end

    def retained_target(proposal, user)
      return nil unless %w[needs_clarification ready].include?(proposal.status)
      return nil unless proposal.target_ref.present? || proposal.target_event_id
      raise Error.new(:target_changed) unless proposal.target_event_id

      event = Event.find_by(id: proposal.target_event_id)
      raise Error.new(:target_changed) unless event && EventProjection.eligible?(event, user)

      current = @versioner.target_version(event, time_zone: proposal.time_zone,
        reference: proposal.target_version)
      raise Error.new(:target_changed) unless secure_equal?(current, proposal.target_version)

      event
    end

    def assign_needs_target!(proposal, search, claims)
      question = if search.truncated
        '候補が多いため、予定名や日時で絞り込んでください。'
      elsif search.events.empty?
        '対象の予定を特定できませんでした。予定名や日時を追加してください。'
      else
        '対象の予定を選んでください。'
      end
      SecretaryMutation::Contract.provider_generated_text!(question)
      proposal.assign_attributes(
        status: 'needs_target', reason_code: nil,
        question: question,
        target_ref: nil, target_event_id: nil, target_version: nil, relationship_fingerprint: nil,
        target_display: nil, before_snapshot: nil, after_snapshot: nil, changed_fields: [],
        planned_related_effects: nil, content_digest: nil
      )
      mappings = search.events.map do |event|
        {
          'candidate_ref' => @versioner.opaque_ref('sc1'), 'event_id' => event.id,
          'proposal_id' => proposal.public_id, 'revision' => proposal.revision, 'operation' => proposal.operation,
          'home_subject' => claims.fetch('sub'), 'identity_issuer' => proposal.identity_issuer,
          'identity_subject' => proposal.identity_subject,
          'execution_expires_at' => timestamp(proposal.execution_expires_at),
          'target_version' => @versioner.target_version(event, time_zone: proposal.time_zone),
          'display' => EventProjection.display(event, time_zone: proposal.time_zone)
        }
      end
      mappings << { 'truncated' => true } if search.truncated
      proposal.candidate_mappings = mappings
    end

    def assign_plan!(proposal, event, now)
      plan = EventPlan.new(event: event, operation: proposal.operation,
        messages: proposal.messages, time_zone: proposal.time_zone, now: now).call
      SecretaryMutation::Contract.provider_generated_text!(plan.question)
      SecretaryMutation::Contract.display_title!(event.title)
      target_version = @versioner.target_version(event, time_zone: proposal.time_zone)
      relationship_fingerprint = @versioner.relationship_fingerprint(event)
      proposal.assign_attributes(
        status: plan.status, reason_code: plan.reason_code, question: plan.question,
        candidate_mappings: [], target_ref: @versioner.opaque_ref('st1'), target_event_id: event.id,
        target_version: target_version, relationship_fingerprint: relationship_fingerprint,
        target_display: { 'title' => event.title }, before_snapshot: plan.before,
        after_snapshot: plan.after, changed_fields: plan.changed_fields,
        planned_related_effects: plan.planned_related_effects, content_digest: nil
      )
      proposal.content_digest = digest(proposal) if proposal.status == 'ready'
    end

    def confirm!(proposal, request, user, now)
      require_revision!(proposal, request.fetch('revision'))
      key_digest = Digest::SHA256.hexdigest(request.fetch('idempotency_key'))
      if proposal.executed?
        raise Error.new(:idempotency_conflict) unless secure_equal?(key_digest, proposal.idempotency_key_digest)
        tombstone!(proposal, now) if receipt_detail_expired?(proposal, now)
        return build_response(proposal, request, now)
      end
      raise Error.new(:proposal_changed) unless proposal.status == 'ready'
      exact = request.fetch('operation') == proposal.operation &&
        request.fetch('target_ref') == proposal.target_ref && request.fetch('target_version') == proposal.target_version &&
        request.fetch('content_digest') == proposal.content_digest && digest(proposal) == proposal.content_digest
      raise Error.new(:proposal_changed) unless exact
      if SecretaryMutationProposal.where(user_id: user.id, idempotency_key_digest: key_digest).where.not(id: proposal.id).exists?
        raise Error.new(:idempotency_conflict)
      end
      event = Event.find_by(id: proposal.target_event_id)
      raise Error.new(:target_changed) unless event

      writer_result = nil
      writer_outcome = catch(:mutation_expired) do
        conflict_reason = catch(:mutation_conflict) do
          writer_result = EventWriter.new(
            proposal: proposal, event: event, user: user, versioner: @versioner,
            time_zone: proposal.time_zone, before_event_lock: @before_event_lock,
            expiry_guard: lambda do
              checked_at = @clock.call
              checked_at if checked_at >= proposal.execution_expires_at
            end
          ).call
          nil
        end
        [:finished, conflict_reason]
      end
      if writer_outcome.is_a?(Hash) && writer_outcome.key?(:expired_at)
        expire!(proposal, writer_outcome.fetch(:expired_at))
        return DeferredFailure.new(error: Error.new(:expired))
      end
      conflict_reason = writer_outcome.fetch(1)
      if conflict_reason
        proposal.update!(status: 'conflicted', reason_code: conflict_reason,
          question: conflict_question(conflict_reason), conflicted_at: now)
        audit!(proposal, 'mutation_conflicted', now, 'reason_code' => conflict_reason)
        return build_response(proposal, request, now)
      end

      completed_at = @clock.call
      result_id = SecureRandom.uuid
      receipt = {
        'result_id' => result_id, 'operation' => proposal.operation,
        'target_ref' => proposal.target_ref, 'target_version_before' => proposal.target_version,
        'target_version_after' => writer_result.target_version_after,
        'completed_at' => timestamp(completed_at), 'domain_outcome' => writer_result.domain_outcome,
        'related_effects' => writer_result.related_effects, 'executed_snapshot' => writer_result.executed_snapshot
      }
      refresh_scope = {
        'capability' => 'schedule_context', 'scope_ref' => @versioner.opaque_ref('rs1'),
        'expires_at' => timestamp(completed_at + REFRESH_TTL),
        'security_context_digest' => @versioner.security_context_digest(user: user, home_subject: proposal.home_subject)
      }
      proposal.assign_attributes(
        status: 'completed', reason_code: nil, question: nil, idempotency_key_digest: key_digest,
        result_id: result_id, receipt: receipt, refresh_scope: refresh_scope, completed_at: completed_at,
        receipt_detail_available_until: completed_at + RECEIPT_DETAIL_TTL,
        status_available_until: completed_at + IDEMPOTENCY_TTL,
        idempotency_available_until: completed_at + IDEMPOTENCY_TTL
      )
      proposal.target_event_id = nil if proposal.operation == 'event.delete'
      proposal.save!
      audit!(proposal, 'mutation_completed', completed_at, 'result_id' => result_id,
        'domain_outcome' => writer_result.domain_outcome)
      outbox!(proposal, completed_at)
      build_response(proposal, request, now)
    end

    def cancel!(proposal, request, now)
      require_revision!(proposal, request.fetch('revision'))
      return build_response(proposal, request, now) if proposal.status == 'cancelled'
      raise Error.new(:proposal_changed) if proposal.terminal? || proposal.executed?

      proposal.update!(status: 'cancelled', reason_code: 'user_cancelled',
        question: nil, cancelled_at: now)
      audit!(proposal, 'proposal_cancelled', now)
      build_response(proposal, request, now)
    end

    def expire!(proposal, now)
      proposal.update!(status: 'expired', reason_code: 'execution_expired',
        question: '確認期限が切れました。もう一度提案してください。', expired_at: now)
      audit!(proposal, 'proposal_expired', now)
    end

    def receipt_detail_expired?(proposal, now)
      proposal.executed? && proposal.receipt_detail_available_until &&
        now >= proposal.receipt_detail_available_until && proposal.status != 'completed_tombstone'
    end

    def tombstone!(proposal, now)
      receipt = proposal.receipt
      proposal.update!(
        status: 'completed_tombstone', reason_code: 'receipt_detail_expired', messages: [],
        question: nil, candidate_mappings: [], target_ref: nil, target_event_id: nil,
        target_version: nil, relationship_fingerprint: nil, target_display: nil,
        before_snapshot: nil, after_snapshot: nil, changed_fields: [], planned_related_effects: nil,
        content_digest: nil, refresh_scope: nil,
        receipt: {
          'kind' => 'tombstone', 'result_id' => receipt.fetch('result_id'),
          'operation' => receipt.fetch('operation'), 'completed_at' => receipt.fetch('completed_at'),
          'domain_outcome' => receipt.fetch('domain_outcome')
        },
        updated_at: now
      )
    end

    def audit!(proposal, event_type, now, payload = {})
      proposal.secretary_mutation_audits.create!(event_type: event_type,
        revision: proposal.revision, payload: payload, occurred_at: now, created_at: now)
    end

    def outbox!(proposal, now)
      proposal.secretary_mutation_outbox_entries.create!(
        public_id: SecureRandom.uuid, event_type: 'secretary_mutation.completed', status: 'pending',
        payload: { 'proposal_id' => proposal.public_id, 'operation' => proposal.operation,
          'result_id' => proposal.result_id, 'domain_outcome' => proposal.receipt.fetch('domain_outcome') },
        occurred_at: now
      )
    end

    def digest(proposal)
      SecretaryMutation::Contract.digest(digest_input(proposal))
    rescue SecretaryMutation::Contract::Invalid
      raise Error.new(:unavailable), cause: nil
    end

    def digest_input(proposal)
      {
        'provider' => 'chrono_flow', 'proposal_id' => proposal.public_id,
        'revision' => proposal.revision, 'execution_expires_at' => timestamp(proposal.execution_expires_at),
        'operation' => proposal.operation, 'target_ref' => proposal.target_ref,
        'target_version' => proposal.target_version, 'before' => proposal.before_snapshot,
        'after' => proposal.after_snapshot, 'changed_fields' => proposal.changed_fields.sort,
        'relationship_fingerprint' => proposal.relationship_fingerprint,
        'planned_related_effects' => proposal.planned_related_effects
      }
    end

    def build_response(proposal, request, now)
      response = ResponseBuilder.new(proposal: proposal, request_id: request.fetch('request_id'),
        trace_id: request.fetch('trace_id'), now: now).call
      SecretaryMutation::Contract.validate_success_response!(response)
      response
    rescue SecretaryMutation::Contract::Invalid
      raise Error.new(:unavailable), cause: nil
    end

    def require_revision!(proposal, revision)
      raise Error.new(:proposal_changed) unless proposal.revision == revision
    end

    def truncated_candidate_search?(proposal)
      Array(proposal.candidate_mappings).any? { |item| item['truncated'] == true }
    end

    def timestamp(value)
      value.utc.iso8601(value.usec.zero? ? 0 : 6)
    end

    # The wire contract deliberately constrains execution expiry to whole seconds.
    # Build it once and derive status retention from the same instant so fractional
    # timestamp arithmetic remains exact.
    def execution_expiry(now)
      now.change(usec: 0) + EXECUTION_TTL
    end

    def secure_equal?(one, two)
      one.to_s.bytesize == two.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(one.to_s, two.to_s)
    end

    def unique_constraint(error)
      result = error.cause.respond_to?(:result) ? error.cause.result : nil
      result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
    rescue StandardError
      nil
    end

    def conflict_question(reason)
      reason == 'relationships_changed' ?
        '関連情報が確認後に変わりました。内容を確認して、もう一度提案してください。' :
        '予定が確認後に変わりました。内容を確認して、もう一度提案してください。'
    end
  end
end
