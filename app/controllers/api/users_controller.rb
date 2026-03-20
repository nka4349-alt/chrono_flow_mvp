# frozen_string_literal: true

module Api
  class UsersController < BaseController
    # GET /api/users?q=keyword
    def index
      q = params[:q].to_s.strip
      return render(json: { users: [] }) if q.blank?

      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%"

      users = User
        .where.not(id: current_user.id)
        .where("LOWER(COALESCE(users.name, '')) LIKE :q OR LOWER(users.email) LIKE :q", q: pattern)
        .order(:id)
        .limit(limit_param)
        .to_a

      friend_ids = friend_ids_for(current_user.id)
      user_ids = users.map(&:id)

      pending_sent_ids = []
      pending_received_ids = []
      shared_group_counts = {}

      if user_ids.any?
        outgoing_requests = Notification.where(user_id: user_ids, kind: Notification.kinds[:friend_request], read_at: nil).to_a
        pending_sent_ids = outgoing_requests.filter_map do |notification|
          payload = notification.payload.to_h.stringify_keys
          next unless payload.fetch('status', 'pending').to_s == 'pending'
          next unless payload['from_user_id'].to_i == current_user.id.to_i

          notification.user_id.to_i
        end.uniq

        incoming_requests = current_user.notifications.friend_request.where(read_at: nil).to_a
        pending_received_ids = incoming_requests.filter_map do |notification|
          payload = notification.payload.to_h.stringify_keys
          next unless payload.fetch('status', 'pending').to_s == 'pending'

          from_user_id = payload['from_user_id'].to_i
          user_ids.include?(from_user_id) ? from_user_id : nil
        end.uniq

        my_group_ids = GroupMember.where(user_id: current_user.id).pluck(:group_id)
        if my_group_ids.any?
          shared_group_counts = GroupMember
            .where(group_id: my_group_ids, user_id: user_ids)
            .group(:user_id)
            .count
        end
      end

      render json: {
        users: users.map { |user| serialize_user(user, friend_ids, pending_sent_ids, pending_received_ids, shared_group_counts) }
      }
    end

    private

    def limit_param
      value = params[:limit].to_i
      return 20 if value <= 0

      [value, 50].min
    end

    def serialize_user(user, friend_ids, pending_sent_ids, pending_received_ids, shared_group_counts)
      {
        id: user.id,
        name: user.display_name,
        email: user.email,
        is_friend: friend_ids.include?(user.id),
        pending_sent: pending_sent_ids.include?(user.id),
        pending_received: pending_received_ids.include?(user.id),
        shared_group_count: shared_group_counts[user.id].to_i
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
