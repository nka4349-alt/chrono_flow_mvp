# frozen_string_literal: true

module Api
  class AvailabilityProfilesController < BaseController
    before_action :set_contact

    # GET /api/contacts/:contact_id/availability_profiles
    def index
      render json: {
        availability_profiles: @contact.availability_profiles.ordered.map { |profile| serialize_profile(profile) }
      }
    end

    # POST /api/contacts/:contact_id/availability_profiles
    def create
      profile = @contact.availability_profiles.create!(profile_params)
      render json: { availability_profile: serialize_profile(profile) }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # PATCH /api/contacts/:contact_id/availability_profiles/:id
    def update
      profile = @contact.availability_profiles.find(params[:id])
      profile.update!(profile_params)
      render json: { availability_profile: serialize_profile(profile) }
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'availability profile not found' }, status: :not_found
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # DELETE /api/contacts/:contact_id/availability_profiles/:id
    def destroy
      profile = @contact.availability_profiles.find(params[:id])
      profile.destroy!
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'availability profile not found' }, status: :not_found
    end

    private

    def set_contact
      @contact = current_user.contacts.find(params[:contact_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'contact not found' }, status: :not_found
    end

    def profile_params
      params.require(:availability_profile).permit(
        :weekday,
        :start_minute,
        :end_minute,
        :preference_kind,
        :source_kind,
        :notes,
        :active
      )
    end

    def serialize_profile(profile)
      {
        id: profile.id,
        weekday: profile.weekday,
        day_label: profile.day_label,
        start_minute: profile.start_minute,
        end_minute: profile.end_minute,
        start_hhmm: profile.start_hhmm,
        end_hhmm: profile.end_hhmm,
        preference_kind: profile.preference_kind,
        source_kind: profile.source_kind,
        notes: profile.notes,
        active: profile.active,
        created_at: profile.created_at&.iso8601,
        updated_at: profile.updated_at&.iso8601
      }
    end
  end
end
