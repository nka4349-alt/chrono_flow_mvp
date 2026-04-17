# frozen_string_literal: true

module Api
  class AiRecommendationsController < BaseController
    before_action :set_recommendation
    before_action :authorize_recommendation!

    # POST /api/ai_recommendations/:id/accept_copy
    def accept_copy
      return json_error('recommendation already processed', status: :unprocessable_entity) unless @recommendation.pending? || @recommendation.later?

      event = nil
      feedback = nil

      ActiveRecord::Base.transaction do
        event = build_event_from_recommendation!

        @recommendation.update!(status: :accepted_copy, created_event: event)
        feedback = @recommendation.ai_recommendation_feedbacks.create!(
          ai_conversation: @recommendation.ai_conversation,
          user: current_user,
          action: :accepted_copy,
          metadata: { created_event_id: event.id }
        )
        stamp_latest_impression!(interaction_label: 'accepted_copy', feedback: feedback)
      end

      render json: {
        ok: true,
        recommendation: serialize_recommendation(@recommendation.reload),
        event: serialize_event(event)
      }
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :unprocessable_entity)
    end

    # POST /api/ai_recommendations/:id/feedback
    def feedback
      return json_error('recommendation already processed', status: :unprocessable_entity) unless @recommendation.pending? || @recommendation.later?

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
      Event.new(
        title: payload['title'].presence || @recommendation.title,
        description: payload['description'].presence || @recommendation.description,
        start_at: parse_time(payload['start_at']) || @recommendation.start_at,
        end_at: parse_time(payload['end_at']) || @recommendation.end_at,
        all_day: ActiveModel::Type::Boolean.new.cast(payload.key?('all_day') ? payload['all_day'] : @recommendation.all_day),
        location: payload['location'],
        color: normalize_event_color(payload['color'])
      )
    end


    def normalize_event_color(value)
      color = value.to_s.downcase
      return '#3b82f6' if color.blank?
      return color if Event::COLOR_PALETTE.include?(color)

      '#3b82f6'
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def serialize_recommendation(recommendation)
      {
        id: recommendation.id,
        kind: recommendation.kind,
        status: recommendation.status,
        title: recommendation.title,
        description: recommendation.description,
        reason: recommendation.reason,
        start_at: recommendation.start_at&.iso8601,
        end_at: recommendation.end_at&.iso8601,
        all_day: recommendation.all_day,
        source_event_id: recommendation.source_event_id,
        created_event_id: recommendation.created_event_id,
        payload: recommendation.payload || {}
      }
    end

    def serialize_event(event)
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
  end
end
