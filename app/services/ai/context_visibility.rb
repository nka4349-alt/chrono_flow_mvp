# frozen_string_literal: true

module Ai
  # Builds event payloads for AI context after applying the viewer's visibility boundary.
  #
  # Product rule:
  # - personal_simple: the viewer's own events can be detailed; other users' events are at most free/busy.
  # - business_full: event/group grants can expose title_time/detail/edit/admin for B2B workspaces.
  # - group conversations never leak unrelated personal or sibling-group event detail into the shared AI context.
  class ContextVisibility
    PERMISSIONS = %w[none free_busy title_time detail comment edit admin].freeze
    RANK = PERMISSIONS.each_with_index.to_h.freeze

    NONE = 'none'
    FREE_BUSY = 'free_busy'
    TITLE_TIME = 'title_time'
    DETAIL = 'detail'
    COMMENT = 'comment'
    EDIT = 'edit'
    ADMIN = 'admin'

    PERSONAL_SIMPLE = 'personal_simple'
    BUSINESS_FULL = 'business_full'
    MODES = [PERSONAL_SIMPLE, BUSINESS_FULL].freeze

    def initialize(user:, conversation:, now: Time.current)
      @user = user
      @conversation = conversation
      @now = now
      @access_rows = []
    end

    def mode
      @mode ||= resolve_mode
    end

    def payload_for(event, source_type: 'event', permission: nil, peer_user_id: nil, peer_name: nil)
      resolved_permission = normalize_permission(permission || permission_for(event, source_type: source_type, peer_user_id: peer_user_id))
      return nil if resolved_permission == NONE

      payload = build_payload(event, permission: resolved_permission, peer_user_id: peer_user_id, peer_name: peer_name)
      remember_access(event, permission: resolved_permission, source_type: source_type, payload: payload)
      payload
    rescue StandardError
      nil
    end

    def permission_for(event, source_type: 'event', peer_user_id: nil)
      return NONE unless event && user

      permission = if source_type.to_s == 'peer_event'
                     permission_for_peer_event(event, peer_user_id: peer_user_id)
                   else
                     highest_permission(base_permissions_for(event))
                   end

      apply_scope_and_mode_policy(event, permission: permission, source_type: source_type)
    rescue StandardError
      NONE
    end

    def flush_access_logs!(request_id:)
      return if @access_rows.empty?
      return unless table_exists?('ai_context_access_logs')

      now_value = Time.current
      rows = @access_rows.map do |row|
        row.merge(request_id: request_id, created_at: now_value, updated_at: now_value)
      end

      AiContextAccessLog.insert_all(rows) if rows.any?
      @access_rows.clear
    rescue StandardError
      @access_rows.clear
    end

    def permission_at_least?(permission, minimum)
      RANK.fetch(normalize_permission(permission), 0) >= RANK.fetch(normalize_permission(minimum), 0)
    end

    def group_context?
      conversation&.scope_type.to_s == 'group' && conversation&.group_id.present?
    end

    private

    attr_reader :user, :conversation, :now

    def resolve_mode
      raw = nil

      if group_context? && conversation.group && group_has_column?(:ai_context_mode)
        raw = conversation.group.ai_context_mode
      end

      raw = ENV['CF_AI_CONTEXT_MODE'] if raw.blank?
      MODES.include?(raw.to_s) ? raw.to_s : PERSONAL_SIMPLE
    rescue StandardError
      PERSONAL_SIMPLE
    end

    def base_permissions_for(event)
      permissions = []
      permissions << explicit_event_grant_permission(event)
      permissions << DETAIL if event_owner?(event)
      permissions << DETAIL if event_participant?(event)
      permissions << group_permission_for(event)
      permissions << inherited_group_permission_for(event)
      permissions
    end

    def permission_for_peer_event(event, peer_user_id:)
      direct_permission = highest_permission(base_permissions_for(event))

      if mode == PERSONAL_SIMPLE
        return direct_permission if event_owner?(event) || event_participant?(event)
        return peer_availability_allowed?(peer_user_id) ? FREE_BUSY : NONE
      end

      return direct_permission if permission_at_least?(direct_permission, FREE_BUSY)

      peer_availability_allowed?(peer_user_id) ? FREE_BUSY : NONE
    end

    def apply_scope_and_mode_policy(event, permission:, source_type:)
      permission = normalize_permission(permission)
      return NONE if permission == NONE

      # In a shared group AI conversation, personal/outside-group events should only block time.
      if group_context? && !event_in_current_group?(event)
        permission = [permission, FREE_BUSY].min_by { |candidate| RANK.fetch(candidate, 0) }
      end

      # B2C/personal mode is intentionally simple: own/participating events can be detailed;
      # all other users' events are reduced to free/busy even if the UI can show more.
      if mode == PERSONAL_SIMPLE && !(event_owner?(event) || event_participant?(event))
        permission = [permission, FREE_BUSY].min_by { |candidate| RANK.fetch(candidate, 0) }
      end

      # peer_event is availability-oriented. In personal mode, peer detail is never sent.
      if source_type.to_s == 'peer_event' && mode == PERSONAL_SIMPLE && !(event_owner?(event) || event_participant?(event))
        permission = [permission, FREE_BUSY].min_by { |candidate| RANK.fetch(candidate, 0) }
      end

      permission
    end

    def build_payload(event, permission:, peer_user_id:, peer_name:)
      context_permission = normalize_permission(permission)
      base = {
        start_at: event.start_at&.iso8601,
        end_at: event.end_at&.iso8601,
        all_day: !!event.try(:all_day),
        context_permission: context_permission,
        ai_context_mode: mode
      }

      base[:peer_user_id] = peer_user_id if peer_user_id.present?
      base[:peer_name] = peer_name if peer_name.present?

      case context_permission
      when FREE_BUSY
        base.merge(
          id: nil,
          title: '予定あり',
          description: nil,
          location: nil,
          group_ids: [],
          group_names: [],
          masked: true,
          masked_level: FREE_BUSY
        )
      when TITLE_TIME
        base.merge(
          id: event.id,
          title: event.title,
          description: nil,
          location: nil,
          group_ids: event_group_ids(event),
          group_names: event_group_names(event),
          masked: true,
          masked_level: TITLE_TIME
        )
      else
        base.merge(
          id: event.id,
          title: event.title,
          description: event.try(:description),
          location: event.try(:location),
          color: event.try(:color),
          created_by_id: event.try(:created_by_id),
          group_ids: event_group_ids(event),
          group_names: event_group_names(event),
          masked: false,
          masked_level: nil
        )
      end
    end

    def remember_access(event, permission:, source_type:, payload:)
      return unless event&.id

      @access_rows << {
        user_id: user.id,
        event_id: event.id,
        group_id: primary_event_group_id(event),
        source_type: source_type.to_s,
        permission_used: normalize_permission(permission),
        masked_level: payload[:masked_level],
        ai_context_mode: mode
      }
    rescue StandardError
      nil
    end

    def event_owner?(event)
      event.respond_to?(:created_by_id) && event.created_by_id.to_i == user.id.to_i
    end

    def event_participant?(event)
      return false unless table_exists?('event_participants')

      EventParticipant.exists?(event_id: event.id, user_id: user.id)
    end

    def group_permission_for(event)
      return NONE unless table_exists?('event_groups')

      group_ids = event_group_ids(event)
      return NONE if group_ids.empty?

      grant_permission = explicit_group_grant_permission(group_ids)
      return grant_permission if permission_at_least?(grant_permission, FREE_BUSY)

      # A member of the group that owns the event can see the event in detail by default.
      return DETAIL if GroupMember.exists?(user_id: user.id, group_id: group_ids)

      NONE
    end

    def inherited_group_permission_for(event)
      return NONE unless group_has_column?(:inheritance_mode)

      event_groups(event).filter_map do |group|
        case group.inheritance_mode.to_s
        when 'parent_free_busy'
          FREE_BUSY if parent_group_admin?(group)
        when 'tree_visible'
          DETAIL if user_in_group_tree?(group)
        end
      end.then { |permissions| highest_permission(permissions) }
    rescue StandardError
      NONE
    end

    def explicit_event_grant_permission(event)
      return NONE unless table_exists?('event_access_grants')

      principal_sql, bind_values = principal_predicate

      permissions = EventAccessGrant
                    .where(event_id: event.id)
                    .where('expires_at IS NULL OR expires_at > ?', now)
                    .where(principal_sql, *bind_values)
                    .pluck(:permission)

      highest_permission(permissions)
    rescue StandardError
      NONE
    end

    def explicit_group_grant_permission(group_ids)
      return NONE unless table_exists?('group_access_grants')

      principal_sql, bind_values = principal_predicate

      permissions = GroupAccessGrant
                    .where(group_id: group_ids)
                    .where('expires_at IS NULL OR expires_at > ?', now)
                    .where(principal_sql, *bind_values)
                    .pluck(:permission)

      highest_permission(permissions)
    rescue StandardError
      NONE
    end

    def principal_predicate
      clauses = ['(principal_type = ? AND principal_id = ?)']
      bind_values = ['User', user.id]

      group_ids = current_user_group_ids
      if group_ids.any?
        clauses << '(principal_type = ? AND principal_id IN (?))'
        bind_values.concat(['Group', group_ids])
      end

      [clauses.join(' OR '), bind_values]
    end

    def peer_availability_allowed?(peer_user_id)
      peer_id = peer_user_id.to_i
      return false if peer_id <= 0 || peer_id == user.id.to_i

      if table_exists?('friendships') && defined?(Friendship)
        peer = User.find_by(id: peer_id)
        return true if peer && Friendship.connected?(user, peer)
      end

      if table_exists?('contacts') && defined?(Contact)
        return true if Contact.active.exists?(user_id: user.id, linked_user_id: peer_id)
      end

      if group_context? && table_exists?('group_members')
        return true if GroupMember.exists?(group_id: conversation.group_id, user_id: peer_id)
      end

      false
    rescue StandardError
      false
    end

    def event_in_current_group?(event)
      return false unless group_context?
      return false unless table_exists?('event_groups')

      EventGroup.exists?(event_id: event.id, group_id: conversation.group_id)
    rescue StandardError
      false
    end

    def parent_group_admin?(group)
      parent_id = group.parent_id
      return false if parent_id.blank?

      GroupMember.exists?(group_id: parent_id, user_id: user.id, role: GroupMember.roles[:admin]) ||
        Group.where(id: parent_id, owner_id: user.id).exists?
    rescue StandardError
      false
    end

    def user_in_group_tree?(group)
      ids = [group.id, group.parent_id].compact
      GroupMember.exists?(group_id: ids, user_id: user.id)
    rescue StandardError
      false
    end

    def current_user_group_ids
      return [] unless table_exists?('group_members')

      @current_user_group_ids ||= GroupMember.where(user_id: user.id).pluck(:group_id).map(&:to_i).uniq
    end

    def event_group_ids(event)
      event_groups(event).map(&:id)
    end

    def primary_event_group_id(event)
      event_group_ids(event).first
    end

    def event_group_names(event)
      event_groups(event).map(&:name)
    end

    def event_groups(event)
      return [] unless table_exists?('event_groups')

      @event_groups_by_event_id ||= {}
      @event_groups_by_event_id[event.id] ||= begin
        ids = EventGroup.where(event_id: event.id).pluck(:group_id)
        ids.empty? ? [] : Group.where(id: ids).order(:id).to_a
      end
    rescue StandardError
      []
    end

    def highest_permission(values)
      Array(values)
        .map { |value| normalize_permission(value) }
        .max_by { |permission| RANK.fetch(permission, 0) } || NONE
    end

    def normalize_permission(value)
      permission = value.to_s
      PERMISSIONS.include?(permission) ? permission : NONE
    end

    def table_exists?(name)
      ActiveRecord::Base.connection.data_source_exists?(name)
    rescue StandardError
      false
    end

    def group_has_column?(name)
      table_exists?('groups') && Group.column_names.include?(name.to_s)
    rescue StandardError
      false
    end
  end
end
