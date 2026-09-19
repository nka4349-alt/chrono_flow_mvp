# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class AiRecommendationsRoutesTest < ActionDispatch::IntegrationTest
  setup do
    @now = Time.utc(2026, 9, 19, 0)
    @user = User.create!(name: 'Routes acceptance', email: "route-accept-#{SecureRandom.hex(6)}@example.invalid", password: 'password123')
    @conversation = AiConversation.create!(user: @user, scope_type: 'home')
    post '/login', params: { email: @user.email, password: 'password123' }
    assert_response :redirect
    @provider_calls = []
    calls = @provider_calls
    result = successful_result
    @provider = Object.new
    @provider.define_singleton_method(:call) do |**request|
      calls << request
      result
    end
  end

  test 'acceptance rechecks route then atomically saves bundle and retries create nothing' do
    travel_to(@now) do
      recommendation = create_recommendation
      with_stub(TravelRouting::GoogleRoutesProvider, :new, @provider) do
        assert_difference(['Event.count', 'EventParticipant.count'], 2) do
          assert_difference('AiRecommendationFeedback.count', 1) { accept(recommendation) }
        end
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal 2, body.fetch('events').length
        assert_equal 'Google Maps', body.dig('recommendation', 'payload', 'route_attribution')
        refute body.dig('recommendation', 'payload').key?('routing')
        refute_includes response.body, 'private-provider-origin'
        ids = body.fetch('events').map { |event| event.fetch('id') }
        assert_equal [@user.id], Event.where(id: ids).distinct.pluck(:created_by_id)
        assert recommendation.reload.accepted_copy?
        assert_equal 1, @provider_calls.size

        assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) { accept(recommendation) }
        assert_response :success
        assert_equal 1, @provider_calls.size
        assert_equal ids.first, JSON.parse(response.body).dig('recommendation', 'created_event_id')
      end
    end
  end

  test 'expired or conflicted route proposal has zero calendar and feedback writes' do
    travel_to(@now) do
      recommendation = create_recommendation
      conflict = @user.created_events.create!(title: 'New busy in arrival buffer', start_at: @now + 33.hours + 5.minutes,
        end_at: @now + 33.hours + 10.minutes, color: '#3b82f6')
      assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) { accept(recommendation) }
      assert_response :unprocessable_entity
      assert recommendation.reload.pending?
      assert_empty @provider_calls
      conflict.destroy!
    end
    recommendation = create_recommendation
    travel_to(@now + 900) do
      assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) { accept(recommendation) }
      assert_response :unprocessable_entity
      assert_equal TravelRouting::RecommendationGuard::EXPIRED_MESSAGE, JSON.parse(response.body).fetch('error')
    end
  end

  test 'provider revalidation failure does not save or expose provider details' do
    travel_to(@now) do
      recommendation = create_recommendation
      @provider.define_singleton_method(:call) { |**_request| raise 'secret-address api-key SQL trace' }
      with_stub(TravelRouting::GoogleRoutesProvider, :new, @provider) do
        assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) { accept(recommendation) }
      end
      assert_response :unprocessable_entity
      assert_equal TravelRouting::RecommendationGuard::FAILURE_MESSAGE, JSON.parse(response.body).fetch('error')
      refute_includes response.body, 'secret-address'
      assert recommendation.reload.pending?
    end
  end

  test 'chat and feedback serializers retain attribution and hide server route evidence' do
    travel_to(@now) do
      recommendation = create_recommendation
      get '/api/ai_chat', params: { scope: 'home' }, as: :json
      assert_response :success
      payload = JSON.parse(response.body).fetch('recommendations').find { |item| item['id'] == recommendation.id }.fetch('payload')
      refute payload.key?('routing')
      assert_equal 'Google Maps', payload['route_attribution']
      refute_includes response.body, 'private-provider-origin'

      post "/api/ai_recommendations/#{recommendation.id}/feedback", params: { feedback_action: 'later' }, as: :json
      assert_response :success
      refute JSON.parse(response.body).dig('recommendation', 'payload').key?('routing')
      assert recommendation.reload.payload.key?('routing')
    end
  end

  test 'GenerateReply checks canonical conflicts and persists route evidence only on a feasible candidate' do
    travel_to(@now) do
      context = { scope: 'home', now: @now.iso8601, timezone: 'Asia/Tokyo', personal_events: [] }
      ai_response = { assistant_message: '移動候補です。', recommendations: [candidate], provider: 'rails-local-routes-api-v1', tool_invocations: [],
        routes_provenance: TravelRouting::RecommendationGuard::LOCAL_PROVENANCE }
      with_stub(Ai::ContextBuilder, :call, context) do
        with_stub(Ai::Client, :call, ai_response) do
          assert_no_difference(['Event.count', 'EventParticipant.count']) do
            Ai::GenerateReply.call(conversation: @conversation, user: @user, user_message: '電車で移動')
          end
        end
      end
      recommendation = @conversation.ai_recommendations.pending.sole
      assert recommendation.payload.dig('routing', 'approval_digest').present?
      with_stub(TravelRouting::GoogleRoutesProvider, :new, @provider) { accept(recommendation) }
      assert_response :success

      with_stub(Ai::ContextBuilder, :call, context) do
        with_stub(Ai::Client, :call, ai_response) do
          assert_no_difference('AiRecommendation.count') do
            Ai::GenerateReply.call(conversation: @conversation, user: @user, user_message: '電車で移動')
          end
        end
      end
      assert_equal TravelRouting::RecommendationGuard::FAILURE_MESSAGE, @conversation.ai_messages.last.body
    end
  end

  test 'actual home chat creates a provider backed proposal that can be accepted through the same UI API' do
    Time.use_zone('Asia/Tokyo') do
      travel_to(@now) do
        with_stub(TravelRouting::GoogleRoutesProvider, :new, @provider) do
          assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) do
            post '/api/ai_chat/messages', params: {
              scope: 'home', body: '東京駅から大阪駅まで電車で移動、明日18時15分に会議、15分前に到着'
            }, as: :json
          end
          assert_response :created
          body = JSON.parse(response.body)
          public_candidate = body.fetch('recommendations').sole
          assert_equal 'Google Maps', public_candidate.dig('payload', 'route_attribution')
          refute public_candidate.fetch('payload').key?('routing')
          recommendation = @user.ai_recommendations.find(public_candidate.fetch('id'))
          assert recommendation.payload.dig('routing', 'approval_digest').present?
          assert_equal 'RAIL', recommendation.payload.dig('routing', 'request', 'transit_mode')
          assert_equal 1, @provider_calls.size

          assert_difference(['Event.count', 'EventParticipant.count'], 2) do
            assert_difference('AiRecommendationFeedback.count', 1) { accept(recommendation) }
          end
          assert_response :success
          saved = JSON.parse(response.body)
          assert_equal 2, @provider_calls.size
          assert_equal 'Google Maps', saved.dig('recommendation', 'payload', 'route_attribution')
          refute saved.dig('recommendation', 'payload').key?('routing')
          assert_equal ['移動: 東京駅 → 大阪駅', '会議'], saved.fetch('events').map { |event| event.fetch('title') }
          assert_equal @now + 33.hours + 15.minutes, Time.iso8601(saved.fetch('events').last.fetch('start_at'))
          assert recommendation.reload.accepted_copy?
        end
      end
    end
  end

  private

  def with_stub(target, name, value)
    original = target.method(name)
    target.define_singleton_method(name) { |*_, **_keywords| value }
    yield
  ensure
    target.define_singleton_method(name, &original)
  end

  def accept(recommendation)
    post "/api/ai_recommendations/#{recommendation.id}/accept_copy", as: :json
  end

  def successful_result
    TravelRouting::GoogleRoutesProvider::Result.new(code: 'ok', duration_seconds: 1800, distance_meters: 2400,
      walking_seconds: 300, departure_time: (@now + 32.hours + 30.minutes).iso8601,
      arrival_time: (@now + 33.hours).iso8601, attribution: 'Google Maps')
  end

  def candidate
    travel_start, travel_end, main_start, main_end = [32.hours + 30.minutes, 33.hours, 33.hours + 15.minutes, 34.hours + 15.minutes].map { |offset| (@now + offset).iso8601 }
    { 'kind' => 'draft_event', 'title' => '移動込み: 会議', 'start_at' => travel_start, 'end_at' => main_end, 'all_day' => false,
      'payload' => {
        'route_attribution' => 'Google Maps',
        'events' => [
          { 'title' => '移動', 'start_at' => travel_start, 'end_at' => travel_end, 'all_day' => false, 'location' => '目的地' },
          { 'title' => '会議', 'start_at' => main_start, 'end_at' => main_end, 'all_day' => false, 'location' => '目的地' }
        ],
        'routing' => {
          'source' => 'google_routes',
          'request' => { 'origin' => 'private-provider-origin', 'destination' => 'private-provider-destination', 'mode' => 'TRANSIT', 'arrival_time' => travel_end },
          'result' => successful_result.to_h.stringify_keys.except('code', 'attribution'),
          'checked_at' => @now.iso8601, 'arrival_buffer_minutes' => 15
        }
      } }
  end

  def create_recommendation
    response = TravelRouting::RecommendationGuard.prepare_response({ recommendations: [candidate],
      routes_provenance: TravelRouting::RecommendationGuard::LOCAL_PROVENANCE }, user: @user, now: @now)
    attrs = response.fetch(:recommendations).sole
    @conversation.ai_recommendations.create!(user: @user, kind: attrs['kind'], title: attrs['title'],
      start_at: attrs['start_at'], end_at: attrs['end_at'], all_day: false, payload: attrs['payload'])
  end
end
