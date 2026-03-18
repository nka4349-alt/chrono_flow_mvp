# frozen_string_literal: true

module Api
  class GroupMembersController < BaseController
    before_action :set_group

    # GET /api/groups/:id/members
    def index
      authorize_member!
      return if performed?

      members = GroupMember
        .where(group_id: @group.id)
        .includes(:user)
        .to_a

      # PostgreSQL / SQLite 差異を避けるため Ruby 側で並び替え
      members.sort_by! do |gm|
        [role_rank(gm), gm.created_at || Time.at(0)]
      end

      owner_user_id = compute_owner_user_id(members)
      current_gm = members.find { |m| m.user_id.to_i == current_user.id.to_i }
      current_role = current_gm&.role.to_s

      can_manage_roles =
        (owner_user_id.present? && owner_user_id.to_i == current_user.id.to_i) ||
        (current_role == 'admin')

      render json: {
        group_id: @group.id,
        owner_user_id: owner_user_id,
        current_user_id: current_user.id,
        current_user_role: current_role,
        can_manage_roles: can_manage_roles,
        members: members.map { |gm| serialize_member(gm, owner_user_id) }
      }
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH /api/groups/:group_id/members/:user_id/role
    def update_role
      authorize_admin!
      return if performed?

      user_id = params[:user_id].to_i
      new_role = params[:role].to_s

      unless %w[member admin].include?(new_role)
        return json_error('invalid role', status: :bad_request)
      end

      gm = GroupMember.find_by!(group_id: @group.id, user_id: user_id)

      owner_user_id = compute_owner_user_id(GroupMember.where(group_id: @group.id).includes(:user).to_a)
      if owner_user_id.present? && owner_user_id.to_i == user_id
        return json_error('owner role cannot be changed', status: :forbidden)
      end

      gm.update!(role: new_role)

      render json: { ok: true }
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def set_group
      gid = params[:id] || params[:group_id]
      @group = Group.find(gid)
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    end

    def authorize_member!
      return if performed?
      return if GroupMember.exists?(group_id: @group.id, user_id: current_user.id)

      json_error('Forbidden', status: :forbidden)
    end

    def authorize_admin!
      return if performed?

      gm = GroupMember.find_by(group_id: @group.id, user_id: current_user.id)

      owner_id =
        if @group.respond_to?(:owner_id) && @group.owner_id.present?
          @group.owner_id
        elsif @group.respond_to?(:owner_user_id) && @group.owner_user_id.present?
          @group.owner_user_id
        else
          nil
        end

      is_owner = owner_id.present? && owner_id.to_i == current_user.id.to_i
      is_admin = gm && gm.respond_to?(:role) && gm.role.to_s == 'admin'

      return if is_owner || is_admin

      json_error('Forbidden', status: :forbidden)
    end

    def compute_owner_user_id(members)
      if @group.respond_to?(:owner_id) && @group.owner_id.present?
        return @group.owner_id
      end

      if @group.respond_to?(:owner_user_id) && @group.owner_user_id.present?
        return @group.owner_user_id
      end

      admin = members.find { |gm| gm.respond_to?(:role) && gm.role.to_s == 'admin' }
      admin&.user_id || members.first&.user_id
    end

    def role_rank(gm)
      gm.respond_to?(:role) && gm.role.to_s == 'admin' ? 0 : 1
    end

    def serialize_member(gm, owner_user_id)
      u = gm.user
      {
        user_id: gm.user_id,
        id: gm.user_id,
        name: (u.respond_to?(:name) ? u.name : nil),
        email: (u.respond_to?(:email) ? u.email : nil),
        role: (gm.respond_to?(:role) ? gm.role.to_s : 'member'),
        is_owner: owner_user_id.present? && owner_user_id.to_i == gm.user_id.to_i
      }
    end
  end
end
