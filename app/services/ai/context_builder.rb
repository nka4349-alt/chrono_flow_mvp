# frozen_string_literal: true

require 'securerandom'

module Ai
  class ContextBuilder
    LOOKAHEAD_DAYS = 14
    MESSAGE_LIMIT = 12
    GROUP_CHAT_LIMIT = 20
    GROUP_EVENT_LIMIT = 12
    FRIEND_LIMIT = 20
    DIRECT_MESSAGE_LIMIT = 12
    CONTACT_LIMIT = 24
    RANKING_IMPRESSION_LIMIT = 200

    def self.call(...)
      new(...).call
    end

    def initialize(user:, conversation:)
      @user = user
      @conversation = conversation
      @now = Time.current
    end

    def call
      personal_events = personal_events_payload
      group_events = candidate_group_events_payload
      peer_events = peer_events_payload
      context_permissions = context_permissions_payload(personal_events, group_events, peer_events)
      context_visibility.flush_access_logs!(request_id: ai_context_request_id)

      {
        request_id: ai_context_request_id,
        scope: conversation.scope_type,
        now: @now.iso8601,
        timezone: app_timezone,
        user: {
          id: user.id,
          name: user.respond_to?(:display_name) ? user.display_name : (user.name.presence || user.email)
        },
        group: group_payload,
        conversation: {
          id: conversation.id,
          recent_messages: ai_recent_messages_payload
        },
        ai_context_mode: context_visibility.mode,
        context_permissions: context_permissions,
        personal_events: personal_events,
        candidate_group_events: group_events,
        recent_group_messages: recent_group_messages_payload,
        friends: friends_payload,
        contacts: contacts_payload,
        recent_direct_messages: recent_direct_messages_payload,
        peer_events: peer_events,
        ranking_history: ranking_history_payload
      }
    end

    private

    attr_reader :user, :conversation

    def app_timezone
      configured = ENV['APP_TIMEZONE'].presence
      return configured if configured.present?

      tzinfo_name = Time.zone.tzinfo.name rescue nil
      return 'Asia/Tokyo' if tzinfo_name.blank? || %w[UTC Etc/UTC].include?(tzinfo_name)

      tzinfo_name
    end

    def group_payload
      return nil unless conversation.group

      {
        id: conversation.group.id,
        name: conversation.group.name
      }
    end

    def ai_recent_messages_payload
      conversation.ai_messages.order(created_at: :desc, id: :desc).limit(MESSAGE_LIMIT).to_a.reverse.map do |message|
        {
          id: message.id,
          role: message.role,
          body: message.body,
          created_at: message.created_at&.iso8601
        }
      end
    end

    def recent_group_messages_payload
      return [] unless conversation.group

      room = ChatRoom.find_by(chatable: conversation.group)
      return [] unless room

      room.messages.includes(:user).order(created_at: :desc).limit(GROUP_CHAT_LIMIT).to_a.reverse.map do |message|
        {
          id: message.id,
          body: message.body,
          created_at: message.created_at&.iso8601,
          user_id: message.user_id,
          user_name: message.user&.respond_to?(:display_name) ? message.user.display_name : (message.user&.name.presence || message.user&.email || 'user')
        }
      end
    end

    def friends_payload
      return [] unless defined?(Friendship)

      Friendship.for_user(user.id).includes(:user, :friend).limit(FRIEND_LIMIT).map do |friendship|
        peer = friendship.peer_for(user)
        next unless peer

        {
          id: peer.id,
          name: peer.respond_to?(:display_name) ? peer.display_name : (peer.name.presence || peer.email),
          email: peer.email
        }
      end.compact.sort_by { |item| [item[:name].to_s.downcase, item[:id].to_i] }
    end

    def contacts_payload
      return [] unless defined?(Contact)
      return [] unless ActiveRecord::Base.connection.data_source_exists?('contacts')

      user.contacts
          .includes(:linked_user, :availability_profiles)
          .active
          .ordered
          .limit(CONTACT_LIMIT)
          .map do |contact|
        {
          id: contact.id,
          display_name: contact.display_name,
          relation_type: contact.relation_type,
          relation_label: contact.relation_label,
          source_kind: contact.source_kind,
          linked_user_id: contact.linked_user_id,
          linked_user_name: contact.linked_user&.respond_to?(:display_name) ? contact.linked_user&.display_name : (contact.linked_user&.name.presence || contact.linked_user&.email),
          linked_user_email: contact.linked_user&.email,
          preferred_duration_minutes: contact.preferred_duration_minutes,
          timezone: contact.display_timezone,
          notes: contact.notes.to_s,
          availability_profiles: contact.availability_profiles.active.ordered.map do |profile|
            {
              id: profile.id,
              weekday: profile.weekday,
              weekday_label: profile.day_label,
              start_minute: profile.start_minute,
              end_minute: profile.end_minute,
              start_hhmm: profile.start_hhmm,
              end_hhmm: profile.end_hhmm,
              preference_kind: profile.preference_kind,
              source_kind: profile.source_kind,
              notes: profile.notes.to_s
            }
          end
        }
      end
    end

    def recent_direct_messages_payload
      return [] unless defined?(DirectChat)

      chats = DirectChat.where('user_a_id = :uid OR user_b_id = :uid', uid: user.id).includes(chat_room: { messages: :user }).limit(8)
      messages = []

      chats.each do |chat|
        peer = chat.peer_for(user)
        room = chat.chat_room
        next unless peer && room

        room.messages.order(created_at: :desc).limit(4).to_a.reverse.each do |message|
          messages << {
            id: message.id,
            body: message.body,
            created_at: message.created_at&.iso8601,
            user_id: message.user_id,
            user_name: message.user&.respond_to?(:display_name) ? message.user.display_name : (message.user&.name.presence || message.user&.email || 'user'),
            peer_id: peer.id,
            peer_name: peer.respond_to?(:display_name) ? peer.display_name : (peer.name.presence || peer.email),
            peer_email: peer.email
          }
        end
      end

      messages.sort_by { |item| item[:created_at].to_s }.last(DIRECT_MESSAGE_LIMIT)
    end

    def context_visibility
      @context_visibility ||= Ai::ContextVisibility.new(user: user, conversation: conversation, now: @now)
    end

    def ai_context_request_id
      @ai_context_request_id ||= SecureRandom.uuid
    end

    def personal_events_payload
      home_events_scope.limit(24).to_a.filter_map do |event|
        context_visibility.payload_for(event, source_type: 'personal_event')
      end
    end

    def candidate_group_events_payload
      candidate_group_events.to_a.filter_map do |event|
        context_visibility.payload_for(event, source_type: 'group_event')
      end
    end

    def context_permissions_payload(personal_events, group_events, peer_events)
      payloads = Array(personal_events) + Array(group_events) + Array(peer_events)
      permission_counts = payloads.each_with_object(Hash.new(0)) do |payload, counts|
        counts[payload[:context_permission].to_s] += 1
      end
      masked_count = payloads.count { |payload| payload[:masked] }

      {
        mode: context_visibility.mode,
        permission_counts: permission_counts.to_h,
        masked_count: masked_count,
        detail_count: permission_counts['detail'].to_i,
        title_time_count: permission_counts['title_time'].to_i,
        free_busy_count: permission_counts['free_busy'].to_i,
        peer_event_count: Array(peer_events).size
      }
    end

    def group_scope?
      conversation.scope_type.to_s == 'group' && conversation.group_id.present?
    end

    def ranking_history_payload
      return {} unless defined?(AiRecommendationImpression)
      return {} unless ActiveRecord::Base.connection.data_source_exists?('ai_recommendation_impressions')

      impressions = user.ai_recommendation_impressions
                        .recent_first
                        .limit(RANKING_IMPRESSION_LIMIT)

      impressions = if conversation.group_id.present?
                      impressions.where(group_id: conversation.group_id)
                    else
                      impressions.where(group_id: nil)
                    end

      rows = impressions.to_a
      return {} if rows.empty?

      feature_stats = Hash.new { |hash, key| hash[key] = {} }
      label_counts = Hash.new(0)
      interacted_size = 0

      rows.each do |impression|
        features = normalize_json_hash(impression.features)
        values = ranker_feature_values(impression, features)

        values.each do |feature_name, feature_value|
          next if feature_value.blank?

          feature_stats[feature_name][feature_value] ||= {
            'shown_count' => 0,
            'interacted_count' => 0,
            'reward_sum' => 0.0,
            'accepted_count' => 0,
            'later_count' => 0,
            'dismissed_count' => 0
          }
          feature_stats[feature_name][feature_value]['shown_count'] += 1
        end

        label = impression.interaction_label.to_s
        next if label.blank?

        reward = ranking_reward(label)
        interacted_size += 1
        label_counts[label] += 1

        values.each do |feature_name, feature_value|
          next if feature_value.blank?

          stats = feature_stats[feature_name][feature_value]
          stats['interacted_count'] += 1
          stats['reward_sum'] = (stats['reward_sum'].to_f + reward).round(4)
          stats['accepted_count'] += 1 if label == 'accepted_copy'
          stats['later_count'] += 1 if label == 'later'
          stats['dismissed_count'] += 1 if label == 'dismissed'
        end
      end

      {
        sample_size: rows.size,
        interacted_size: interacted_size,
        label_counts: label_counts.to_h,
        feature_stats: feature_stats.transform_values(&:to_h)
      }
    rescue StandardError
      {}
    end

    def ranker_feature_values(impression, features)
      start_at = impression.start_at
      duration_minutes = features['duration_minutes'] || duration_from_impression(impression)

      {
        'kind' => impression.kind.to_s.presence,
        'category' => features['category'].to_s.presence,
        'intent' => features['intent'].to_s.presence,
        'schedule_profile' => features['schedule_profile'].to_s.presence,
        'weekday' => start_at&.wday&.to_s,
        'hour_bucket' => ranker_hour_bucket(features['start_hour'] || start_at&.hour),
        'duration_bucket' => ranker_duration_bucket(duration_minutes),
        'contact_relation_type' => features['contact_relation_type'].to_s.presence
      }.compact
    end

    def duration_from_impression(impression)
      return nil if impression.start_at.blank? || impression.end_at.blank?

      ((impression.end_at - impression.start_at) / 60).round
    rescue StandardError
      nil
    end

    def ranker_hour_bucket(value)
      hour = safe_integer(value)
      return nil if hour.nil?

      case hour
      when 5...12 then 'morning'
      when 12...15 then 'midday'
      when 15...18 then 'afternoon'
      when 18...22 then 'evening'
      else 'night'
      end
    end

    def ranker_duration_bucket(value)
      minutes = safe_integer(value)
      return nil if minutes.nil? || minutes <= 0

      case minutes
      when 0...45 then 'short'
      when 45...91 then 'medium'
      else 'long'
      end
    end

    def ranking_reward(label)
      case label.to_s
      when 'accepted_copy' then 1.0
      when 'later' then 0.25
      when 'dismissed' then -0.65
      else 0.0
      end
    end

    def safe_integer(value)
      Integer(value)
    rescue StandardError
      nil
    end

    def normalize_json_hash(value)
      hash = value.is_a?(Hash) ? value : {}
      hash.respond_to?(:deep_stringify_keys) ? hash.deep_stringify_keys : hash.transform_keys(&:to_s)
    rescue StandardError
      {}
    end

    def home_events_scope
      scope = Event.left_outer_joins(:event_participants)
      scope = scope.where('events.end_at >= ? AND events.start_at <= ?', @now.beginning_of_day, @now + LOOKAHEAD_DAYS.days)

      if ActiveRecord::Base.connection.data_source_exists?('event_groups')
        scope = scope.where(
          "event_participants.user_id = :uid OR (events.created_by_id = :uid AND NOT EXISTS (SELECT 1 FROM event_groups eg WHERE eg.event_id = events.id))",
          uid: user.id
        )
      else
        scope = scope.where('event_participants.user_id = :uid OR events.created_by_id = :uid', uid: user.id)
      end

      scope.distinct.order(start_at: :asc, id: :asc)
    end

    def candidate_group_events
      return Event.none unless ActiveRecord::Base.connection.data_source_exists?('event_groups')

      group_ids = if group_scope?
                    [conversation.group_id.to_i]
                  else
                    GroupMember.where(user_id: user.id).pluck(:group_id).map(&:to_i).uniq
                  end
      return Event.none if group_ids.empty?

      personal_event_ids = EventParticipant.where(user_id: user.id).select(:event_id)

      Event.joins(:event_groups)
           .where(event_groups: { group_id: group_ids })
           .where('events.end_at >= ? AND events.start_at <= ?', @now.beginning_of_day, @now + LOOKAHEAD_DAYS.days)
           .where.not(id: personal_event_ids)
           .distinct
           .order(start_at: :asc, id: :asc)
           .limit(GROUP_EVENT_LIMIT)
    end

    def peer_events_payload
      peers = peer_users_for_availability
      return [] if peers.empty?

      peer_ids = peers.keys
      peer_names = peers

      scope = Event.left_outer_joins(:event_participants)
                   .where(event_participants: { user_id: peer_ids })
                   .where('events.end_at >= ? AND events.start_at <= ?', @now.beginning_of_day, @now + LOOKAHEAD_DAYS.days)
                   .distinct
                   .order(start_at: :asc, id: :asc)
                   .limit(80)

      scope.flat_map do |event|
        participant_ids = EventParticipant.where(event_id: event.id, user_id: peer_ids).pluck(:user_id)
        participant_ids.filter_map do |peer_id|
          payload = context_visibility.payload_for(
            event,
            source_type: 'peer_event',
            peer_user_id: peer_id,
            peer_name: peer_names[peer_id]
          )
          next unless payload

          payload[:event_id] = payload.delete(:id) if payload.key?(:id)
          payload
        end
      end
    rescue StandardError
      []
    end

    def peer_users_for_availability
      peers = {}

      Array(contacts_payload).each do |contact|
        linked_user_id = contact[:linked_user_id] || contact['linked_user_id']
        next if linked_user_id.blank?
        next if linked_user_id.to_i == user.id

        peers[linked_user_id.to_i] = (contact[:display_name] || contact['display_name'] || contact[:linked_user_name] || contact['linked_user_name']).to_s
      end

      Array(friends_payload).each do |friend|
        friend_id = friend[:id] || friend['id']
        next if friend_id.blank?
        next if friend_id.to_i == user.id

        peers[friend_id.to_i] ||= (friend[:name] || friend['name'] || friend[:email] || friend['email']).to_s
      end

      peers.reject { |_id, name| name.blank? }
    rescue StandardError
      {}
    end

    def serialize_events(events)
      events.filter_map do |event|
        context_visibility.payload_for(event, source_type: 'event')
      end
    end
  end
end
