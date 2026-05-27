# frozen_string_literal: true

module Api
  class AiMemoriesController < BaseController
    def index
      render json: {
        user_places: current_user.user_places.active.ordered.map { |place| serialize_place(place) },
        user_travel_routes: current_user.user_travel_routes.active.ordered.map { |route| serialize_route(route) },
        ai_user_preferences: current_user.ai_user_preferences.order(:key, :id).map { |preference| serialize_preference(preference) }
      }
    end

    def destroy_user_place
      place = current_user.user_places.find(params[:id])
      place.update!(active: false)
      render json: { ok: true, user_place: serialize_place(place) }
    end

    def destroy_user_travel_route
      route = current_user.user_travel_routes.find(params[:id])
      route.update!(active: false)
      render json: { ok: true, user_travel_route: serialize_route(route) }
    end

    def destroy_ai_user_preference
      preference = current_user.ai_user_preferences.find(params[:id])
      preference.destroy!
      render json: { ok: true }
    end

    private

    def serialize_place(place)
      {
        id: place.id,
        kind: place.kind,
        label: place.label,
        place_name: place.place_name,
        address_text: place.address_text,
        notes: place.notes,
        active: place.active
      }
    end

    def serialize_route(route)
      {
        id: route.id,
        origin_name: route.origin_name,
        origin_kind: route.origin_kind,
        destination_name: route.destination_name,
        travel_minutes: route.travel_minutes,
        transport_mode: route.transport_mode,
        arrival_buffer_minutes: route.arrival_buffer_minutes,
        notes: route.notes,
        active: route.active
      }
    end

    def serialize_preference(preference)
      {
        id: preference.id,
        key: preference.key,
        value: preference.value,
        value_type: preference.value_type
      }
    end
  end
end
