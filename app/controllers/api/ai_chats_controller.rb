# frozen_string_literal: true

module Api
  class AiChatsController < BaseController
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
      return json_error('body is required', status: :bad_request) if body.blank?

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
      latest_policy_run = telemetry_tables_ready? ? conversation.ai_policy_runs.includes(:ai_tool_invocations).recent_first.first : nil

      {
        conversation: {
          id: conversation.id,
          scope: conversation.scope_type,
          group_id: conversation.group_id,
          group_name: conversation.group&.name,
          last_used_at: conversation.last_used_at&.iso8601
        },
        policy_run: serialize_policy_run(latest_policy_run),
        tool_invocations: latest_policy_run ? latest_policy_run.ai_tool_invocations.ordered.map { |tool| serialize_tool_invocation(tool) } : [],
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
        metadata: message.metadata || {}
      }
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
        group_id: recommendation.group_id,
        source_event_id: recommendation.source_event_id,
        payload: recommendation.payload || {},
        created_event_id: recommendation.created_event_id,
        created_at: recommendation.created_at&.iso8601
      }
    end
  end
end
