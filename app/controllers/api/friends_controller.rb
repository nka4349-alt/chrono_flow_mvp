# frozen_string_literal: true

module Api
  class FriendsController < BaseController
    # GET /api/friends
    def index
      return render(json: { friends: [] }) unless defined?(Friendship)

      users = User.where(id: friend_ids_for(current_user.id)).to_a
      users.sort_by! { |user| [(user.display_name || '').downcase, user.id.to_i] }

      render json: {
        friends: users.map { |user| serialize_user(user) }
      }
    end

    # GET /api/friend_requests
    def requests
      requests = current_user.notifications.friend_request.where(read_at: nil).order(created_at: :desc).to_a
      requests.select! { |notification| pending_friend_request?(notification) }

      render json: {
        requests: requests.map { |notification| serialize_friend_request(notification) }
      }
    end

    # POST /api/friend_requests
    # body: { user_id: <target_id> }
    def create_request
      target_id = params[:user_id] || params.dig(:friend_request, :user_id)
      target_user = User.find(target_id)

      return json_error('自分には送れません', status: :unprocessable_entity) if target_user.id.to_i == current_user.id.to_i
      return render(json: { ok: true, already_friend: true, friend: serialize_user(target_user) }) if Friendship.connected?(current_user, target_user)

      incoming_request = pending_request_notification(from_user_id: target_user.id, to_user_id: current_user.id)
      if incoming_request
        approve_friend_request!(incoming_request)
        return render json: {
          ok: true,
          auto_accepted: true,
          friend: serialize_user(target_user),
          request: serialize_friend_request(incoming_request)
        }
      end

      existing_request = pending_request_notification(from_user_id: current_user.id, to_user_id: target_user.id)
      if existing_request
        return render json: {
          ok: true,
          already_requested: true,
          request: serialize_friend_request(existing_request)
        }
      end

      request_notification = target_user.notifications.create!(
        kind: :friend_request,
        payload: {
          from_user_id: current_user.id,
          from_user_name: current_user.display_name,
          from_user_email: current_user.email,
          status: 'pending'
        }
      )

      render json: {
        ok: true,
        request: serialize_friend_request(request_notification)
      }, status: :created
    rescue ActiveRecord::RecordNotFound
      json_error('user not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    # PATCH /api/friend_requests/:id
    # body: { decision: approve | reject }
    def respond_request
      request_notification = current_user.notifications.friend_request.find(params[:id])
      decision = params[:decision].to_s
      decision = params.dig(:friend_request, :decision).to_s if decision.blank?
      return json_error('decision is required', status: :bad_request) if decision.blank?

      unless pending_friend_request?(request_notification)
        return json_error('request is not pending', status: :unprocessable_entity)
      end

      case decision
      when 'approve', 'approved', 'accept'
        approve_friend_request!(request_notification)
      when 'reject', 'rejected', 'decline'
        reject_friend_request!(request_notification)
      else
        return json_error('invalid decision', status: :bad_request)
      end

      render json: {
        ok: true,
        request: serialize_friend_request(request_notification)
      }
    rescue ActiveRecord::RecordNotFound
      json_error('request not found', status: :not_found)
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: :internal_server_error)
    end

    private

    def serialize_user(user)
      {
        id: user.id,
        name: user.display_name,
        email: user.email
      }
    end

    def serialize_friend_request(notification)
      payload = notification.payload.to_h.stringify_keys

      {
        id: notification.id,
        from_user_id: payload['from_user_id'].to_i,
        from_user_name: payload['from_user_name'].presence || payload['from_user_email'].presence || "User##{payload['from_user_id']}",
        from_user_email: payload['from_user_email'],
        status: payload['status'].presence || 'pending',
        created_at: notification.created_at&.iso8601,
        read_at: notification.read_at&.iso8601
      }
    end

    def friend_ids_for(user_id)
      ids = []
      ids.concat Friendship.where(user_id: user_id).pluck(:friend_id)
      ids.concat Friendship.where(friend_id: user_id).pluck(:user_id)
      ids.compact.map(&:to_i).uniq
    end

    def pending_request_notification(from_user_id:, to_user_id:)
      Notification.where(user_id: to_user_id, kind: Notification.kinds[:friend_request], read_at: nil)
                  .order(created_at: :desc)
                  .to_a
                  .find do |notification|
        payload = notification.payload.to_h.stringify_keys
        payload.fetch('status', 'pending').to_s == 'pending' && payload['from_user_id'].to_i == from_user_id.to_i
      end
    end

    def pending_friend_request?(notification)
      payload = notification.payload.to_h.stringify_keys
      notification.read_at.nil? && payload.fetch('status', 'pending').to_s == 'pending'
    end

    def approve_friend_request!(notification)
      payload = notification.payload.to_h.stringify_keys
      from_user = User.find(payload['from_user_id'])

      a_id, b_id = [from_user.id, current_user.id].map(&:to_i).sort
      Friendship.find_or_create_by!(user_id: a_id, friend_id: b_id)

      notification.update!(
        read_at: Time.current,
        payload: payload.merge(
          'status' => 'approved',
          'responded_at' => Time.current.iso8601,
          'responded_by_id' => current_user.id
        )
      )
    end

    def reject_friend_request!(notification)
      payload = notification.payload.to_h.stringify_keys

      notification.update!(
        read_at: Time.current,
        payload: payload.merge(
          'status' => 'rejected',
          'responded_at' => Time.current.iso8601,
          'responded_by_id' => current_user.id
        )
      )
    end
  end
end
