# frozen_string_literal: true

require 'test_helper'

class ApiGroupMembersOwnerTransferTest < ActionDispatch::IntegrationTest
  PASSWORD = 'Password-123!'

  setup do
    @owner = create_user('owner-transfer-owner@example.com', 'Owner User')
    @admin = create_user('owner-transfer-admin@example.com', 'Admin User')
    @member = create_user('owner-transfer-member@example.com', 'Member User')
    @outsider = create_user('owner-transfer-outsider@example.com', 'Outsider User')

    @group = Group.create!(name: '管理者変更テスト', owner_id: @owner.id)
    GroupMember.create!(group: @group, user: @owner, role: :admin)
    GroupMember.create!(group: @group, user: @admin, role: :admin)
    GroupMember.create!(group: @group, user: @member, role: :member)
  end

  test 'owner can transfer group ownership to another member' do
    login_as(@owner)

    patch "/api/groups/#{@group.id}/members/#{@member.id}/owner", as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body.fetch('ok')
    assert_equal @member.id, body.fetch('owner_user_id')
    assert_equal @owner.id, body.fetch('previous_owner_user_id')

    assert_equal @member.id, @group.reload.owner_id
    assert_equal 'admin', GroupMember.find_by!(group: @group, user: @member).role
    assert_equal 'admin', GroupMember.find_by!(group: @group, user: @owner).role
  end

  test 'admin cannot transfer group ownership unless they are owner' do
    login_as(@admin)

    patch "/api/groups/#{@group.id}/members/#{@member.id}/owner", as: :json

    assert_response :forbidden
    assert_equal @owner.id, @group.reload.owner_id
  end

  test 'owner cannot transfer ownership to non member' do
    login_as(@owner)

    patch "/api/groups/#{@group.id}/members/#{@outsider.id}/owner", as: :json

    assert_response :not_found
    assert_equal @owner.id, @group.reload.owner_id
  end

  test 'owner cannot transfer ownership to current owner' do
    login_as(@owner)

    patch "/api/groups/#{@group.id}/members/#{@owner.id}/owner", as: :json

    assert_response :bad_request
    assert_equal @owner.id, @group.reload.owner_id
  end

  private

  def create_user(email, name)
    User.create!(
      email: email,
      name: name,
      password: PASSWORD,
      password_confirmation: PASSWORD
    )
  end

  def login_as(user)
    post login_path, params: { email: user.email, password: PASSWORD }
    assert_response :redirect
  end
end
