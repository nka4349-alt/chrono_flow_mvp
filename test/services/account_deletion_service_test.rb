# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class AccountDeletionServiceTest < ActiveSupport::TestCase
  PASSWORD = 'Password-123!'

  test 'deletes user and created events' do
    user = create_user
    event = Event.create!(
      title: '削除対象予定',
      created_by: user,
      start_at: Time.zone.parse('2026-06-01 10:00'),
      end_at: Time.zone.parse('2026-06-01 11:00'),
      color: '#3b82f6'
    )

    AccountDeletionService.call(user)

    refute User.exists?(user.id)
    refute Event.exists?(event.id)
  end

  test 'deletes ai memories' do
    user = create_user
    UserPlace.create!(user: user, kind: 'home', label: '自宅', place_name: '天王寺駅')
    UserTravelRoute.create!(user: user, origin_name: '自宅', destination_name: '大阪駅', travel_minutes: 30)
    AiUserPreference.create!(user: user, key: 'arrival_buffer.meeting', value: '15', value_type: 'integer')

    AccountDeletionService.call(user)

    assert_empty UserPlace.where(user_id: user.id)
    assert_empty UserTravelRoute.where(user_id: user.id)
    assert_empty AiUserPreference.where(user_id: user.id)
  end

  test 'transfers owned group to another member before deleting user' do
    owner = create_user
    member = create_user
    group = Group.create!(name: '共有グループ', owner_id: owner.id)
    GroupMember.create!(group: group, user: owner, role: :admin)
    GroupMember.create!(group: group, user: member, role: :member)

    AccountDeletionService.call(owner)

    assert_equal member.id, group.reload.owner_id
    assert_equal 'admin', GroupMember.find_by!(group: group, user: member).role
    refute GroupMember.exists?(group: group, user_id: owner.id)
    refute User.exists?(owner.id)
  end

  test 'destroys sole owned group' do
    owner = create_user
    group = Group.create!(name: '個人グループ', owner_id: owner.id)
    GroupMember.create!(group: group, user: owner, role: :admin)

    AccountDeletionService.call(owner)

    refute Group.exists?(group.id)
    refute User.exists?(owner.id)
  end

  test 'removes direct chat, friendship, linked contact, and user messages' do
    user = create_user
    friend = create_user
    friendship = Friendship.create!(user: user, friend: friend)
    Contact.create!(user: friend, linked_user: user, friendship: friendship, display_name: '削除対象ユーザー')
    direct_chat = DirectChat.create!(user_a: user, user_b: friend)
    chat_room = ChatRoom.create!(chatable: direct_chat)
    Message.create!(chat_room: chat_room, user: user, body: '削除されるメッセージ')
    Message.create!(chat_room: chat_room, user: friend, body: '関連チャットのメッセージ')

    AccountDeletionService.call(user)

    refute User.exists?(user.id)
    refute Friendship.exists?(friendship.id)
    refute DirectChat.exists?(direct_chat.id)
    assert_empty Message.where(user_id: user.id)
    assert_nil Contact.find_by!(user: friend).linked_user_id
    assert_nil Contact.find_by!(user: friend).friendship_id
  end

  private

  def create_user
    User.create!(
      name: 'Delete Service User',
      email: "delete-service-#{SecureRandom.hex(6)}@example.com",
      password: PASSWORD,
      password_confirmation: PASSWORD
    )
  end
end
