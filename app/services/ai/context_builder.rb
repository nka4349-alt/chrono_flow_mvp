# frozen_string_literal: true

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
      {
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
        personal_events: serialize_events(home_events_scope.limit(24).to_a),
        candidate_group_events: serialize_events(candidate_group_events.to_a),
        recent_group_messages: recent_group_messages_payload,
        friends: friends_payload,
        contacts: contacts_payload,
        recent_direct_messages: recent_direct_messages_payload,
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
            peer_name: peer.respond_to?(:display_name) ? peer.display_name : (peer.name.presence || peer.email)
          }
        end
      end

      messages.sort_by { |item| item[:created_at].to_s }.last(DIRECT_MESSAGE_LIMIT)
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

      my_group_ids = GroupMember.where(user_id: user.id).select(:group_id)
      return Event.none unless my_group_ids.exists?

      personal_event_ids = EventParticipant.where(user_id: user.id).select(:event_id)

      Event.joins(:event_groups)
           .where(event_groups: { group_id: my_group_ids })
           .where('events.end_at >= ? AND events.start_at <= ?', @now.beginning_of_day, @now + LOOKAHEAD_DAYS.days)
           .where.not(id: personal_event_ids)
           .distinct
           .order(start_at: :asc, id: :asc)
           .limit(GROUP_EVENT_LIMIT)
    end

    def serialize_events(events)
      events.map do |event|
        {
          id: event.id,
          title: event.title,
          description: event.try(:description),
          location: event.try(:location),
          color: event.try(:color),
          start_at: event.start_at&.iso8601,
          end_at: event.end_at&.iso8601,
          all_day: !!event.try(:all_day),
          created_by_id: event.try(:created_by_id),
          group_ids: event.respond_to?(:group_ids) ? event.group_ids : [],
          group_names: event.respond_to?(:groups) ? event.groups.map(&:name) : []
        }
      end
    end
  end
end
