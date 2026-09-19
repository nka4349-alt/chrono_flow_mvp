# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class TravelRoutingRecommendationGuardTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 19, 0)
    @user = User.create!(name: 'Route guard test', email: "route-guard-#{SecureRandom.hex(6)}@example.invalid", password: 'password123')
    @conversation = AiConversation.create!(user: @user, scope_type: 'home')
    @calls = []
    @provider = Object.new
    @provider.define_singleton_method(:call) { |**_request| raise 'Unexpected route request' }
  end

  test 'preparation preserves exact route and buffered event times without Event writes' do
    response = nil
    assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) do
      response = prepare
    end
    payload = response.fetch(:recommendations).sole.fetch('payload')
    assert_equal proposal.fetch('payload').fetch('events'), payload.fetch('events')
    assert_match(/\A[0-9a-f]{64}\z/, payload.dig('routing', 'approval_digest'))
    assert_equal @now + 900, Time.iso8601(payload.dig('routing', 'expires_at'))
  end

  test 'complete canonical scope detects conflict after 24 earlier events and inside arrival buffer' do
    30.times do |index|
      create_event(start_at: @now + index.minutes, end_at: @now + (index + 1).minutes)
    end
    create_event(start_at: @now + 33.hours + 5.minutes, end_at: @now + 33.hours + 10.minutes)
    assert_empty prepare.fetch(:recommendations)
  end

  test 'participating events block while unrelated other user events do not' do
    other = User.create!(name: 'Other', email: "other-route-#{SecureRandom.hex(6)}@example.invalid", password: 'password123')
    event = create_event(user: other, start_at: @now + 32.hours + 40.minutes, end_at: @now + 33.hours)
    assert_equal 1, prepare.fetch(:recommendations).size
    EventParticipant.create!(event: event, user: @user, source: :copied)
    assert_empty prepare.fetch(:recommendations)
  end

  test 'all day conflicts block and half open adjacency is preserved' do
    create_event(start_at: @now + 24.hours, end_at: @now + 32.hours + 30.minutes)
    assert_equal 1, prepare.fetch(:recommendations).size
    create_event(start_at: @now + 24.hours, end_at: @now + 48.hours, all_day: true)
    assert_empty prepare.fetch(:recommendations)
  end

  test 'acceptance replays exact server request and leaves approved times unchanged' do
    recommendation = persist_prepared
    before = recommendation.payload.deep_dup
    stub_provider(route_result)
    assert guard.revalidate!(recommendation)
    assert_equal [proposal.dig('payload', 'routing', 'request').symbolize_keys], @calls
    assert_equal before, recommendation.reload.payload
  end

  test 'expired or altered approval is rejected before a provider call' do
    recommendation = persist_prepared
    assert_raises(TravelRouting::RecommendationGuard::Rejected) do
      TravelRouting::RecommendationGuard.new(user: @user, now: @now + 900, provider: @provider).revalidate!(recommendation)
    end
    recommendation.payload['events'][0]['start_at'] = (@now + 32.hours + 29.minutes).iso8601
    assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    assert_empty @calls
  end

  test 'longer route or provider failure cannot silently shift an accepted interval' do
    recommendation = persist_prepared
    [route_result(duration_seconds: 1860, arrival_time: (@now + 33.hours + 1.minute).iso8601),
     TravelRouting::GoogleRoutesProvider::Result.new(code: 'unavailable')].each do |result|
      stub_provider(result)
      assert_no_difference(['Event.count', 'AiRecommendationFeedback.count']) do
        assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
      end
    end
  end

  test 'deactivated or changed saved place cannot reuse old route' do
    place = @user.user_places.create!(kind: 'home', label: '自宅', place_name: 'Synthetic origin', address_text: 'Synthetic address')
    candidate = proposal
    candidate['payload']['routing']['place_bindings'] = [place.attributes.slice('id', 'kind', 'label', 'place_name', 'address_text')]
    recommendation = persist_prepared(candidate)
    place.update!(active: false)
    assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    place.update!(active: true, address_text: 'Changed address')
    assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    assert_empty @calls
  end

  test 'cross user recommendation and raw provider exceptions fail with safe copy' do
    recommendation = persist_prepared
    recommendation.user_id = @user.id + 100_000
    assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    recommendation.reload
    error = assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    assert_equal TravelRouting::RecommendationGuard::FAILURE_MESSAGE, error.message
    refute_includes error.message, 'Unexpected route request'
  end

  test 'routing data is recursively redacted from public payloads' do
    payload = { 'routing' => { 'request' => { 'origin' => 'private' } }, 'events' => [{ 'title' => '移動', 'routing' => { 'secret' => 'private' } }] }
    assert_equal({ 'events' => [{ 'title' => '移動' }] }, TravelRouting::RecommendationGuard.public_payload(payload))
    assert payload.key?('routing')
  end

  test 'remote fabricated routing and provider names cannot create verified proposals' do
    response = guard.prepare_response(recommendations: [proposal], provider: 'rails-local-routes-api-v1', routes_provenance: 'LOCAL_PROVENANCE')
    assert_empty response.fetch(:recommendations)
    assert_equal TravelRouting::RecommendationGuard::FAILURE_MESSAGE, response.fetch(:assistant_message)
  end

  test 'new profile or exact directed route buffer cannot weaken an already approved margin' do
    candidate = proposal
    candidate['payload']['routing']['buffer_context'] = {
      'preference_keys' => %w[arrival_buffer.meeting arrival_buffer.default],
      'origin_name' => 'Synthetic origin', 'destination_name' => 'Synthetic destination',
      'transport_modes' => ['train'], 'explicit_minutes' => 15
    }
    recommendation = persist_prepared(candidate)
    preference = @user.ai_user_preferences.create!(key: 'arrival_buffer.meeting', value: '20', value_type: 'integer')
    assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    preference.update!(value: '10')
    route = @user.user_travel_routes.create!(origin_name: 'Synthetic destination', destination_name: 'Synthetic origin',
      travel_minutes: 30, arrival_buffer_minutes: 30, transport_mode: 'train')
    stub_provider(route_result)
    assert guard.revalidate!(recommendation), 'reverse route buffer does not apply'
    route.update!(origin_name: 'Synthetic origin', destination_name: 'Synthetic destination')
    assert_raises(TravelRouting::RecommendationGuard::Rejected) { guard.revalidate!(recommendation) }
    assert_equal 1, @calls.size
  end

  private

  def guard
    TravelRouting::RecommendationGuard.new(user: @user, now: @now, provider: @provider)
  end

  def stub_provider(result)
    calls = @calls
    @provider.define_singleton_method(:call) do |**request|
      calls << request
      result
    end
  end

  def route_result(**changes)
    TravelRouting::GoogleRoutesProvider::Result.new(**{
      code: 'ok', duration_seconds: 1800, distance_meters: 2400, walking_seconds: 300,
      departure_time: (@now + 32.hours + 30.minutes).iso8601,
      arrival_time: (@now + 33.hours).iso8601, attribution: 'Google Maps'
    }.merge(changes))
  end

  def proposal
    travel_start, travel_end, main_start, main_end = [32.hours + 30.minutes, 33.hours, 33.hours + 15.minutes, 34.hours + 15.minutes].map { |offset| (@now + offset).iso8601 }
    {
      'kind' => 'draft_event', 'title' => '移動込み: 会議', 'start_at' => travel_start, 'end_at' => main_end, 'all_day' => false,
      'payload' => {
        'events' => [
          { 'title' => '移動', 'start_at' => travel_start, 'end_at' => travel_end, 'all_day' => false, 'location' => 'Synthetic destination' },
          { 'title' => '会議', 'start_at' => main_start, 'end_at' => main_end, 'all_day' => false, 'location' => 'Synthetic destination' }
        ],
        'routing' => {
          'source' => 'google_routes', 'request' => { 'origin' => 'Synthetic origin', 'destination' => 'Synthetic destination', 'mode' => 'TRANSIT', 'arrival_time' => travel_end },
          'result' => route_result.to_h.stringify_keys.except('code', 'attribution'), 'checked_at' => @now.iso8601,
          'arrival_buffer_minutes' => 15
        }
      }
    }
  end

  def prepare(candidate = proposal)
    guard.prepare_response(assistant_message: '移動候補です。', recommendations: [candidate],
      routes_provenance: TravelRouting::RecommendationGuard::LOCAL_PROVENANCE)
  end

  def persist_prepared(candidate = proposal)
    attrs = prepare(candidate).fetch(:recommendations).sole
    @conversation.ai_recommendations.create!(user: @user, kind: attrs['kind'], title: attrs['title'],
      start_at: attrs['start_at'], end_at: attrs['end_at'], all_day: false, payload: attrs['payload'])
  end

  def create_event(user: @user, **attributes)
    user.created_events.create!({ title: 'Synthetic busy', color: '#3b82f6' }.merge(attributes))
  end
end

# Separate committed fixtures let another connection genuinely contend for the
# row locks; transaction-wrapped fixtures would be invisible to that connection.
class TravelRoutingRecommendationGuardConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test 'acceptance blocks owned and participating event updates until its transaction finishes' do
    assert_equal 'PostgreSQL', Event.connection.adapter_name
    now = Time.utc(2026, 9, 19, 0)
    user = User.create!(name: 'Route lock owner', email: "route-lock-#{SecureRandom.hex(6)}@example.invalid", password: 'password123')
    other = User.create!(name: 'Route lock other', email: "route-lock-other-#{SecureRandom.hex(6)}@example.invalid", password: 'password123')
    owned = user.created_events.create!(title: 'Earlier owned event', start_at: now + 1.hour, end_at: now + 2.hours, color: '#3b82f6')
    participating = other.created_events.create!(title: 'Earlier participating event', start_at: now + 3.hours, end_at: now + 4.hours, color: '#3b82f6')
    EventParticipant.create!(event: participating, user: user, source: :copied)
    conversation = AiConversation.create!(user: user, scope_type: 'home')
    departure, arrival = now + 32.hours, now + 33.hours
    result = TravelRouting::GoogleRoutesProvider::Result.new(code: 'ok', duration_seconds: 3600,
      distance_meters: 5000, walking_seconds: 0, departure_time: departure.iso8601,
      arrival_time: arrival.iso8601, attribution: 'Google Maps')
    candidate = {
      'kind' => 'draft_event', 'title' => '移動',
      'payload' => {
        'events' => [{ 'title' => '移動', 'start_at' => departure.iso8601, 'end_at' => arrival.iso8601, 'all_day' => false }],
        'routing' => {
          'source' => 'google_routes',
          'request' => { 'origin' => 'Synthetic origin', 'destination' => 'Synthetic destination', 'mode' => 'DRIVE', 'departure_time' => departure.iso8601 },
          'result' => result.to_h.stringify_keys.except('code', 'attribution'), 'checked_at' => now.iso8601
        }
      }
    }
    prepared = TravelRouting::RecommendationGuard.prepare_response({ recommendations: [candidate],
      routes_provenance: TravelRouting::RecommendationGuard::LOCAL_PROVENANCE }, user: user, now: now)
    recommendation = conversation.ai_recommendations.create!(user: user, kind: 'draft_event', title: '移動',
      payload: prepared.fetch(:recommendations).sole.fetch('payload'))
    attempts = []
    provider = Object.new
    provider.define_singleton_method(:call) do |**_request|
      [owned, participating].each do |event|
        attempts << Thread.new do
          Event.connection_pool.with_connection do |connection|
            begin
              connection.transaction do
                connection.execute("SET LOCAL lock_timeout = '150ms'")
                Event.where(id: event.id).update_all(start_at: departure + 5.minutes, end_at: arrival - 5.minutes)
              end
              :updated
            rescue ActiveRecord::LockWaitTimeout
              :blocked
            end
          end
        end.value
      end
      result
    end

    ActiveRecord::Base.transaction do
      user.lock!
      recommendation.lock!
      assert TravelRouting::RecommendationGuard.new(user: user, now: now, provider: provider).revalidate!(recommendation)
      assert_equal [:blocked, :blocked], attempts
      assert_equal now + 1.hour, owned.reload.start_at
      assert_equal now + 3.hours, participating.reload.start_at
    end

    # The same update becomes possible after the accepting transaction releases
    # its locks, rather than being globally prohibited by a model/controller rule.
    assert_equal 2, Event.where(id: [owned.id, participating.id]).update_all(start_at: departure + 5.minutes, end_at: arrival - 5.minutes)
  ensure
    conversation&.destroy! if conversation&.persisted?
    [owned, participating].compact.each { |event| event.destroy! if event.persisted? }
    [user, other].compact.each { |record| record.destroy! if record.persisted? }
  end
end
