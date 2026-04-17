# frozen_string_literal: true

module Api
  class ContactsController < BaseController
    # GET /api/contacts
    def index
      contacts = current_user.contacts.includes(:availability_profiles, :linked_user).ordered

      render json: {
        contacts: contacts.map { |contact| serialize_contact(contact) }
      }
    end

    # POST /api/contacts
    def create
      contact = current_user.contacts.new(contact_params)
      contact.display_name = inferred_display_name(contact) if contact.display_name.blank?
      contact.save!

      render json: { contact: serialize_contact(contact.reload) }, status: :created
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'linked user not found' }, status: :not_found
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # PATCH /api/contacts/:id
    def update
      contact = current_user.contacts.find(params[:id])
      contact.assign_attributes(contact_params)
      contact.display_name = inferred_display_name(contact) if contact.display_name.blank?
      contact.save!

      render json: { contact: serialize_contact(contact.reload) }
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'contact not found' }, status: :not_found
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # DELETE /api/contacts/:id
    def destroy
      contact = current_user.contacts.find(params[:id])
      contact.destroy!
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'contact not found' }, status: :not_found
    end

    # POST /api/contacts/sync_friends
    def sync_friends
      created = []
      updated = []

      friend_users.each do |friend|
        attrs = {
          linked_user: friend,
          display_name: friend.display_name,
          relation_type: :friend,
          active: true,
          timezone: 'Asia/Tokyo'
        }

        contact = current_user.contacts.find_or_initialize_by(linked_user: friend)
        was_new = contact.new_record?
        contact.assign_attributes(attrs)
        contact.save!

        (was_new ? created : updated) << serialize_contact(contact)
      end

      render json: {
        ok: true,
        created_count: created.size,
        updated_count: updated.size,
        created:,
        updated:
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    private

    def contact_params
      permitted = params.require(:contact).permit(
        :display_name,
        :linked_user_id,
        :relation_type,
        :notes,
        :preferred_duration_minutes,
        :active,
        :timezone
      )

      if permitted[:linked_user_id].present?
        permitted[:linked_user] = User.find(permitted.delete(:linked_user_id))
      end

      permitted
    end

    def inferred_display_name(contact)
      contact.linked_user&.display_name.presence || contact.display_name
    end

    def serialize_contact(contact)
      {
        id: contact.id,
        display_name: contact.display_name,
        relation_type: contact.relation_type,
        relation_label: contact.relation_label,
        notes: contact.notes,
        preferred_duration_minutes: contact.preferred_duration_minutes,
        active: contact.active,
        timezone: contact.display_timezone,
        source_kind: contact.source_kind,
        linked_user: serialize_linked_user(contact.linked_user),
        availability_profiles: contact.availability_profiles.ordered.map { |profile| serialize_profile(profile) },
        created_at: contact.created_at&.iso8601,
        updated_at: contact.updated_at&.iso8601
      }
    end

    def serialize_linked_user(user)
      return nil unless user

      {
        id: user.id,
        name: user.display_name,
        email: user.email
      }
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

    def friend_users
      ids = []
      ids.concat Friendship.where(user_id: current_user.id).pluck(:friend_id)
      ids.concat Friendship.where(friend_id: current_user.id).pluck(:user_id)
      ids = ids.compact.map(&:to_i).uniq
      return [] if ids.empty?

      User.where(id: ids).order(Arel.sql('LOWER(name) ASC NULLS LAST'), :id)
    end
  end
end
