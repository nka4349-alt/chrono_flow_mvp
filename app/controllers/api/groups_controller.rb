# frozen_string_literal: true

module Api
  class GroupsController < BaseController
    before_action :set_group, only: %i[show update destroy reorder events]
    before_action :authorize_member!, only: %i[show events]
    before_action :authorize_admin!, only: %i[update destroy reorder]

    # GET /api/groups
    def index
      groups = Group
        .joins(:group_members)
        .where(group_members: { user_id: current_user.id })
        .distinct

      if groups.klass.column_names.include?('position')
        groups = groups.order(Arel.sql('COALESCE(groups.position, 0) ASC'), :id)
      else
        groups = groups.order(:id)
      end

      render json: {
        groups: groups.map { |g| serialize_group(g) }
      }
    end

    # GET /api/groups/:id
    def show
      render json: { group: serialize_group(@group) }
    end

    # POST /api/groups
    def create
      g = Group.new(group_params)

      # owner_id は DB で NOT NULL
      g.owner_id = current_user.id if g.respond_to?(:owner_id=) && g.owner_id.blank?

      # 旧スキーマ保険
      if g.respond_to?(:owner_user_id=) && g.owner_user_id.blank?
        g.owner_user_id = current_user.id
      end

      if g.respond_to?(:position=) && g.position.nil?
        g.position = 0
      end

      g.save!

      # 作成者を admin 参加
      begin
        GroupMember.find_or_create_by!(group_id: g.id, user_id: current_user.id) do |gm|
          gm.role = 'admin' if gm.respond_to?(:role=)
        end
      rescue StandardError
      end

      # グループチャットルーム作成
      begin
        ChatRoom.find_or_create_by!(chatable: g)
      rescue StandardError
      end

      render json: { group: serialize_group(g) }, status: :created
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
          g = Group.find(gid)
          next unless GroupMember.exists?(group_id: g.id, user_id: current_user.id)

          g.update!(position: idx) if g.respond_to?(:position=)
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

      render json: { events: events.map { |ev| serialize_fc_event(ev) } }
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
      gm = GroupMember.find_by(group_id: @group.id, user_id: current_user.id)

      owner_id =
        if @group.respond_to?(:owner_id) && @group.owner_id.present?
          @group.owner_id
        elsif @group.respond_to?(:owner_user_id) && @group.owner_user_id.present?
          @group.owner_user_id
        else
          nil
        end

      is_owner = owner_id.present? && owner_id == current_user.id
      is_admin = gm && gm.respond_to?(:role) && gm.role.to_s == 'admin'

      return if is_owner || is_admin
      json_error('Forbidden', status: :forbidden)
    end

    def group_params
      p = params[:group].is_a?(ActionController::Parameters) ? params.require(:group) : params

      allowed = %i[name]
      allowed << :parent_id if Group.column_names.include?('parent_id')
      allowed << :position  if Group.column_names.include?('position')

      p.permit(*allowed)
    end

    def parse_time_param(v)
      return nil if v.blank?
      Time.zone.parse(v.to_s)
    rescue StandardError
      nil
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

    def serialize_group(g)
      {
        id: g.id,
        name: g.name,
        parent_id: (g.respond_to?(:parent_id) ? g.parent_id : nil),
        position:  (g.respond_to?(:position) ? g.position : nil),
        owner_id:  (g.respond_to?(:owner_id) ? g.owner_id : nil)
      }
    end

    def serialize_fc_event(event)
      group_ids = if ActiveRecord::Base.connection.data_source_exists?('event_groups')
                    EventGroup.where(event_id: event.id).pluck(:group_id)
                  else
                    []
                  end

      color = nil
      if event.respond_to?(:event_type_id) && event.event_type_id.present? && defined?(EventType)
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
          created_by_id: (event.respond_to?(:created_by_id) ? event.created_by_id : nil)
        }
      }
    end
  end
end
