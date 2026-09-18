# frozen_string_literal: true

require 'digest'
require 'securerandom'

module SecretaryCreation
  class Proposals
    PROVIDER = 'chrono_flow'
    def initialize(parser: EventParser, clock: -> { Time.current })
      @parser, @clock = parser, clock
    end

    def call(operation:, request:, claims:, proposal_id: nil)
      # The existing parser can call an AI service. Keep parsing outside all
      # transactions/row locks, then re-authorize and compare the revision below.
      prepared = prepare_candidate(request, claims) if operation == 'propose'
      User.transaction do
        user = User.lock.find_by(identity_issuer: claims.fetch('identity_issuer'), identity_subject: claims.fetch('identity_subject'))
        raise Error.new(:forbidden) unless user&.active_for_specialist?
        draft = if operation == 'propose' && request['proposal_id'].nil?
          SecretaryCreationProposal.new(user: user, public_id: SecureRandom.uuid, home_subject: claims.fetch('sub'),
            identity_issuer: user.identity_issuer, identity_subject: user.identity_subject, revision: 1,
            expires_at: @clock.call + 15.minutes, messages: [])
        else
          SecretaryCreationProposal.lock.find_by(user_id: user.id, public_id: proposal_id || request['proposal_id'],
            home_subject: claims.fetch('sub'), identity_issuer: user.identity_issuer, identity_subject: user.identity_subject)
        end
        raise Error.new(:not_found) unless draft
        case operation
        when 'propose' then propose!(draft, request, user, prepared)
        when 'create' then confirm!(draft, request, user)
        when 'cancel' then cancel!(draft, request)
        when 'status' then expire!(draft)
        else raise Error.new(:invalid_request)
        end
        result = response(draft, request)
        validate_response!(result)
        result
      end
    rescue ActiveRecord::RecordNotUnique
      raise Error.new(:idempotency_conflict)
    end

    private

    def prepare_candidate(request, claims)
      user = User.find_by(identity_issuer: claims.fetch('identity_issuer'), identity_subject: claims.fetch('identity_subject'))
      raise Error.new(:forbidden) unless user&.active_for_specialist?
      draft = if request['proposal_id']
        SecretaryCreationProposal.find_by(user_id: user.id, public_id: request['proposal_id'], home_subject: claims.fetch('sub'),
          identity_issuer: user.identity_issuer, identity_subject: user.identity_subject)
      end
      if request['proposal_id']
        raise Error.new(:not_found) unless draft
        require_open!(draft)
        raise Error.new(:proposal_changed) unless request.fetch('expected_revision') == draft.revision
      end
      messages = (draft&.messages || []) + [request.fetch('message')]
      raise Error.new(:invalid_request) if messages.join.length > 12_000 || messages.length > 12
      { user_id: user.id, revision: draft&.revision, messages: messages,
        parsed: @parser.call(user: user, messages: messages, now: @clock.call) }
    end

    def propose!(draft, request, user, prepared)
      raise Error.new(:forbidden) unless user.id == prepared.fetch(:user_id)
      if draft.persisted?
        require_open!(draft)
        raise Error.new(:proposal_changed) unless request.fetch('expected_revision') == draft.revision && prepared.fetch(:revision) == draft.revision
        draft.revision += 1
      end
      parsed = prepared.fetch(:parsed)
      draft.assign_attributes(messages: prepared.fetch(:messages), status: parsed.fetch(:status), question: parsed[:question],
        details: parsed[:details], content_digest: nil)
      if draft.status == 'ready'
        if conflict?(user, draft.details)
          draft.assign_attributes(status: 'needs_clarification', details: nil, question: 'その時間には予定があります。別の開始・終了日時を指定してください。')
        else
          draft.content_digest = digest(draft)
        end
      end
      # Invalid parser output cannot become a persisted executable draft.
      validate_response!(response(draft, request))
      draft.save!
    end

    def confirm!(draft, request, user)
      same_content = request.fetch('revision') == draft.revision && request.fetch('content_digest') == draft.content_digest
      raise Error.new(:proposal_changed) unless same_content
      key = request.fetch('idempotency_key')
      if draft.status == 'completed'
        raise Error.new(:already_completed) unless draft.idempotency_key == key
        return
      end
      require_open!(draft)
      raise Error.new(:proposal_changed) unless draft.status == 'ready' && digest(draft) == draft.content_digest
      raise Error.new(:idempotency_conflict) if SecretaryCreationProposal.where(user_id: user.id, idempotency_key: key).exists?
      # Actor lock serializes creations through this gateway. Check current domain
      # rows immediately before insert; never silently move a confirmed time.
      raise Error.new(:proposal_changed) if conflict?(user, draft.details)
      event = EventWriter.call(user: user, details: draft.details)
      draft.update!(status: 'completed', idempotency_key: key, result_id: SecureRandom.uuid,
        created_event_id: event.id, completed_at: @clock.call)
    end

    def cancel!(draft, request)
      raise Error.new(:proposal_changed) unless request.fetch('revision') == draft.revision
      return if draft.status == 'cancelled'
      require_open!(draft)
      draft.update!(status: 'cancelled', question: nil)
    end

    def require_open!(draft)
      raise Error.new(:already_completed) if draft.status == 'completed'
      raise Error.new(:expired) if draft.expires_at <= @clock.call || draft.status == 'expired'
      raise Error.new(:proposal_changed) if draft.terminal?
    end

    def expire!(draft)
      draft.assign_attributes(status: 'expired', question: nil) if !draft.terminal? && draft.expires_at <= @clock.call
    end

    def conflict?(user, details)
      Event.left_outer_joins(:event_participants)
        .where('events.created_by_id = :id OR event_participants.user_id = :id', id: user.id)
        .where('events.start_at < ? AND events.end_at > ?', Time.iso8601(details.fetch('end_at')), Time.iso8601(details.fetch('start_at')))
        .exists?
    end

    def digest(draft)
      Contract.digest(provider: PROVIDER, proposal_id: draft.public_id, revision: draft.revision,
        expires_at: draft.expires_at.utc.iso8601, details: draft.details)
    end

    def validate_response!(value)
      Contract.validate_response!(value)
    end

    def response(draft, request)
      {
        'version' => '1.0', 'request_id' => request.fetch('request_id'), 'trace_id' => request.fetch('trace_id'),
        'provider' => PROVIDER, 'proposal_id' => draft.public_id, 'revision' => draft.revision, 'status' => draft.status,
        'expires_at' => draft.expires_at.utc.iso8601, 'content_digest' => draft.content_digest,
        'question' => draft.question, 'details' => draft.details, 'result_id' => draft.result_id,
        'completed_at' => draft.completed_at&.iso8601
      }
    end
  end
end
