# frozen_string_literal: true

module Api
  class EventShareRequestsController < BaseController
    # GET /api/event_share_requests
    # 返す: 自分が承認すべき pending リクエスト（User宛 / 管理可能Group宛）
    def index
      pending = EventShareRequest.pending

      # 自分宛（User target）
      user_reqs = pending.where(target_type: 'User', target_id: current_user.id)

      # 自分が承認できる Group（owner または admin）
      admin_group_ids = GroupMember.where(user_id: current_user.id, role: :admin).pluck(:group_id)
      owner_group_ids = Group.where(owner_id: current_user.id).pluck(:id)
      manageable_group_ids = (admin_group_ids + owner_group_ids).uniq

      group_reqs = manageable_group_ids.empty? ? EventShareRequest.none : pending.where(target_type: 'Group', target_id: manageable_group_ids)

      reqs = EventShareRequest
        .where(id: (user_reqs.pluck(:id) + group_reqs.pluck(:id)).uniq)
        .includes(:event, :requested_by)
        .order(created_at: :desc)

      render json: {
        requests: reqs.map { |r| serialize_request(r) }
      }
    end

    # POST /api/events/:event_id/share_requests
    # body: { group_ids: [], user_ids: [] }
    def create
      event = Event.find_by(id: params[:event_id])
      return render_error('Event not found', status: 404) unless event

      # 基本: 作成者 or 参加者のみ共有可（MVP）
      can = false
      can ||= (event.respond_to?(:created_by_id) && event.created_by_id == current_user.id)
      can ||= (event.respond_to?(:created_by) && event.created_by == current_user)
      can ||= (event.respond_to?(:user_id) && event.user_id == current_user.id)
      can ||= (event.respond_to?(:user) && event.user == current_user)
      can ||= (event.respond_to?(:owner_id) && event.owner_id == current_user.id)
      can ||= EventParticipant.exists?(event_id: event.id, user_id: current_user.id)
      return render_error('Forbidden', status: 403) unless can

      group_ids = Array(params[:group_ids]).map(&:to_i).uniq
      user_ids  = Array(params[:user_ids]).map(&:to_i).uniq

      # 自分自身は除外
      user_ids -= [current_user.id]

      created = 0
      skipped = 0

      # --- Group targets ---
      group_ids.each do |gid|
        group = Group.find_by(id: gid)
        next(skipped += 1) unless group

        # 共有先グループのメンバーでない場合は弾く（スパム防止）
        next(skipped += 1) unless GroupMember.exists?(group_id: gid, user_id: current_user.id) || group.owner_id == current_user.id

        req = EventShareRequest.find_or_initialize_by(event_id: event.id, target_type: 'Group', target_id: gid)
        if req.persisted?
          skipped += 1
          next
        end
        req.requested_by_id = current_user.id
        req.status = :pending
        req.save!
        created += 1
      end

      # --- User targets ---
      # 友達 or 同じグループに所属しているユーザのみ（MVP）
      # friends (片方向/両方向どちらでも可)
      friend_ids = Friendship.where(user_id: current_user.id).pluck(:friend_id)
      friend_ids += Friendship.where(friend_id: current_user.id).pluck(:user_id)
      friend_ids = friend_ids.uniq

      # 同じグループにいるユーザ
      my_group_ids = GroupMember.where(user_id: current_user.id).pluck(:group_id)
      shared_group_user_ids = if my_group_ids.empty?
        []
      else
        GroupMember.where(group_id: my_group_ids).pluck(:user_id)
      end

      allowed_user_ids = (friend_ids + shared_group_user_ids).uniq

      user_ids.each do |uid|
        target_user = User.find_by(id: uid)
        next(skipped += 1) unless target_user
        next(skipped += 1) unless allowed_user_ids.include?(uid)

        req = EventShareRequest.find_or_initialize_by(event_id: event.id, target_type: 'User', target_id: uid)
        if req.persisted?
          skipped += 1
          next
        end
        req.requested_by_id = current_user.id
        req.status = :pending
        req.save!
        created += 1
      end

      render json: { ok: true, created: created, skipped: skipped }
    rescue ActiveRecord::RecordInvalid => e
      render_error(e.record.errors.full_messages.join(', '), status: 422)
    end

    # PATCH /api/event_share_requests/:id
    # body: { decision: "approve"|"reject" }
    def update
      req = EventShareRequest.find_by(id: params[:id])
      return render_error('Not found', status: 404) unless req

      decision = params[:decision].to_s
      decision = params.dig(:event_share_request, :decision).to_s if decision.blank?
      decision = params[:status].to_s if decision.blank?

      return render_error('decision is required', status: 422) if decision.blank?

      # auth
      unless can_respond?(req)
        return render_error('Forbidden', status: 403)
      end

      case decision
      when 'approve', 'approved', 'accept'
        apply_request!(req)
        req.status = :approved
      when 'reject', 'rejected', 'decline'
        req.status = :rejected
      else
        return render_error('Invalid decision', status: 422)
      end

      req.responded_by_id = current_user.id
      req.responded_at = Time.current
      req.save!

      render json: { ok: true, request: serialize_request(req) }
    rescue ActiveRecord::RecordInvalid => e
      render_error(e.record.errors.full_messages.join(', '), status: 422)
    end

    private

    def can_respond?(req)
      if req.target_type == 'User'
        return req.target_id == current_user.id
      end

      if req.target_type == 'Group'
        group = Group.find_by(id: req.target_id)
        return false unless group
        return true if group.owner_id == current_user.id
        return GroupMember.exists?(group_id: group.id, user_id: current_user.id, role: :admin)
      end

      false
    end

    def apply_request!(req)
      if req.target_type == 'User'
        uid = req.target_id
        EventParticipant.find_or_create_by!(event_id: req.event_id, user_id: uid) do |ep|
          ep.role = :guest if ep.respond_to?(:role=)
          ep.source = :requested if ep.respond_to?(:source=)
        end
      elsif req.target_type == 'Group'
        EventGroup.find_or_create_by!(event_id: req.event_id, group_id: req.target_id)
      end
    end

    def serialize_request(r)
      target_name = nil
      if r.target_type == 'Group'
        g = Group.find_by(id: r.target_id)
        target_name = g&.name
      elsif r.target_type == 'User'
        u = User.find_by(id: r.target_id)
        target_name = u&.respond_to?(:name) && u.name.present? ? u.name : u&.email
      end

      {
        id: r.id,
        status: r.status,
        event_id: r.event_id,
        event_title: (r.event.respond_to?(:title) ? r.event.title : nil),
        requested_by_id: r.requested_by_id,
        requested_by_name: (r.requested_by.respond_to?(:name) ? r.requested_by.name : r.requested_by.email),
        target_type: r.target_type,
        target_id: r.target_id,
        target_name: target_name,
        created_at: r.created_at,
      }
    end
  end
end
