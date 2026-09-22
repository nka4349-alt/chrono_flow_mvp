# frozen_string_literal: true

module SecretaryMutation
  module EventProjection
    module_function

    def snapshot(event, time_zone:)
      zone = ActiveSupport::TimeZone[time_zone]
      raise Error.new(:invalid_request) unless zone

      validate_event_text_fields!(event)

      {
        'kind' => 'event',
        'title' => event.title,
        'description' => event.description,
        'location' => event.location,
        'schedule' => schedule(event, zone)
      }
    end

    def schedule(event, zone)
      if event.all_day?
        start_on = event.start_at.in_time_zone(Time.zone).to_date
        end_on = event.end_at.in_time_zone(Time.zone).to_date
        {
          'precision' => 'date', 'start_at' => nil, 'end_at' => nil,
          'start_on' => start_on.iso8601, 'end_on' => end_on.iso8601,
          'time_zone' => zone.tzinfo.name, 'end_exclusive' => true
        }
      else
        start_time = event.start_at.in_time_zone(zone)
        end_time = event.end_at.in_time_zone(zone)
        {
          'precision' => 'datetime', 'start_at' => rfc3339(start_time), 'end_at' => rfc3339(end_time),
          'start_on' => nil, 'end_on' => nil, 'time_zone' => zone.tzinfo.name, 'end_exclusive' => true
        }
      end
    end

    def display(event, time_zone:)
      SecretaryMutation::Contract.display_title!(event.title)
      value = { 'title' => event.title }
      schedule_value = schedule(event, ActiveSupport::TimeZone[time_zone])
      if event.all_day?
        value.merge('start_on' => schedule_value['start_on'], 'end_on' => schedule_value['end_on'], 'all_day' => true)
      else
        value.merge('start_at' => schedule_value['start_at'], 'end_at' => schedule_value['end_at'], 'all_day' => false)
      end
    end

    def related_tuples(event)
      tuples = []
      tuples.concat(event.children.order(:id).map { |row| tuple('child', row) })
      tuples.concat(event.event_groups.order(:id).map { |row| tuple('group', row, row.group_id) })
      tuples.concat(event.event_participants.order(:id).map { |row| tuple('participant', row, row.user_id, row.source) })
      tuples.concat(event.event_shares.order(:id).map { |row| tuple('share', row, row.to_group_id, row.to_user_id, row.action) })
      tuples.concat(event.event_requests.order(:id).map { |row| tuple('request', row, row.group_id, row.target_user_id, row.status) })
      tuples.concat(EventShareRequest.where(event_id: event.id).order(:id).map { |row| tuple('share_request', row, row.target_type, row.target_id, row.status) })
      tuples.concat(event.event_access_grants.order(:id).map { |row| tuple('grant', row, row.principal_type, row.principal_id, row.permission) })
      tuples.concat(event.event_reminders.order(:id).map { |row| tuple('reminder', row, row.user_id, row.remind_at&.iso8601(6), row.status) })
      if (room = event.chat_room)
        tuples << tuple('chat_room', room)
        tuples.concat(room.messages.order(:id).map { |row| tuple('chat_message', row, row.user_id) })
      end
      tuples.concat(AiRecommendation.where('source_event_id = :id OR created_event_id = :id', id: event.id).order(:id)
        .map { |row| tuple('ai_recommendation', row, row.source_event_id, row.created_event_id) })
      tuples.concat(AiContextAccessLog.where(event_id: event.id).order(:id).map { |row| tuple('ai_context_log', row) })
      tuples.concat(notification_rows(event).map { |row| tuple('notification', row, row.kind) })
      tuples.sort_by { |entry| JSON.generate(entry) }
    end

    def eligible?(event, user)
      return false unless event.created_by_id == user.id && event.parent_id.nil?
      return false unless event.start_at && event.end_at && event.end_at > event.start_at
      return false unless wire_representable?(event)
      return false if event.children.exists? || event.event_groups.exists? || event.event_access_grants.exists?
      return false if event.event_shares.exists? || event.event_requests.exists? || EventShareRequest.where(event_id: event.id).exists?
      return false if event.event_participants.where.not(user_id: user.id).exists?

      true
    end

    def wire_representable?(event)
      validate_event_text_fields!(event)
      true
    rescue SecretaryMutation::Contract::Invalid
      false
    end

    def pending_reminder?(event)
      event.event_reminders.pending.exists?
    end

    def notification_rows(event)
      Notification.where("payload ->> 'event_id' = ?", event.id.to_s).order(:id)
    end

    def delete_effects(event)
      reminder_counts = EventReminder.statuses.keys.to_h do |status|
        [status, event.event_reminders.public_send(status).count]
      end
      room = event.chat_room
      recommendation_count = AiRecommendation.where(source_event_id: event.id).count +
        AiRecommendation.where(created_event_id: event.id).count
      {
        'type' => 'event_delete',
        'self_participants_to_delete' => event.event_participants.count,
        'reminders_to_delete' => reminder_counts,
        'chat_rooms_to_delete' => room ? 1 : 0,
        'chat_messages_to_delete' => room ? room.messages.count : 0,
        'ai_recommendation_refs_to_nullify' => recommendation_count,
        'ai_context_log_refs_to_nullify' => AiContextAccessLog.where(event_id: event.id).count
      }
    end

    def executed_delete_effects(plan)
      {
        'type' => 'event_delete',
        'self_participants_deleted' => plan.fetch('self_participants_to_delete'),
        'reminders_deleted' => plan.fetch('reminders_to_delete'),
        'chat_rooms_deleted' => plan.fetch('chat_rooms_to_delete'),
        'chat_messages_deleted' => plan.fetch('chat_messages_to_delete'),
        'ai_recommendation_refs_nullified' => plan.fetch('ai_recommendation_refs_to_nullify'),
        'ai_context_log_refs_nullified' => plan.fetch('ai_context_log_refs_to_nullify')
      }
    end

    def rfc3339(time)
      time.iso8601(time.usec.zero? ? 0 : 6)
    end

    def validate_event_text_fields!(event)
      SecretaryMutation::Contract.event_title!(event.title)
      SecretaryMutation::Contract.description!(event.description) unless event.description.nil?
      SecretaryMutation::Contract.event_location!(event.location) unless event.location.nil?
    end
    private_class_method :validate_event_text_fields!

    def tuple(type, row, *values)
      [type, row.id, *values, row.updated_at&.utc&.iso8601(6)]
    end
    private_class_method :tuple
  end
end
