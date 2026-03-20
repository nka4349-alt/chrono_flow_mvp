# frozen_string_literal: true

module Api
  class GroupsController < BaseController
    before_action :set_group, only: %i[show update destroy reorder events]
    before_action :authorize_member!, only: %i[show events]
    before_action :authorize_admin!, only: %i[update destroy reorder]

    # GET /api/groups
    # query:
    #   q=keyword  # current user's groups only
    def index
      groups = Group.where(id: member_group_ids_relation)

      q = params[:q].to_s.strip
      if q.present?
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%"
        groups = groups.where('LOWER(groups.name) LIKE ?', pattern)
      end

      groups = apply_group_order(groups)

      render json: {
        groups: groups.map { |group| serialize_group(group) }
      }
    end

    # GET /api/groups/:id
    def show
      render json: { group: serialize_group(@group) }
    end

    # POST /api/groups
    def create
      group = Group.new(group_params)

      # owner_id は DB で NOT NULL
      group.owner_id = current_user.id if group.respond_to?(:owner_id=) && group.owner_id.blank?

      # 旧スキーマ保険
      if group.respond_to?(:owner_user_id=) && group.owner_user_id.blank?
        group.owner_user_id = current_user.id
      end

      group.position = 0 if group.respond_to?(:position=) && group.position.nil?

      group.save!

      # 作成者を admin 参加
      begin
        GroupMember.find_or_create_by!(group_id: group.id, user_id: current_user.id) do |member|
          member.role = 'admin' if member.respond_to?(:role=)
        end
      rescue StandardError
      end

      # グループチャットルーム作成
      begin
        ChatRoom.find_or_create_by!(chatable: group)
      rescue StandardError
      end

      render json: { group: serialize_group(group) }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH/PUT /api/groups/:id
    def update
      @group.update!(group_params)
      render json: { group: serialize_group(@group) }
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # DELETE /api/groups/:id
    def destroy
      @group.destroy!
      render json: { ok: true }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH /api/groups/:id/reorder
    def reorder
      ordered_ids = Array(params[:ordered_ids]).map(&:to_i).uniq
      return json_error('ordered_ids is required', status: :bad_request) if ordered_ids.empty?

      Group.transaction do
        ordered_ids.each_with_index do |gid, idx|
          group = Group.find(gid)
          next unless GroupMember.exists?(group_id: group.id, user_id: current_user.id)

          group.update!(position: idx) if group.respond_to?(:position=)
        end
      end

      render json: { ok: true }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # GET /api/groups/:id/events?start=...&end=...
    def events
      start_at = parse_time_param(params[:start])
      end_at   = parse_time_param(params[:end])

      events = group_events_scope(@group)
      if start_at && end_at
        events = events.where('events.end_at > ? AND events.start_at < ?', start_at, end_at)
      end
      events = events.order(:start_at)

      render json: { events: events.map { |event| serialize_fc_event(event) } }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def set_group
      @group = Group.find(params[:id])
    end

    def authorize_member!
      return if GroupMember.exists?(group_id: @group.id, user_id: current_user.id)

      json_error('Forbidden', status: :forbidden)
    end

    def authorize_admin!
      group_member = GroupMember.find_by(group_id: @group.id, user_id: current_user.id)

      owner_id =
        if @group.respond_to?(:owner_id) && @group.owner_id.present?
          @group.owner_id
        elsif @group.respond_to?(:owner_user_id) && @group.owner_user_id.present?
          @group.owner_user_id
        end

      is_owner = owner_id.present? && owner_id.to_i == current_user.id.to_i
      is_admin = group_member && group_member.respond_to?(:role) && group_member.role.to_s == 'admin'

      return if is_owner || is_admin

      json_error('Forbidden', status: :forbidden)
    end

    def group_params
      raw_params = params[:group].is_a?(ActionController::Parameters) ? params.require(:group) : params

      allowed = %i[name]
      allowed << :parent_id if Group.column_names.include?('parent_id')
      allowed << :position if Group.column_names.include?('position')

      raw_params.permit(*allowed)
    end

    def parse_time_param(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def member_group_ids_relation
      GroupMember.where(user_id: current_user.id).select(:group_id)
    end

    def apply_group_order(scope)
      if Group.column_names.include?('position')
        scope.order(Arel.sql('COALESCE(groups.position, 0) ASC'), :id)
      else
        scope.order(:id)
      end
    end

    def group_events_scope(group)
      if ActiveRecord::Base.connection.data_source_exists?('event_groups')
        Event.joins('INNER JOIN event_groups ON event_groups.event_id = events.id')
             .where(event_groups: { group_id: group.id })
             .distinct
      elsif Event.column_names.include?('group_id')
        Event.where(group_id: group.id)
      else
        Event.none
      end
    end

    def serialize_group(group)
      {
        id: group.id,
        name: group.name,
        parent_id: (group.respond_to?(:parent_id) ? group.parent_id : nil),
        position: (group.respond_to?(:position) ? group.position : nil),
        owner_id: (group.respond_to?(:owner_id) ? group.owner_id : nil)
      }
    end

    def serialize_fc_event(event)
      group_ids = if ActiveRecord::Base.connection.data_source_exists?('event_groups')
                    EventGroup.where(event_id: event.id).pluck(:group_id)
                  else
                    []
                  end

      color = nil
      color = event.color if event.respond_to?(:color) && event.color.present?
      if color.blank? && event.respond_to?(:event_type_id) && event.event_type_id.present? && defined?(EventType)
        color = EventType.where(id: event.event_type_id).limit(1).pluck(:color).first
      end
      color ||= '#3b82f6'

      {
        id: event.id,
        title: event.title,
        start: event.start_at&.iso8601,
        end: event.end_at&.iso8601,
        allDay: !!event.try(:all_day),
        backgroundColor: color,
        borderColor: color,
        extendedProps: {
          group_ids: group_ids,
          parent_id: (event.respond_to?(:parent_id) ? event.parent_id : nil),
          created_by_id: (event.respond_to?(:created_by_id) ? event.created_by_id : nil),
          location: (event.respond_to?(:location) ? event.location : nil),
          description: (event.respond_to?(:description) ? event.description : nil),
          color: (event.respond_to?(:color) ? event.color : nil)
        }
      }
    end
  end
end
