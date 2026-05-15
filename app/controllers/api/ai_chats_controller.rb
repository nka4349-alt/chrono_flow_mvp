# frozen_string_literal: true

module Api
  class AiChatsController < BaseController
    INTERNAL_RESPONSE_KEYS = %w[
      policy_run
      policy_runs
      tool_invocation
      tool_invocations
      provider
      policy_version
      request_kind
      ai_policy_run_id
      policy_run_id
      tool_invocation_count
      prompt_snapshot
      context_snapshot
      result_metadata
      input_payload
      output_payload
      raw_response
      debug
    ].freeze

    # GET /api/ai_chat?scope=home
    # GET /api/ai_chat?scope=group&group_id=:id
    def show
      conversation = find_conversation
      render json: conversation_payload(conversation)
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue StandardError => e
      json_error(e.message, status: (e.message == 'Forbidden' ? :forbidden : :unprocessable_entity))
    end

    # POST /api/ai_chat/messages
    def create_message
      body = params[:body].to_s.strip
      return json_error('入力内容を入れてください。', status: :bad_request) if body.blank?

      conversation = find_conversation
      Ai::GenerateReply.call(conversation: conversation, user: current_user, user_message: body)

      render json: conversation_payload(conversation.reload), status: :created
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: (e.message == 'Forbidden' ? :forbidden : :unprocessable_entity))
    end

    # POST /api/ai_chat/refresh
    def refresh
      conversation = find_conversation
      Ai::GenerateReply.call(conversation: conversation, user: current_user, refresh_only: true)

      render json: conversation_payload(conversation.reload)
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: (e.message == 'Forbidden' ? :forbidden : :unprocessable_entity))
    end

    private

    def find_conversation
      Ai::ConversationLocator.call(
        user: current_user,
        scope_type: params[:scope],
        group_id: params[:group_id]
      )
    end

    def conversation_payload(conversation)
      {
        conversation: {
          id: conversation.id,
          scope: conversation.scope_type,
          group_id: conversation.group_id,
          group_name: conversation.group&.name,
          last_used_at: conversation.last_used_at&.iso8601
        },
        messages: conversation.ai_messages.order(created_at: :desc, id: :desc).limit(20).to_a.reverse.map { |message| serialize_message(message) },
        recommendations: conversation.ai_recommendations.active_for_display.limit(10).map { |recommendation| serialize_recommendation(recommendation) }
      }
    end

    def serialize_message(message)
      {
        id: message.id,
        role: message.role,
        body: message.body,
        created_at: message.created_at&.iso8601,
        metadata: public_message_metadata(message.metadata || {})
      }
    end

    def public_message_metadata(_metadata)
      {}
    end

    def serialize_policy_run(policy_run)
      return nil unless policy_run

      {
        id: policy_run.id,
        provider: policy_run.provider,
        policy_version: policy_run.policy_version,
        request_kind: policy_run.request_kind,
        duration_ms: policy_run.duration_ms,
        scope: policy_run.scope_type,
        prompt_snapshot: policy_run.prompt_snapshot || {},
        context_snapshot: policy_run.context_snapshot || {},
        result_metadata: policy_run.result_metadata || {},
        created_at: policy_run.created_at&.iso8601
      }
    end

    def serialize_tool_invocation(tool_invocation)
      {
        id: tool_invocation.id,
        tool_name: tool_invocation.tool_name,
        status: tool_invocation.status,
        position: tool_invocation.position,
        duration_ms: tool_invocation.duration_ms,
        input_payload: tool_invocation.input_payload || {},
        output_payload: tool_invocation.output_payload || {},
        metadata: tool_invocation.metadata || {},
        created_at: tool_invocation.created_at&.iso8601
      }
    end

    def telemetry_tables_ready?
      ActiveRecord::Base.connection.data_source_exists?('ai_policy_runs') &&
        ActiveRecord::Base.connection.data_source_exists?('ai_tool_invocations')
    rescue StandardError
      false
    end

    def public_recommendation_payload(payload, recommendation = nil)
      sanitized = scrub_internal_response_keys(payload || {})
      if recommendation
        sanitized['all_day'] = normalized_recommendation_all_day(recommendation)
        sanitized['title'] = clean_recommendation_title(sanitized['title']) if sanitized['title'].present?
      end
      if sanitized['events'].is_a?(Array)
        sanitized['events'] = sanitized['events'].map do |event_payload|
          event_hash = event_payload.respond_to?(:to_h) ? event_payload.to_h.stringify_keys : {}
          event_hash['title'] = clean_recommendation_title(event_hash['title']) if event_hash['title'].present?
          event_hash['all_day'] = normalized_payload_all_day(event_hash)
          event_hash
        end
      end
      sanitized
    end

    def scrub_internal_response_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), sanitized|
          next if internal_response_key?(key)

          sanitized[key] = scrub_internal_response_keys(child)
        end
      when Array
        value.map { |child| scrub_internal_response_keys(child) }
      else
        value
      end
    end

    def internal_response_key?(key)
      INTERNAL_RESPONSE_KEYS.include?(key.to_s)
    end

    def serialize_recommendation(recommendation)
      all_day = normalized_recommendation_all_day(recommendation)
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
        group_id: recommendation.group_id,
        source_event_id: recommendation.source_event_id,
        payload: public_recommendation_payload(recommendation.payload || {}, recommendation),
        created_event_id: recommendation.created_event_id,
        created_at: recommendation.created_at&.iso8601
      }
    end

    def normalized_recommendation_all_day(recommendation)
      return false if timed_event_range?(recommendation.start_at, recommendation.end_at)

      ActiveModel::Type::Boolean.new.cast(recommendation.all_day)
    end

    def normalized_payload_all_day(payload)
      start_at = parse_time(payload['start_at'])
      end_at = parse_time(payload['end_at'])
      return false if timed_event_range?(start_at, end_at)

      ActiveModel::Type::Boolean.new.cast(payload['all_day'])
    end

    def timed_event_range?(start_at, end_at)
      return false if start_at.blank? || end_at.blank?

      start_midnight = start_at.hour.zero? && start_at.min.zero? && start_at.sec.zero?
      end_midnight = end_at.hour.zero? && end_at.min.zero? && end_at.sec.zero?
      !(start_midnight && end_midnight)
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def clean_recommendation_title(value)
      title = value.to_s.strip
      title = title.gsub(/\A(?:から|まで|以降|の間|間で|間に)+/, '')
      title = title.gsub(/\A(?:に|は|で|を|と|の|から)+/, '')
      title = title.gsub(/\A[\s、。,.，．・:：;；]+|[\s、。,.，．・:：;；]+\z/, '').strip
      title.presence || '候補イベント'
    end
  end
end
