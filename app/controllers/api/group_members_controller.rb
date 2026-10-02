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

      with_locked_group_members(extra_user_ids: [user_id]) do |group, members|
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless group_admin_from_locked?(group, members)

        group_member = members.find { |member| member.user_id.to_i == user_id }
        raise ActiveRecord::RecordNotFound unless group_member
        owner_user_id = locked_group_owner_id(group)
        raise SecretaryMutation::NativeWriterGuard::Forbidden if owner_user_id.to_i == user_id

        group_member.update!(role: new_role)
      end

      render json: { ok: true }
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::TargetSetChanged
      json_error('group membership changed', status: :conflict)
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH /api/groups/:group_id/members/:user_id/owner
    def transfer_owner
      authorize_owner!
      return if performed?

      user_id = params[:user_id].to_i
      return json_error('invalid user_id', status: :bad_request) if user_id <= 0

      unless @group.respond_to?(:owner_id=) || @group.respond_to?(:owner_user_id=)
        return json_error('group owner column is missing', status: :unprocessable_entity)
      end

      members = GroupMember.where(group_id: @group.id).includes(:user).to_a
      previous_owner_user_id = compute_owner_user_id(members)
      return json_error('already owner', status: :bad_request) if previous_owner_user_id.to_i == user_id

      target_member = members.find { |member| member.user_id.to_i == user_id }
      return json_error('target user is not a group member', status: :not_found) unless target_member

      with_locked_group_members(extra_user_ids: [user_id, previous_owner_user_id]) do |group, locked_members|
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless group_owner_from_locked?(group)

        previous_owner_user_id = locked_group_owner_id(group)
        raise SecretaryMutation::NativeWriterGuard::TargetSetChanged if previous_owner_user_id.to_i == user_id
        target_member = locked_members.find { |member| member.user_id.to_i == user_id }
        raise ActiveRecord::RecordNotFound unless target_member
        previous_owner_member = locked_members.find { |member| member.user_id.to_i == previous_owner_user_id.to_i }
        target_member.update!(role: 'admin') if target_member.respond_to?(:role=)
        previous_owner_member.update!(role: 'admin') if previous_owner_member&.respond_to?(:role=)

        if group.respond_to?(:owner_id=)
          group.update!(owner_id: user_id)
        elsif group.respond_to?(:owner_user_id=)
          group.update!(owner_user_id: user_id)
        end
      end

      updated_members = GroupMember.where(group_id: @group.id).includes(:user).to_a

      render json: {
        ok: true,
        owner_user_id: user_id,
        previous_owner_user_id: previous_owner_user_id,
        members: updated_members.map { |group_member| serialize_member(group_member, user_id) }
      }
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Only owner can transfer ownership', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::TargetSetChanged
      json_error('group membership changed', status: :conflict)
    rescue ActiveRecord::RecordNotFound
      json_error('target user is not a group member', status: :not_found)
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

      invited_user_ids = []
      with_locked_group_members(extra_user_ids: requested_ids) do |group, members|
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless group_admin_from_locked?(group, members)

        allowed_friend_ids = friend_ids_for(current_user.id) & requested_ids
        existing_member_ids = members.map(&:user_id) & allowed_friend_ids
        target_ids = allowed_friend_ids - existing_member_ids
        target_ids.each do |user_id|
          GroupMember.create!(group_id: group.id, user_id: user_id, role: :member)
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
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      json_error('Forbidden', status: :forbidden)
    rescue SecretaryMutation::NativeWriterGuard::TargetSetChanged
      json_error('group membership changed', status: :conflict)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def with_locked_group_members(extra_user_ids:)
      expected_owner_id = group_owner_user_id
      expected_member_user_ids = GroupMember.where(group_id: @group.id).order(:user_id).pluck(:user_id)
      user_ids = [expected_owner_id, *expected_member_user_ids, *extra_user_ids]
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: [], user_ids: user_ids
      ) do
        @group = Group.lock.find(@group.id)
        members = GroupMember.where(group_id: @group.id).order(:id).lock.to_a
        current_member_user_ids = members.map(&:user_id).sort
        unless locked_group_owner_id(@group).to_i == expected_owner_id.to_i &&
            current_member_user_ids == expected_member_user_ids.sort
          raise SecretaryMutation::NativeWriterGuard::TargetSetChanged,
            'group ownership or membership changed while waiting'
        end

        yield @group, members
      end
    end

    def group_admin_from_locked?(group, members)
      return true if locked_group_owner_id(group).to_i == current_user.id.to_i

      membership = members.find { |member| member.user_id.to_i == current_user.id.to_i }
      membership&.role.to_s == 'admin'
    end

    def group_owner_from_locked?(group)
      locked_group_owner_id(group).to_i == current_user.id.to_i
    end

    def locked_group_owner_id(group)
      if group.respond_to?(:owner_id) && group.owner_id.present?
        group.owner_id
      elsif group.respond_to?(:owner_user_id) && group.owner_user_id.present?
        group.owner_user_id
      end
    end

    def set_group
      group_id = params[:id] || params[:group_id]
      @group = Group.find(group_id)
    end

    def authorize_member!
      return if GroupMember.exists?(group_id: @group.id, user_id: current_user.id)

      json_error('Forbidden', status: :forbidden)
    end

    def authorize_owner!
      owner_id = group_owner_user_id
      return if owner_id.present? && owner_id.to_i == current_user.id.to_i

      json_error('Only owner can transfer ownership', status: :forbidden)
    end

    def authorize_admin!
      group_member = GroupMember.find_by(group_id: @group.id, user_id: current_user.id)

      owner_id = group_owner_user_id
      is_owner = owner_id.present? && owner_id.to_i == current_user.id.to_i
      is_admin = group_member && group_member.respond_to?(:role) && group_member.role.to_s == 'admin'

      return if is_owner || is_admin

      json_error('Forbidden', status: :forbidden)
    end

    def group_owner_user_id
      if @group.respond_to?(:owner_id) && @group.owner_id.present?
        return @group.owner_id
      end

      if @group.respond_to?(:owner_user_id) && @group.owner_user_id.present?
        return @group.owner_user_id
      end

      nil
    end

    def compute_owner_user_id(members)
      owner_id = group_owner_user_id
      return owner_id if owner_id.present?

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
