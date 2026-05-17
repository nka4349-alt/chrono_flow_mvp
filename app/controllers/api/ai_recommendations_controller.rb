# frozen_string_literal: true

module Api
  class AiRecommendationsController < BaseController
    before_action :set_recommendation
    before_action :authorize_recommendation!

    # POST /api/ai_recommendations/:id/accept_copy
    def accept_copy
      return render(json: { ok: true, recommendation: serialize_recommendation(@recommendation) }) unless @recommendation.pending? || @recommendation.later?

      events = []
      event = nil
      feedback = nil

      reminder = nil

      ActiveRecord::Base.transaction do
        if @recommendation.event_update?
          event = apply_event_update_from_recommendation!
          events = [event].compact
        elsif @recommendation.event_delete?
          event = apply_event_delete_from_recommendation!
          events = []
        elsif @recommendation.event_reminder?
          reminder = apply_event_reminder_from_recommendation!
          event = reminder&.event
          events = []
        else
          events = build_events_from_recommendation!
          event = events.first
        end

        @recommendation.update!(status: :accepted_copy, created_event: event)
        feedback = @recommendation.ai_recommendation_feedbacks.create!(
          ai_conversation: @recommendation.ai_conversation,
          user: current_user,
          action: :accepted_copy,
          metadata: {
            created_event_id: event&.id,
            created_event_ids: events.map(&:id),
            reminder_id: reminder&.id,
            recommendation_kind: @recommendation.kind
          }.compact
        )
        stamp_latest_impression!(interaction_label: 'accepted_copy', feedback: feedback)
      end

      render json: {
        ok: true,
        recommendation: serialize_recommendation(@recommendation.reload),
        event: serialize_event(event),
        events: events.map { |ev| serialize_event(ev) },
        reminder: serialize_reminder(reminder)
      }
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :unprocessable_entity)
    end

    # POST /api/ai_recommendations/:id/feedback
    def feedback
      return render(json: { ok: true, recommendation: serialize_recommendation(@recommendation) }) unless @recommendation.pending? || @recommendation.later?

      feedback_action = normalized_feedback_action
      feedback_status = feedback_status_for(feedback_action)

      return json_error('invalid action', status: :bad_request) unless feedback_action && feedback_status

      feedback = nil

      ActiveRecord::Base.transaction do
        @recommendation.update!(status: feedback_status)
        feedback = @recommendation.ai_recommendation_feedbacks.create!(
          ai_conversation: @recommendation.ai_conversation,
          user: current_user,
          action: feedback_action,
          metadata: {
            source: 'ui',
            requested_feedback_action: feedback_action,
            resulting_status: feedback_status
          }
        )
        stamp_latest_impression!(interaction_label: feedback_action, feedback: feedback)
      end

      render json: { ok: true, recommendation: serialize_recommendation(@recommendation.reload) }
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :unprocessable_entity)
    end

    private

    def set_recommendation
      @recommendation = AiRecommendation.find(params[:id])
    end

    def authorize_recommendation!
      return if @recommendation.user_id.to_i == current_user.id.to_i

      json_error('Forbidden', status: :forbidden)
    end

    def normalized_feedback_action
      raw_value = [
        params[:feedback_action],
        params[:recommendation_action],
        params[:status],
        request_payload['feedback_action'],
        request_payload['recommendation_action'],
        request_payload['status'],
        request_payload['action']
      ].find { |value| value.to_s.strip.present? }

      case raw_value.to_s.strip
      when 'later', 'snooze'
        'later'
      when 'dismiss', 'dismissed', 'not_interested', 'no_interest'
        'dismissed'
      else
        nil
      end
    end

    def feedback_status_for(feedback_action)
      case feedback_action.to_s
      when 'later' then :later
      when 'dismissed' then :dismissed
      else nil
      end
    end

    def request_payload
      @request_payload ||= begin
        payload = request.request_parameters
        payload.is_a?(Hash) ? payload : {}
      rescue StandardError
        {}
      end
    end

    def stamp_latest_impression!(interaction_label:, feedback: nil)
      return unless telemetry_tables_ready?

      impression = @recommendation.ai_recommendation_impressions.recent_first.first
      return unless impression

      impression.update!(
        interaction_label: interaction_label,
        interacted_at: Time.current,
        recommendation_status: @recommendation.status,
        metadata: (impression.metadata || {}).merge(
          'feedback_id' => feedback&.id,
          'feedback_action' => interaction_label,
          'recommendation_status_after_feedback' => @recommendation.status,
          'updated_via' => action_name
        )
      )
    end

    def telemetry_tables_ready?
      ActiveRecord::Base.connection.data_source_exists?('ai_recommendation_impressions')
    rescue StandardError
      false
    end

    def apply_event_update_from_recommendation!
      payload = (@recommendation.payload || {}).to_h.stringify_keys
      source_event = editable_source_event!(payload['source_event_id'] || @recommendation.source_event_id)
      updates = payload['updates'].respond_to?(:to_h) ? payload['updates'].to_h.stringify_keys : {}

      attrs = {}
      attrs[:start_at] = parse_time(updates['start_at']) if updates['start_at'].present?
      attrs[:end_at] = parse_time(updates['end_at']) if updates['end_at'].present?
      attrs[:all_day] = normalize_recommendation_all_day(updates['all_day'], attrs[:start_at] || source_event.start_at, attrs[:end_at] || source_event.end_at) if updates.key?('all_day')
      attrs[:title] = clean_recommendation_title(updates['title']) if updates['title'].present?
      attrs[:description] = updates['description'] if updates.key?('description')
      attrs[:location] = updates['location'] if Event.column_names.include?('location') && updates.key?('location')
      attrs[:color] = normalize_event_color(updates['color']) if Event.column_names.include?('color') && updates['color'].present?

      raise ActiveRecord::RecordInvalid, source_event if attrs.empty?

      source_event.update!(attrs)
      source_event
    end

    def apply_event_delete_from_recommendation!
      payload = (@recommendation.payload || {}).to_h.stringify_keys
      source_event = editable_source_event!(payload['source_event_id'] || @recommendation.source_event_id)
      source_event.destroy!
      nil
    end

    def apply_event_reminder_from_recommendation!
      payload = (@recommendation.payload || {}).to_h.stringify_keys
      raise 'EventReminder is not available' unless defined?(EventReminder)

      source_event = visible_source_event!(payload['source_event_id'] || @recommendation.source_event_id)
      remind_at = parse_time(payload['remind_at'])
      minutes_before = payload['minutes_before'].to_i
      minutes_before = 30 if minutes_before <= 0
      remind_at ||= source_event.start_at - minutes_before.minutes

      EventReminder.find_or_initialize_by(user: current_user, event: source_event, remind_at: remind_at).tap do |reminder|
        reminder.minutes_before = minutes_before
        reminder.status = :pending if reminder.respond_to?(:status=) && reminder.status.blank?
        reminder.payload = (reminder.payload || {}).merge(
          'source' => 'ai_recommendation',
          'ai_recommendation_id' => @recommendation.id,
          'event_title' => source_event.title
        )
        reminder.save!
      end
    end

    def editable_source_event!(event_id)
      event = visible_source_event!(event_id)
      return event if event.created_by_id.to_i == current_user.id.to_i
      return event if defined?(EventParticipant) && EventParticipant.exists?(event_id: event.id, user_id: current_user.id)

      raise 'Forbidden'
    end

    def visible_source_event!(event_id)
      event = Event.find(event_id)
      return event if event.created_by_id.to_i == current_user.id.to_i
      return event if defined?(EventParticipant) && EventParticipant.exists?(event_id: event.id, user_id: current_user.id)

      raise 'Forbidden'
    end

    def build_events_from_recommendation!
      payload = (@recommendation.payload || {}).to_h.stringify_keys
      raw_events = Array(payload['events']).select { |value| value.respond_to?(:to_h) }

      return [build_event_from_recommendation!] if raw_events.empty?

      raw_events.map do |raw_event|
        event_payload = payload.merge(raw_event.to_h.stringify_keys)
        event = event_from_payload(event_payload)
        event.created_by = current_user
        event.save!

        EventParticipant.find_or_create_by!(event_id: event.id, user_id: current_user.id) do |participant|
          participant.source = :copied
        end

        event
      end
    end

    def build_event_from_recommendation!
      event = if @recommendation.group_event_copy? && @recommendation.source_event.present?
                duplicate_event(@recommendation.source_event)
              else
                event_from_payload(@recommendation.payload.to_h.stringify_keys)
              end

      event.created_by = current_user
      event.save!
      EventParticipant.find_or_create_by!(event_id: event.id, user_id: current_user.id) do |participant|
        participant.source = :copied
      end
      event
    end

    def duplicate_event(source)
      Event.new(
        title: source.title,
        description: source.try(:description),
        start_at: source.start_at,
        end_at: source.end_at,
        all_day: !!source.try(:all_day),
        event_type_id: source.try(:event_type_id),
        parent_id: source.try(:parent_id),
        location: source.try(:location),
        color: normalize_event_color(source.try(:color))
      )
    end

    def event_from_payload(payload)
      start_at = parse_time(payload['start_at']) || @recommendation.start_at
      end_at = parse_time(payload['end_at']) || @recommendation.end_at
      raw_all_day = payload.key?('all_day') ? payload['all_day'] : @recommendation.all_day
      all_day = normalize_recommendation_all_day(raw_all_day, start_at, end_at)

      Event.new(
        title: clean_recommendation_title(payload['title'].presence || @recommendation.title),
        description: payload['description'].presence || @recommendation.description,
        start_at: start_at,
        end_at: end_at,
        all_day: all_day,
        location: payload['location'],
        color: normalize_event_color(payload['color'])
      )
    end

    def normalize_recommendation_all_day(value, start_at, end_at)
      all_day = ActiveModel::Type::Boolean.new.cast(value)
      return false if all_day && timed_event_range?(start_at, end_at)

      all_day
    end

    def timed_event_range?(start_at, end_at)
      return false if start_at.blank? || end_at.blank?

      start_is_midnight = start_at.hour.zero? && start_at.min.zero? && start_at.sec.zero?
      end_is_midnight = end_at.hour.zero? && end_at.min.zero? && end_at.sec.zero?

      !(start_is_midnight && end_is_midnight)
    end


    def normalize_event_color(value)
      color = value.to_s.downcase
      return '#3b82f6' if color.blank?
      return color if Event::COLOR_PALETTE.include?(color)

      '#3b82f6'
    end

    def clean_recommendation_title(value)
      title = value.to_s.strip
      title = title.gsub(/\A(?:から|まで|以降|の間|間で|間に)+/, '')
      title = title.gsub(/\A(?:に|は|で|を|と|の|から)+/, '')
      title = title.gsub(/\A[\s、。,.，．・:：;；]+|[\s、。,.，．・:：;；]+\z/, '').strip
      title.presence || '候補イベント'
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def serialize_recommendation(recommendation)
      all_day = normalize_recommendation_all_day(recommendation.all_day, recommendation.start_at, recommendation.end_at)
      payload = (recommendation.payload || {}).to_h.stringify_keys
      payload['title'] = clean_recommendation_title(payload['title']) if payload['title'].present?
      payload['all_day'] = all_day
      if payload['events'].is_a?(Array)
        payload['events'] = payload['events'].map do |event_payload|
          event_hash = event_payload.respond_to?(:to_h) ? event_payload.to_h.stringify_keys : {}
          event_hash['title'] = clean_recommendation_title(event_hash['title']) if event_hash['title'].present?
          event_hash['all_day'] = normalize_recommendation_all_day(event_hash['all_day'], parse_time(event_hash['start_at']), parse_time(event_hash['end_at']))
          event_hash
        end
      end

      {
        id: recommendation.id,
        kind: recommendation.kind,
        status: recommendation.status,
        title: clean_recommendation_title(recommendation.title),
        description: recommendation.description,
        reason: recommendation.reason,
        start_at: recommendation.start_at&.iso8601,
        end_at: recommendation.end_at&.iso8601,
        all_day: all_day,
        source_event_id: recommendation.source_event_id,
        created_event_id: recommendation.created_event_id,
        payload: payload
      }
    end

    def serialize_event(event)
      return nil unless event

      {
        id: event.id,
        title: event.title,
        start_at: event.start_at&.iso8601,
        end_at: event.end_at&.iso8601,
        all_day: !!event.try(:all_day),
        description: event.try(:description),
        location: event.try(:location),
        color: event.try(:color)
      }
    end

    def serialize_reminder(reminder)
      return nil unless reminder

      {
        id: reminder.id,
        event_id: reminder.event_id,
        remind_at: reminder.remind_at&.iso8601,
        minutes_before: reminder.minutes_before,
        status: reminder.status
      }
    end
  end
end
