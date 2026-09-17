# frozen_string_literal: true

require 'test_helper'
require 'securerandom'
require 'time'

class AiRecommendationsCompactClockTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = true

  test 'accepting a compact 2300 candidate preserves midnight and repeated acceptance creates nothing' do
    Time.use_zone('Asia/Tokyo') do
      travel_to(Time.zone.local(2026, 9, 17, 22, 13)) do
        user = User.create!(
          name: 'Synthetic Compact Clock User',
          email: "compact-clock-#{SecureRandom.hex(6)}@example.invalid",
          password: 'password123'
        )
        conversation = AiConversation.create!(user: user, scope_type: 'home', last_used_at: Time.current)
        post '/login', params: { email: user.email, password: 'password123' }
        assert_response :redirect

        context = {
          scope: 'home', timezone: 'Asia/Tokyo', now: Time.current.iso8601,
          personal_events: [], peer_events: [], contacts: [], friends: []
        }
        client = Ai::Client.new(context: context, user_message: '今日の2300に会議')
        remote_called = false
        client.define_singleton_method(:request_remote) do
          remote_called = true
          raise 'Unexpected remote request in compact-clock acceptance regression'
        end

        assert_no_difference(['EventReminder.count', 'Notification.count']) do
          ai_response = nil
          assert_no_difference(['Event.count', 'EventParticipant.count']) { ai_response = client.call }
          refute remote_called
          assert_empty ai_response.fetch(:tool_invocations)
          assert_equal 1, ai_response.fetch(:recommendations).length
          candidate = ai_response.fetch(:recommendations).sole
          expected_start = Time.zone.local(2026, 9, 17, 23, 0)
          expected_end = Time.zone.local(2026, 9, 18, 0, 0)

          assert_equal 'draft_event', candidate.fetch('kind')
          [candidate, candidate.fetch('payload')].each do |attributes|
            assert_equal '会議', attributes.fetch('title')
            assert_equal expected_start, Time.iso8601(attributes.fetch('start_at'))
            assert_equal expected_end, Time.iso8601(attributes.fetch('end_at'))
            assert_equal false, attributes.fetch('all_day')
          end

          recommendation = nil
          assert_no_difference(['Event.count', 'EventParticipant.count']) do
            recommendation = conversation.ai_recommendations.create!(
              user: user,
              kind: candidate.fetch('kind'),
              title: candidate.fetch('title'),
              description: candidate['description'],
              reason: candidate['reason'],
              start_at: candidate.fetch('start_at'),
              end_at: candidate.fetch('end_at'),
              all_day: candidate.fetch('all_day'),
              payload: candidate.fetch('payload')
            )
          end
          assert recommendation.pending?
          assert_nil recommendation.created_event_id

          assert_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count'], 1) do
            post "/api/ai_recommendations/#{recommendation.id}/accept_copy", as: :json
          end
          assert_response :success
          accepted = JSON.parse(response.body)
          assert_equal true, accepted.fetch('ok')
          assert_nil accepted.fetch('reminder')
          assert_equal 1, accepted.fetch('events').length

          event = recommendation.reload.created_event
          assert recommendation.accepted_copy?
          assert_not_nil event
          assert_equal event.id, accepted.fetch('event').fetch('id')
          assert_equal event.id, accepted.fetch('recommendation').fetch('created_event_id')
          assert_equal '会議', event.title
          assert_equal user.id, event.created_by_id
          assert_equal expected_start, event.start_at
          assert_equal expected_end, event.end_at
          assert_equal 60.minutes, event.end_at - event.start_at
          assert_equal false, event.all_day
          assert_equal false, accepted.fetch('event').fetch('all_day')
          assert_equal expected_end, Time.iso8601(accepted.fetch('event').fetch('end_at'))
          participant = event.event_participants.sole
          assert_equal user.id, participant.user_id
          assert participant.copied?
          assert recommendation.ai_recommendation_feedbacks.sole.accepted_copy?

          assert_no_difference(['Event.count', 'EventParticipant.count', 'AiRecommendationFeedback.count']) do
            post "/api/ai_recommendations/#{recommendation.id}/accept_copy", as: :json
          end
          assert_response :success
          repeated = JSON.parse(response.body)
          assert_equal true, repeated.fetch('ok')
          assert_equal 'accepted_copy', repeated.fetch('recommendation').fetch('status')
          assert_equal event.id, repeated.fetch('recommendation').fetch('created_event_id')
          assert_equal event.id, recommendation.reload.created_event_id
        end
      end
    end
  end
end
