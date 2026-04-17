# frozen_string_literal: true

require 'json'

module Ai
  class GenerateReply
    MAX_RECOMMENDATIONS = 3
    TELEMETRY_TABLES = %w[ai_policy_runs ai_tool_invocations ai_recommendation_impressions].freeze

    BUSINESS_STRONG_KEYWORDS = %w[
      会議 ミーティング meeting mtg 打ち合わせ 打合せ レビュー レビュー会 合議 稟議 キックオフ 定例 1on1 面談 商談
    ].freeze
    BUSINESS_SOFT_KEYWORDS = %w[
      相談 調整 確認 すり合わせ 整理 進捗 フォロー 再確認
    ].freeze
    FAMILY_KEYWORDS = %w[
      家族 実家 親 母 父 お母さん お父さん 子ども 子供 娘 息子 夫 妻 パートナー
      送り迎え 通院 付き添い
    ].freeze
    FRIEND_KEYWORDS = %w[
      友達 友人 同級生 親友 サークル 飲み ご飯 ごはん ランチ ディナー 食事 遊び 約束
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(conversation:, user:, user_message: nil, refresh_only: false)
      @conversation = conversation
      @user = user
      @user_message = user_message.to_s.strip
      @refresh_only = refresh_only
    end

    def call
      context = Ai::ContextBuilder.call(user: @user, conversation: @conversation)
      response = Ai::Client.call(context: context, user_message: @user_message, refresh_only: @refresh_only)
      response = guard_home_business_intent_response(response, context)

      persist_response!(response, context: context)
    end

    private

    def guard_home_business_intent_response(response, context)
      return response unless home_business_intent_priority?(context)

      filtered = Array(response[:recommendations]).reject { |raw| social_recommendation?(raw) }
      return response if filtered.length == Array(response[:recommendations]).length

      response.merge(
        recommendations: filtered,
        assistant_message: filtered.any? ? response[:assistant_message] : business_fallback_message(response[:assistant_message])
      )
    end

    def home_business_intent_priority?(context)
      return false unless @conversation.scope_type.to_s == 'home'
      return false if @refresh_only

      normalized = normalize_text(@user_message)
      return false if normalized.blank?
      return false if explicit_social_signal?(normalized, context)

      business_signal_level(normalized).positive?
    end

    def social_recommendation?(raw)
      attrs = normalized_hash(raw)
      payload = normalized_hash(attrs['payload'])
      category = payload['category'].to_s
      intent = payload['intent'].to_s
      relation_tags = Array(payload['relation_tags']).map(&:to_s)
      hay = [
        attrs['title'],
        attrs['description'],
        attrs['reason'],
        category,
        intent,
        *relation_tags
      ].join(' ')

      category.in?(%w[family friend]) ||
        intent.in?(%w[family_plan friend_meetup]) ||
        relation_tags.any? { |tag| tag.in?(%w[family friend]) } ||
        contains_any?(normalize_text(hay), FAMILY_KEYWORDS + FRIEND_KEYWORDS)
    end

    def business_fallback_message(original_message)
      return original_message if original_message.present? && !contains_any?(normalize_text(original_message), FRIEND_KEYWORDS + FAMILY_KEYWORDS)

      '今の予定の空きに合わせて、会議や打ち合わせ向けの候補を優先して再調整しました。'
    end

    def explicit_social_signal?(text, context)
      return true if contains_any?(text, FAMILY_KEYWORDS + FRIEND_KEYWORDS)

      Array(context[:contacts]).any? do |contact|
        next false unless %w[family parent child partner friend].include?(contact[:relation_type].to_s)

        name = normalize_text(contact[:display_name].to_s)
        name.present? && text.include?(name)
      end
    end

    def business_signal_level(text)
      return 2 if contains_any?(text, BUSINESS_STRONG_KEYWORDS)
      return 1 if contains_any?(text, BUSINESS_SOFT_KEYWORDS)

      0
    end

    def contains_any?(text, keywords)
      keywords.any? do |keyword|
        normalized_keyword = normalize_text(keyword)
        normalized_keyword.present? && text.include?(normalized_keyword)
      end
    end

    def normalize_text(text)
      text.to_s.unicode_normalize(:nfkc).downcase.strip
    rescue StandardError
      text.to_s.downcase.strip
    end

    def persist_response!(response, context:)
      assistant_body = response[:assistant_message].to_s.strip
      assistant_body = '今すぐ確度の高い候補は見つかりませんでした。' if assistant_body.blank?
      provider = response[:provider].presence || 'rules-v4-work-intent'

      ActiveRecord::Base.transaction do
        @conversation.ai_messages.create!(role: :user, body: @user_message) if @user_message.present?

        archive_existing_recommendations!

        policy_run = telemetry_tables_ready? ? @conversation.ai_policy_runs.create!(build_policy_run_attrs(response, context, assistant_body, provider)) : nil

        metadata = { provider: provider }
        if policy_run
          metadata.merge!(
            policy_version: policy_run.policy_version,
            request_kind: policy_run.request_kind,
            ai_policy_run_id: policy_run.id,
            tool_invocation_count: Array(response[:tool_invocations]).size
          )
        end

        @conversation.ai_messages.create!(
          role: :assistant,
          body: assistant_body,
          metadata: metadata
        )

        persist_tool_invocations!(policy_run, response[:tool_invocations]) if policy_run

        Array(response[:recommendations]).first(MAX_RECOMMENDATIONS).each_with_index do |raw, index|
          attrs = normalized_hash(raw)
          recommendation = @conversation.ai_recommendations.create!(
            user: @user,
            group: @conversation.group,
            kind: attrs['kind'].presence || 'draft_event',
            title: attrs['title'].presence || '候補イベント',
            description: attrs['description'],
            reason: attrs['reason'],
            start_at: parse_time(attrs['start_at']),
            end_at: parse_time(attrs['end_at']),
            all_day: ActiveModel::Type::Boolean.new.cast(attrs['all_day']),
            source_event_id: attrs['source_event_id'],
            payload: normalize_payload(attrs)
          )

          persist_recommendation_impression!(
            policy_run: policy_run,
            recommendation: recommendation,
            raw_attrs: attrs,
            rank_index: index + 1
          ) if policy_run
        end

        @conversation.touch(:last_used_at)
      end

      @conversation.reload
    end

    def archive_existing_recommendations!
      @conversation.ai_recommendations.where(status: AiRecommendation.statuses[:pending]).update_all(
        status: AiRecommendation.statuses[:archived],
        updated_at: Time.current
      )
    end

    def build_policy_run_attrs(response, context, assistant_body, provider)
      raw_policy_run = normalized_hash(response[:policy_run])
      {
        user: @user,
        group: @conversation.group,
        scope_type: @conversation.scope_type,
        provider: raw_policy_run['provider'].presence || provider,
        policy_version: raw_policy_run['policy_version'].presence || provider,
        request_kind: normalize_request_kind(raw_policy_run['request_kind']),
        duration_ms: safe_integer(raw_policy_run['duration_ms']),
        user_message: @user_message.presence,
        assistant_message: assistant_body,
        prompt_snapshot: json_hash(default_prompt_snapshot(context).merge(json_hash(raw_policy_run['prompt_snapshot']))),
        context_snapshot: json_hash(default_context_snapshot(context).merge(json_hash(raw_policy_run['context_snapshot']))),
        result_metadata: json_hash(default_result_metadata(response, assistant_body).merge(json_hash(raw_policy_run['result_metadata'])))
      }
    end

    def default_prompt_snapshot(context)
      {
        'scope' => @conversation.scope_type,
        'refresh_only' => @refresh_only,
        'user_message' => @user_message,
        'group_id' => @conversation.group_id,
        'group_name' => @conversation.group&.name,
        'contact_count' => Array(context[:contacts]).size,
        'friend_count' => Array(context[:friends]).size
      }.compact
    end

    def default_context_snapshot(context)
      {
        'scope' => context[:scope],
        'timezone' => context[:timezone],
        'now' => context[:now],
        'group' => json_hash(context[:group]),
        'personal_event_count' => Array(context[:personal_events]).size,
        'candidate_group_event_count' => Array(context[:candidate_group_events]).size,
        'recent_group_message_count' => Array(context[:recent_group_messages]).size,
        'recent_direct_message_count' => Array(context[:recent_direct_messages]).size,
        'friend_count' => Array(context[:friends]).size,
        'contact_count' => Array(context[:contacts]).size
      }.compact
    end

    def default_result_metadata(response, assistant_body)
      recommendations = Array(response[:recommendations])
      {
        'assistant_message' => assistant_body,
        'recommendation_count' => recommendations.size,
        'recommendation_kind_counts' => recommendations.each_with_object(Hash.new(0)) do |raw, counts|
          kind = normalized_hash(raw)['kind'].presence || 'draft_event'
          counts[kind] += 1
        end,
        'tool_invocation_count' => Array(response[:tool_invocations]).size,
        'provider' => response[:provider].presence || 'rules-v4-work-intent'
      }
    end

    def persist_tool_invocations!(policy_run, raw_tool_invocations)
      Array(raw_tool_invocations).each_with_index do |raw, index|
        attrs = normalized_hash(raw)
        policy_run.ai_tool_invocations.create!(
          ai_conversation: @conversation,
          user: @user,
          tool_name: attrs['tool_name'].presence || attrs['name'].presence || "tool_#{index + 1}",
          status: attrs['status'].presence || 'success',
          position: safe_integer(attrs['position']) || index + 1,
          duration_ms: safe_integer(attrs['duration_ms']),
          input_payload: json_hash(attrs['input_payload'] || attrs['input']),
          output_payload: json_hash(attrs['output_payload'] || attrs['output']),
          metadata: json_hash(attrs['metadata'])
        )
      end
    end

    def persist_recommendation_impression!(policy_run:, recommendation:, raw_attrs:, rank_index:)
      payload = normalize_payload(raw_attrs)

      policy_run.ai_recommendation_impressions.create!(
        ai_conversation: @conversation,
        ai_recommendation: recommendation,
        user: @user,
        group: @conversation.group,
        rank_position: safe_integer(payload['rank_position']) || rank_index,
        kind: recommendation.kind,
        recommendation_status: recommendation.status,
        title: recommendation.title,
        start_at: recommendation.start_at,
        end_at: recommendation.end_at,
        payload_snapshot: payload,
        features: build_ranking_features(recommendation, payload),
        metadata: {
          provider: policy_run.provider,
          policy_version: policy_run.policy_version,
          request_kind: policy_run.request_kind
        }
      )
    end

    def build_ranking_features(recommendation, payload)
      start_at = recommendation.start_at
      end_at = recommendation.end_at
      duration_minutes = if start_at.present? && end_at.present?
                           ((end_at - start_at) / 60).round
                         end

      {
        'kind' => recommendation.kind,
        'category' => payload['category'],
        'intent' => payload['intent'],
        'schedule_profile' => payload['schedule_profile'],
        'score' => safe_float(payload['score']),
        'rank_position' => safe_integer(payload['rank_position']),
        'all_day' => recommendation.all_day,
        'start_hour' => start_at&.hour,
        'weekday' => start_at&.wday,
        'duration_minutes' => duration_minutes,
        'contact_id' => payload['contact_id'],
        'contact_name' => payload['contact_name'],
        'contact_relation_type' => payload['contact_relation_type'],
        'friend_name' => payload['friend_name'],
        'source_event_id' => recommendation.source_event_id,
        'relation_tags' => Array(payload['relation_tags']).map(&:to_s),
        'source_group_names' => Array(payload['source_group_names']).map(&:to_s)
      }.compact
    end

    def normalize_request_kind(value)
      kind = value.to_s
      return kind if AiPolicyRun::REQUEST_KINDS.include?(kind)

      @refresh_only ? 'refresh_only' : 'chat_message'
    end

    def normalize_payload(attrs)
      payload = json_hash(attrs['payload'])
      payload['title'] ||= attrs['title']
      payload['description'] ||= attrs['description']
      payload['start_at'] ||= attrs['start_at']
      payload['end_at'] ||= attrs['end_at']
      payload['all_day'] = ActiveModel::Type::Boolean.new.cast(attrs['all_day']) if attrs.key?('all_day')
      payload['source_event_id'] ||= attrs['source_event_id'] if attrs['source_event_id'].present?
      payload['location'] ||= attrs['location'] if attrs['location'].present?

      raw_color = payload['color'].presence || attrs['color'].presence
      payload['color'] = normalize_event_color(raw_color) if raw_color.present?

      payload
    end

    def normalize_event_color(value)
      color = value.to_s.downcase
      return '#3b82f6' if color.blank?
      return color if Event::COLOR_PALETTE.include?(color)

      '#3b82f6'
    end

    def normalized_hash(value)
      hash = value.respond_to?(:to_h) ? value.to_h : {}
      hash.deep_stringify_keys
    rescue StandardError
      {}
    end

    def json_hash(value)
      raw = value.respond_to?(:to_h) ? value.to_h : value
      return {} if raw.blank?

      JSON.parse(JSON.generate(raw))
    rescue StandardError
      {}
    end

    def safe_integer(value)
      Integer(value)
    rescue StandardError
      nil
    end

    def safe_float(value)
      Float(value)
    rescue StandardError
      nil
    end

    def telemetry_tables_ready?
      TELEMETRY_TABLES.all? { |table_name| ActiveRecord::Base.connection.data_source_exists?(table_name) }
    rescue StandardError
      false
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
