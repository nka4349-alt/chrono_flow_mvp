# frozen_string_literal: true

module SecretaryMutation
  class EventWriter
    Result = Struct.new(:target_version_after, :domain_outcome, :related_effects, :executed_snapshot, keyword_init: true)

    def initialize(proposal:, event:, user:, versioner:, time_zone:, expiry_guard:, before_event_lock: nil)
      @proposal = proposal
      @event = event
      @user = user
      @versioner = versioner
      @time_zone = time_zone
      @expiry_guard = expiry_guard
      @before_event_lock = before_event_lock
    end

    def call
      @before_event_lock&.call(@event.id)
      @event = Event.lock.find_by(id: @event.id)
      expire_if_needed!
      return conflict!(:target_changed) unless @event

      lock_relationships!
      expire_if_needed!
      current_relationships = @versioner.relationship_fingerprint(@event,
        reference: @proposal.relationship_fingerprint)
      return conflict!(:relationships_changed) unless secure_equal?(current_relationships, @proposal.relationship_fingerprint)
      return conflict!(:target_changed) unless EventProjection.eligible?(@event, @user)
      current_version = @versioner.target_version(@event, time_zone: @time_zone,
        reference: @proposal.target_version)
      return conflict!(:target_changed) unless secure_equal?(current_version, @proposal.target_version)

      if @proposal.operation == 'event.update'
        update_event!
      else
        delete_event!
      end
    end

    private

    def expire_if_needed!
      expired_at = @expiry_guard.call
      throw :mutation_expired, { expired_at: expired_at } if expired_at
    end

    def lock_relationships!
      Event.where(parent_id: @event.id).order(:id).lock.load
      EventGroup.where(event_id: @event.id).order(:id).lock.load
      EventAccessGrant.where(event_id: @event.id).order(:id).lock.load
      EventParticipant.where(event_id: @event.id).order(:id).lock.load
      EventShare.where(event_id: @event.id).order(:id).lock.load
      EventRequest.where(event_id: @event.id).order(:id).lock.load
      EventShareRequest.where(event_id: @event.id).order(:id).lock.load
      EventReminder.where(event_id: @event.id).order(:id).lock.load
      if (room = ChatRoom.where(chatable_type: 'Event', chatable_id: @event.id).order(:id).lock.first)
        Message.where(chat_room_id: room.id).order(:id).lock.load
      end
      AiRecommendation.where('source_event_id = :id OR created_event_id = :id', id: @event.id).order(:id).lock.load
      AiContextAccessLog.where(event_id: @event.id).order(:id).lock.load
      EventProjection.notification_rows(@event).lock.load
    end

    def update_event!
      after = @proposal.after_snapshot
      changed = @proposal.changed_fields
      if changed.include?('schedule') && EventProjection.pending_reminder?(@event)
        return conflict!(:relationships_changed)
      end

      attrs = {}
      %w[title description location].each { |field| attrs[field] = after.fetch(field) if changed.include?(field) }
      attrs.merge!(schedule_attributes(after.fetch('schedule'))) if changed.include?('schedule')
      if changed.include?('schedule') && collision?(attrs.fetch(:start_at), attrs.fetch(:end_at))
        return conflict!(:target_changed)
      end
      persist_update!(attrs, after)
      Result.new(
        target_version_after: @versioner.target_version(@event, time_zone: @time_zone),
        domain_outcome: 'event_updated', related_effects: { 'type' => 'none' },
        executed_snapshot: nil
      )
    end

    def delete_event!
      return conflict!(:relationships_changed) if EventProjection.notification_rows(@event).exists?

      plan = EventProjection.delete_effects(@event)
      return conflict!(:relationships_changed) unless plan == @proposal.planned_related_effects

      expire_if_needed!
      @event.destroy!
      Result.new(target_version_after: nil, domain_outcome: 'event_deleted',
        related_effects: EventProjection.executed_delete_effects(plan), executed_snapshot: nil)
    end

    def schedule_attributes(schedule)
      request_zone = ActiveSupport::TimeZone[schedule.fetch('time_zone')]
      if schedule.fetch('precision') == 'date'
        start_on = Date.iso8601(schedule.fetch('start_on'))
        end_on = Date.iso8601(schedule.fetch('end_on'))
        request_start = unambiguous_midnight(request_zone, start_on)
        request_end = unambiguous_midnight(request_zone, end_on)
        start_at = unambiguous_midnight(Time.zone, start_on)
        end_at = unambiguous_midnight(Time.zone, end_on)
        return conflict!(:target_changed) unless request_start && request_end && start_at && end_at

        { start_at: start_at, end_at: end_at, all_day: true }
      else
        { start_at: Time.iso8601(schedule.fetch('start_at')),
          end_at: Time.iso8601(schedule.fetch('end_at')), all_day: false }
      end
    end

    def persist_update!(attrs, expected_snapshot)
      all_day_schedule = expected_snapshot.dig('schedule', 'precision') == 'date' && attrs.key?(:all_day)
      if all_day_schedule
        @event.assign_attributes(attrs)
        raise ActiveRecord::RecordInvalid, @event unless @event.valid?

        # Event's legacy normalization inspects instants in the application zone. The contract's
        # all-day value is instead defined by the request IANA zone, already checked above.
        @event.all_day = true
        expire_if_needed!
        validate_text_snapshot!(expected_snapshot)
        @event.save!(validate: false)
      else
        expire_if_needed!
        validate_text_snapshot!(expected_snapshot)
        @event.update!(attrs)
      end
      @event.reload
      unless EventProjection.snapshot(@event, time_zone: @time_zone) == expected_snapshot
        raise Error.new(:unavailable)
      end
    end

    def validate_text_snapshot!(snapshot)
      SecretaryMutation::Contract.event_title!(snapshot.fetch('title'))
      SecretaryMutation::Contract.description!(snapshot['description']) unless snapshot['description'].nil?
      SecretaryMutation::Contract.event_location!(snapshot['location']) unless snapshot['location'].nil?
    end

    def collision?(start_at, end_at)
      Event.left_outer_joins(:event_participants)
        .where.not(events: { id: @event.id })
        .where('events.created_by_id = :id OR event_participants.user_id = :id', id: @user.id)
        .where('events.start_at < ? AND events.end_at > ?', end_at, start_at)
        .exists?
    end

    def unambiguous_midnight(zone, date)
      wall_clock = DateTime.new(date.year, date.month, date.day, 0, 0, 0)
      return nil unless zone.tzinfo.periods_for_local(wall_clock).one?

      value = zone.local(date.year, date.month, date.day, 0, 0, 0)
      return nil unless [value.year, value.month, value.day, value.hour, value.min, value.sec] ==
        [date.year, date.month, date.day, 0, 0, 0]

      value
    rescue ArgumentError
      nil
    end

    def conflict!(reason)
      throw :mutation_conflict, reason.to_s
    end

    def secure_equal?(one, two)
      one.bytesize == two.to_s.bytesize && ActiveSupport::SecurityUtils.secure_compare(one, two.to_s)
    end
  end
end
