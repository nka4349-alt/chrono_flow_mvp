# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class ApiAiChatsControllerTest < ActionDispatch::IntegrationTest
  test 'blank AI chat body returns Japanese validation error' do
    user = User.create!(
      name: 'Test User',
      email: "ai-chat-empty-#{SecureRandom.hex(6)}@example.com",
      password: 'password123'
    )

    post '/login', params: { email: user.email, password: 'password123' }
    assert_response :redirect

    post '/api/ai_chat/messages', params: { scope: 'home', body: '   ' }, as: :json

    assert_response :bad_request
    assert_equal '入力内容を入れてください。', JSON.parse(response.body).fetch('error')
  end
end
