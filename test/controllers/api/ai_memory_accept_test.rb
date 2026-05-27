# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class ApiAiMemoryAcceptTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      name: 'Memory User',
      email: "ai-memory-#{SecureRandom.hex(6)}@example.com",
      password: 'password123'
    )
    @conversation = AiConversation.create!(user: @user, scope_type: 'home', last_used_at: Time.current)

    post '/login', params: { email: @user.email, password: 'password123' }
    assert_response :redirect
  end

  test 'accept memory_save user_place creates user place' do
    recommendation = create_memory_recommendation!(
      title: '自宅を天王寺駅として保存',
      payload: {
        memory_type: 'user_place',
        kind: 'home',
        label: '自宅',
        place_name: '天王寺駅'
      }
    )

    post "/api/ai_recommendations/#{recommendation.id}/accept_copy", as: :json

    assert_response :success
    place = @user.user_places.find_by!(kind: 'home')
    assert_equal '自宅', place.label
    assert_equal '天王寺駅', place.place_name
    assert_equal 'ai', place.source
    assert_equal true, place.active
  end

  test 'accept memory_save route creates user travel route' do
    recommendation = create_memory_recommendation!(
      title: '自宅から大阪駅まで30分として保存',
      payload: {
        memory_type: 'user_travel_route',
        origin_name: '自宅',
        origin_kind: 'home',
        destination_name: '大阪駅',
        travel_minutes: 30,
        transport_mode: 'train'
      }
    )

    post "/api/ai_recommendations/#{recommendation.id}/accept_copy", as: :json

    assert_response :success
    route = @user.user_travel_routes.find_by!(origin_name: '自宅', destination_name: '大阪駅')
    assert_equal 'home', route.origin_kind
    assert_equal 30, route.travel_minutes
    assert_equal 'train', route.transport_mode
  end

  test 'accept memory_save preference creates ai user preference' do
    recommendation = create_memory_recommendation!(
      title: '会議の到着余裕を15分前として保存',
      payload: {
        memory_type: 'ai_user_preference',
        key: 'arrival_buffer.meeting',
        value: '15',
        value_type: 'integer'
      }
    )

    post "/api/ai_recommendations/#{recommendation.id}/accept_copy", as: :json

    assert_response :success
    preference = @user.ai_user_preferences.find_by!(key: 'arrival_buffer.meeting')
    assert_equal '15', preference.value
    assert_equal 'integer', preference.value_type
    assert_equal 'ai', preference.source
  end

  private

  def create_memory_recommendation!(title:, payload:)
    AiRecommendation.create!(
      ai_conversation: @conversation,
      user: @user,
      kind: 'memory_save',
      title: title,
      description: 'AI秘書のメモリー保存候補',
      reason: '保存候補',
      payload: payload.merge(title: title)
    )
  end
end
