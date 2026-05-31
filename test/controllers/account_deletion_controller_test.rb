# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class AccountDeletionControllerTest < ActionDispatch::IntegrationTest
  PASSWORD = 'Password-123!'

  setup do
    @user = create_user
  end

  test 'guest is redirected from delete screen to login' do
    get account_delete_path

    assert_redirected_to login_path
  end

  test 'logged in user can view account delete screen' do
    login_as(@user)

    get account_delete_path

    assert_response :success
    assert_includes response.body, 'アカウント削除'
    assert_includes response.body, '取り消せません'
    assert_includes response.body, 'DELETE'
  end

  test 'blank confirmation does not delete account' do
    login_as(@user)

    assert_no_difference('User.count') do
      delete account_path, params: { confirmation: '' }
    end

    assert_response :unprocessable_entity
    assert User.exists?(@user.id)
    assert_includes response.body, 'DELETE'
  end

  test 'DELETE confirmation deletes account and resets session' do
    login_as(@user)

    assert_difference('User.count', -1) do
      delete account_path, params: { confirmation: 'DELETE' }
    end

    assert_redirected_to login_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, 'アカウントを削除しました'

    get root_path
    assert_redirected_to login_path
  end

  test 'created events are deleted with account' do
    event = Event.create!(
      title: '削除対象予定',
      created_by: @user,
      start_at: Time.zone.parse('2026-06-01 10:00'),
      end_at: Time.zone.parse('2026-06-01 11:00'),
      color: '#3b82f6'
    )

    login_as(@user)
    delete account_path, params: { confirmation: 'DELETE' }

    assert_redirected_to login_path
    refute Event.exists?(event.id)
    assert_equal 0, Event.where(created_by_id: @user.id).count
  end

  test 'ai memories are deleted with account' do
    UserPlace.create!(user: @user, kind: 'home', label: '自宅', place_name: '天王寺駅')
    UserTravelRoute.create!(user: @user, origin_name: '自宅', destination_name: '大阪駅', travel_minutes: 30)
    AiUserPreference.create!(user: @user, key: 'arrival_buffer.meeting', value: '15', value_type: 'integer')

    login_as(@user)
    delete account_path, params: { confirmation: 'DELETE' }

    assert_redirected_to login_path
    assert_empty UserPlace.where(user_id: @user.id)
    assert_empty UserTravelRoute.where(user_id: @user.id)
    assert_empty AiUserPreference.where(user_id: @user.id)
  end

  test 'same email can be registered again after deletion' do
    email = @user.email
    login_as(@user)
    delete account_path, params: { confirmation: 'DELETE' }
    assert_redirected_to login_path

    post signup_path, params: {
      user: {
        name: 'Recreated User',
        email: email,
        password: PASSWORD,
        password_confirmation: PASSWORD
      }
    }

    assert_redirected_to root_path
    assert User.exists?(email: email)
  end

  private

  def create_user
    User.create!(
      name: 'Delete Test User',
      email: "delete-test-#{SecureRandom.hex(6)}@example.com",
      password: PASSWORD,
      password_confirmation: PASSWORD
    )
  end

  def login_as(user)
    post login_path, params: { email: user.email, password: PASSWORD }
    assert_response :redirect
  end
end
