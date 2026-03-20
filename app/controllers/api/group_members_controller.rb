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
      members.sort_by! do |group_member|
        [role_rank(group_member), group_member.created_at || Time.at(0)]
      end

      owner_user_id = compute_owner_user_id(members)
      current_group_member = members.find { |member| member.user_id.to_i == current_user.id.to_i }
      current_role = current_group_member&.role.to_s

      can_manage_roles =
        (owner_user_id.present? && owner_user_id.to_i == current_user.id.to_i) ||
        (current_role == 'admin')

      render json: {
        group_id: @group.id,
        owner_user_id: owner_user_id,
        current_user_id: current_user.id,
        current_user_role: current_role,
        can_manage_roles: can_manage_roles,
        members: members.map { |group_member| serialize_member(group_member, owner_user_id) }
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

      group_member = GroupMember.find_by!(group_id: @group.id, user_id: user_id)

      owner_user_id = compute_owner_user_id(GroupMember.where(group_id: @group.id).includes(:user).to_a)
      if owner_user_id.present? && owner_user_id.to_i == user_id
        return json_error('owner role cannot be changed', status: :forbidden)
      end

      group_member.update!(role: new_role)

      render json: { ok: true }
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # POST /api/groups/:id/invite_friends
    # body: { friend_ids: [1, 2, 3] }
    def invite_friends
      authorize_admin!
      return if performed?

      requested_ids = Array(params[:friend_ids]).map(&:to_i).uniq - [current_user.id.to_i]
      return json_error('friend_ids is required', status: :bad_request) if requested_ids.empty?

      allowed_friend_ids = friend_ids_for(current_user.id) & requested_ids
      existing_member_ids = GroupMember.where(group_id: @group.id, user_id: allowed_friend_ids).pluck(:user_id)
      target_ids = allowed_friend_ids - existing_member_ids

      invited_user_ids = []

      Group.transaction do
        target_ids.each do |user_id|
          GroupMember.find_or_create_by!(group_id: @group.id, user_id: user_id) do |group_member|
            group_member.role = :member if group_member.respond_to?(:role=)
          end
          invited_user_ids << user_id
        end
      end

      skipped = requested_ids.size - invited_user_ids.size

      render json: {
        ok: true,
        invited_count: invited_user_ids.size,
        invited_user_ids: invited_user_ids,
        skipped: skipped
      }
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def set_group
      group_id = params[:id] || params[:group_id]
      @group = Group.find(group_id)
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

    def compute_owner_user_id(members)
      if @group.respond_to?(:owner_id) && @group.owner_id.present?
        return @group.owner_id
      end

      if @group.respond_to?(:owner_user_id) && @group.owner_user_id.present?
        return @group.owner_user_id
      end

      admin_member = members.find { |group_member| group_member.respond_to?(:role) && group_member.role.to_s == 'admin' }
      admin_member&.user_id || members.first&.user_id
    end

    def role_rank(group_member)
      group_member.respond_to?(:role) && group_member.role.to_s == 'admin' ? 0 : 1
    end

    def serialize_member(group_member, owner_user_id)
      user = group_member.user
      {
        user_id: group_member.user_id,
        id: group_member.user_id,
        name: (user.respond_to?(:display_name) ? user.display_name : (user.respond_to?(:name) ? user.name : nil)),
        email: (user.respond_to?(:email) ? user.email : nil),
        role: (group_member.respond_to?(:role) ? group_member.role.to_s : 'member'),
        is_owner: owner_user_id.present? && owner_user_id.to_i == group_member.user_id.to_i
      }
    end

    def friend_ids_for(user_id)
      ids = []
      ids.concat Friendship.where(user_id: user_id).pluck(:friend_id)
      ids.concat Friendship.where(friend_id: user_id).pluck(:user_id)
      ids.compact.map(&:to_i).uniq
    end
  end
end
