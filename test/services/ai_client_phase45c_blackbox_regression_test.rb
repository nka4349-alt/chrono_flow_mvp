# frozen_string_literal: true

require 'test_helper'

class AiClientPhase45cBlackboxRegressionTest < ActiveSupport::TestCase
  BASE_CONTEXT = {
    scope: 'home',
    timezone: 'Asia/Tokyo',
    now: '2026-05-18T08:00:00+09:00',
    personal_events: [],
    peer_events: [],
    contacts: [],
    friends: []
  }.freeze

  TANAKA_EVENT = {
    id: 701,
    title: '田中と打ち合わせ',
    start_at: '2026-05-19T15:00:00+09:00',
    end_at: '2026-05-19T16:00:00+09:00',
    all_day: false
  }.freeze

  def ai_response(message, context: {})
    Ai::Client.call(context: BASE_CONTEXT.merge(context), user_message: message)
  end

  test 'conflict warning exposes the conflicted event name in message and card copy' do
    response = ai_response('明日の15時に30分電話', context: { personal_events: [TANAKA_EVENT] })
    recommendation = response.fetch(:recommendations).first

    assert_includes response.fetch(:assistant_message), '田中と打ち合わせ'
    assert_includes recommendation.fetch('description'), '田中と打ち合わせ'
    assert_includes recommendation.fetch('reason'), '田中と打ち合わせ'
  end

  test 'accepted AI recommendation removes only the accepted card instead of refreshing all candidates' do
    js = Rails.root.join('app/javascript/application.js').read

    assert_includes js, 'function removeAiRecommendationCard'
    assert_includes js, 'removeAiRecommendationCard(recommendationId)'
    assert_includes js, 'keepChatComposerOpenAfterSend()'

    old_accept_refresh = /alert\(aiRecommendationDoneMessage\(recommendationKind, data\)\);\s*await loadAiConversation\(\{ allowSeed: false \}\);\s*collapseChatComposer\(true\);/m
    assert_no_match old_accept_refresh, js
  end
end
