# frozen_string_literal: true

module SecretaryMutation
  # Serializes native Event writers with secretary mutation without making the
  # native UI depend on the mutation feature flag or its signing credentials.
  #
  # Callers must derive candidate target ids before entering, then use only the
  # re-fetched rows yielded after the locks and repeat their authorization check.
  class NativeWriterGuard
    class Forbidden < StandardError; end
    class MissingTarget < StandardError; end
    class TargetSetChanged < StandardError; end

    def self.with_events(actor:, event_ids:, user_ids: [], require_all: true,
                         verify_event_ids: nil, before_user_lock: nil,
                         before_target_locks: nil, &block)
      new(actor: actor, event_ids: event_ids, user_ids: user_ids,
        require_all: require_all, verify_event_ids: verify_event_ids,
        before_user_lock: before_user_lock,
        before_target_locks: before_target_locks).call(&block)
    end

    def initialize(actor:, event_ids:, user_ids: [], require_all: true,
                   verify_event_ids: nil, before_user_lock: nil,
                   before_target_locks: nil)
      @actor = actor
      @event_ids = normalize_ids(event_ids)
      @additional_user_ids = normalize_ids(user_ids)
      @require_all = require_all
      @verify_event_ids = verify_event_ids
      @before_user_lock = before_user_lock
      @before_target_locks = before_target_locks
    end

    def call
      raise ArgumentError, 'actor is required' unless actor&.id
      raise ArgumentError, 'block is required' unless block_given?

      ActiveRecord::Base.transaction do
        # Event ownership is not editable through the native writers. Previewing
        # owner ids before locking is therefore sufficient to establish the
        # global User-before-target order; target rows are always re-fetched.
        owner_ids = Event.where(id: event_ids).pluck(:created_by_id)
        before_user_lock&.call
        locked_users = lock_users!([actor.id, *additional_user_ids, *owner_ids])
        locked_actor = locked_users[actor.id]
        unless locked_actor && (!locked_actor.respond_to?(:active_for_specialist?) || locked_actor.active_for_specialist?)
          raise Forbidden, 'actor is no longer active'
        end
        before_target_locks&.call
        AdvisoryLock.acquire_targets!(event_ids: event_ids)
        events = Event.where(id: event_ids).order(:id).lock.index_by(&:id)
        if require_all && events.keys.sort != event_ids
          raise MissingTarget, 'event target changed while waiting for native writer lock'
        end
        if verify_event_ids && normalize_ids(verify_event_ids.call) != event_ids
          raise TargetSetChanged, 'event target set changed while waiting for native writer lock'
        end

        yield events
      end
    end

    private

    attr_reader :actor, :event_ids, :additional_user_ids, :require_all,
      :verify_event_ids, :before_user_lock, :before_target_locks

    def lock_users!(ids)
      User.where(id: normalize_ids(ids)).order(:id).lock.index_by(&:id)
    end

    def normalize_ids(values)
      Array(values).filter_map do |value|
        Integer(value, exception: false).presence
      end.select(&:positive?).uniq.sort
    end
  end
end
