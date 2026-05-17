# frozen_string_literal: true

module Api
  class EventRemindersController < BaseController
    before_action :set_event, only: %i[index create]

    # GET /api/events/:event_id/reminders
    def index
      authorize_event_visible!
      reminders = current_user.event_reminders.where(event: @event).order(remind_at: :asc, id: :asc)
      render json: { reminders: reminders.map { |reminder| serialize_reminder(reminder) } }
    end

    # POST /api/events/:event_id/reminders
    def create
      authorize_event_visible!
      minutes_before = params[:minutes_before].to_i
      minutes_before = 30 if minutes_before <= 0
      remind_at = parse_time(params[:remind_at]) || (@event.start_at - minutes_before.minutes)

      reminder = current_user.event_reminders.find_or_initialize_by(event: @event, remind_at: remind_at)
      reminder.minutes_before = minutes_before
      reminder.status = :pending
      reminder.payload = (reminder.payload || {}).merge('source' => 'manual')
      reminder.save!

      render json: { reminder: serialize_reminder(reminder) }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      json_error(e.record.errors.full_messages.join(', '), status: :unprocessable_entity)
    rescue StandardError => e
      json_error(e.message, status: (e.message == 'Forbidden' ? :forbidden : :unprocessable_entity))
    end

    # DELETE /api/event_reminders/:id
    def destroy
      reminder = current_user.event_reminders.find(params[:id])
      reminder.update!(status: :cancelled)
      render json: { ok: true, reminder: serialize_reminder(reminder) }
    rescue ActiveRecord::RecordNotFound
      json_error('not found', status: :not_found)
    rescue StandardError => e
      json_error(e.message, status: :unprocessable_entity)
    end

    private

    def set_event
      @event = Event.find(params[:event_id])
    end

    def authorize_event_visible!
      return if @event.created_by_id.to_i == current_user.id.to_i
      return if EventParticipant.exists?(event_id: @event.id, user_id: current_user.id)

      raise 'Forbidden'
    end

    def serialize_reminder(reminder)
      {
        id: reminder.id,
        event_id: reminder.event_id,
        remind_at: reminder.remind_at&.iso8601,
        minutes_before: reminder.minutes_before,
        status: reminder.status,
        delivered_at: reminder.delivered_at&.iso8601,
        payload: reminder.payload
      }
    end
  end
end
