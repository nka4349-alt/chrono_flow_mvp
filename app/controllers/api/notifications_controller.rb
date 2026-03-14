# frozen_string_literal: true

module Api
  class NotificationsController < BaseController
    # GET /api/notifications
    def index
      limit = params[:limit].to_i
      limit = 50 if limit <= 0 || limit > 200

      notifications = current_user.notifications.order(created_at: :desc).limit(limit)

      render json: {
        notifications: notifications.map { |n|
          {
            id: n.id,
            kind: n.kind,
            payload: n.payload,
            read_at: n.read_at&.iso8601,
            created_at: n.created_at&.iso8601
          }
        }
      }
    end

    # PATCH /api/notifications/:id/read
    def read
      n = current_user.notifications.find(params[:id])
      n.update!(read_at: Time.zone.now)
      render json: { ok: true }
    end
  end
end
