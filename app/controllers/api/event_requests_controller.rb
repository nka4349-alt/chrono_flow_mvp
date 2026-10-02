# frozen_string_literal: true

module Api
  class EventRequestsController < BaseController
    before_action :set_request, only: %i[update]

    # POST /api/event_requests
    # payload: { event_id, group_id, target_user_id, note }
    def create
      event = Event.find_by(id: params[:event_id])
      group = Group.find_by(id: params[:group_id])
      target_user = User.find_by(id: params[:target_user_id])

      return render_error('event_not_found', status: :not_found) if event.blank?
      return render_error('group_not_found', status: :not_found) if group.blank?
      return render_error('user_not_found', status: :not_found) if target_user.blank?

      req = nil
      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: [event.id], user_ids: [target_user.id]
      ) do |locked_events|
        event = locked_events.fetch(event.id)
        group = Group.lock.find(group.id)
        gm = group.group_members.lock.find_by(user_id: current_user.id)
        raise SecretaryMutation::NativeWriterGuard::Forbidden if gm.blank?
        unless gm.can_manage_events? || group.owner_id == current_user.id
          raise SecretaryMutation::NativeWriterGuard::Forbidden
        end
        raise EventNotInGroup unless EventGroup.exists?(event_id: event.id, group_id: group.id)

        req = EventRequest.new(event: event, group: group, target_user: target_user,
          requested_by: current_user, note: params[:note])
        raise ActiveRecord::RecordInvalid, req unless req.save

        Notification.create!(user: target_user, kind: :event_request,
          payload: { event_request_id: req.id, event_id: event.id, group_id: group.id })
      end

      render json: {
        ok: true,
        event_request: {
          id: req.id,
          status: req.status,
          event_id: req.event_id,
          group_id: req.group_id,
          target_user_id: req.target_user_id,
          requested_by_id: req.requested_by_id,
          note: req.note
        }
      }, status: :created
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      forbid!
    rescue EventNotInGroup
      render_error('event_not_in_group')
    rescue ActiveRecord::RecordInvalid => e
      render_error('validation_error', details: e.record.errors.full_messages)
    end

    # PATCH /api/event_requests/:id
    # payload: { status: "approved" | "rejected" }
    def update
      new_status = params[:status].to_s
      return render_error('invalid_status') unless %w[approved rejected].include?(new_status)

      SecretaryMutation::NativeWriterGuard.with_events(
        actor: current_user, event_ids: [@request.event_id],
        user_ids: [@request.target_user_id, @request.requested_by_id]
      ) do
        @request = EventRequest.lock.find(@request.id)
        raise SecretaryMutation::NativeWriterGuard::Forbidden unless @request.target_user_id == current_user.id

        if new_status == 'approved'
          EventParticipant.find_or_create_by!(event_id: @request.event_id, user_id: current_user.id) do |ep|
            ep.source = :requested
          end
        end

        @request.update!(status: new_status, responded_at: Time.zone.now)

        Notification.create!(
          user_id: @request.requested_by_id,
          kind: :event_request,
          payload: { event_request_id: @request.id, status: new_status, event_id: @request.event_id }
        )
      end

      render json: { ok: true, event_request: { id: @request.id, status: @request.status } }
    rescue SecretaryMutation::NativeWriterGuard::Forbidden
      forbid!
    end

    private

    EventNotInGroup = Class.new(StandardError)

    def set_request
      @request = EventRequest.find(params[:id])
    end
  end
end
