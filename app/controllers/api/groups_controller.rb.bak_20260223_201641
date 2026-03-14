# frozen_string_literal: true

module Api
  class GroupsController < BaseController
    before_action :set_group, only: %i[show update destroy events reorder]

    # GET /api/groups
    def index
      groups = Group.joins(:group_members)
                    .where(group_members: { user_id: current_user.id })
                    .distinct
                    .order(:position, :id)

      render json: groups.map { |g| serialize_group(g) }
    end

    # POST /api/groups
    def create
      g = Group.new(group_params)
      g.position ||= (Group.maximum(:position) || 0) + 1

      Group.transaction do
        g.save!
        GroupMember.find_or_create_by!(group: g, user: current_user) do |gm|
          gm.role = :admin if gm.respond_to?(:role)
        end
      end

      render json: serialize_group(g), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # PATCH/PUT /api/groups/:id
    def update
      authorize_admin!(@group)
      @group.update!(group_params)
      render json: serialize_group(@group)
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # DELETE /api/groups/:id
    def destroy
      authorize_admin!(@group)
      @group.destroy!
      head :no_content
    end

    # GET /api/groups/:id/events?start=...&end=...
    def events
      authorize_member!(@group)

      start_t = parse_time(params[:start])
      end_t   = parse_time(params[:end])
      start_t ||= Time.zone.now.beginning_of_month
      end_t   ||= (Time.zone.now.end_of_month + 1.day)

      event_ids = EventGroup.where(group_id: @group.id).select(:event_id)
      events = Event.where(id: event_ids)
                   .where('events.end_at > ? AND events.start_at < ?', start_t, end_t)
                   .order(:start_at)

      render json: events.map { |ev| serialize_fc_event(ev, scope: 'group') }
    end

    # PATCH /api/groups/:id/reorder { position: 2 }
    def reorder
      authorize_admin!(@group)
      pos = params[:position].to_i
      @group.update!(position: pos) if params.key?(:position)
      render json: serialize_group(@group)
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    private

    def set_group
      @group = Group.find(params[:id])
    end

    def group_params
      gp = params[:group].presence || params
      permitted = gp.permit(:name, :parent_id, :position)
      permitted[:parent_id] = nil if permitted.key?(:parent_id) && permitted[:parent_id].blank?
      permitted
    end

    def authorize_member!(group)
      return if GroupMember.exists?(group_id: group.id, user_id: current_user.id)
      render json: { error: 'forbidden' }, status: :forbidden
    end

    def authorize_admin!(group)
      gm = GroupMember.find_by(group_id: group.id, user_id: current_user.id)
      allowed = gm && (gm.try(:owner?) || gm.try(:admin?))
      return if allowed
      render json: { error: 'forbidden' }, status: :forbidden
    end

    def parse_time(value)
      return nil if value.blank?
      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def serialize_group(g)
      {
        id: g.id,
        name: g.name,
        parent_id: g.parent_id,
        position: g.position
      }
    end

    def serialize_fc_event(ev, scope:)
      type_color = EventType.where(id: ev.event_type_id).pick(:color)
      base_color = scope == 'group' ? '#ef4444' : '#3b82f6'
      color = type_color.presence || base_color

      {
        id: ev.id,
        title: scope == 'group' ? "グループ: #{ev.title}" : ev.title,
        start: ev.start_at&.iso8601,
        end: ev.end_at&.iso8601,
        allDay: !!ev.all_day,
        backgroundColor: color,
        borderColor: color,
        extendedProps: {
          description: ev.try(:description),
          event_type_id: ev.event_type_id,
          parent_id: ev.parent_id,
          group_ids: EventGroup.where(event_id: ev.id).pluck(:group_id),
          scope: scope
        }
      }
    end
  end
end
