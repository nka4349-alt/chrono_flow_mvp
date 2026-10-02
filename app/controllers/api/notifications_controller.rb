# frozen_string_literal: true

module Api
  class NotificationsController < BaseController
    # GET /api/notifications
    def index
      EventReminder.deliver_due_for_user!(current_user) if defined?(EventReminder)

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
      event_id = notification_event_id(n)
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: [event_id], require_all: false
      ) do
        n = current_user.notifications.lock.find(n.id)
        n.update!(read_at: Time.zone.now)
      end
      render json: { ok: true }
    end

    private

    def notification_event_id(notification)
      value = notification.payload.is_a?(Hash) ? notification.payload['event_id'] : nil
      Integer(value, exception: false)
    end
  end
end
