# frozen_string_literal: true

class AccountDeletionService
  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    raise ArgumentError, 'user is required' if @user.blank?

    ActiveRecord::Base.transaction do
      @user = User.lock.find(@user.id)
      @user_id = @user.id
      target_event_ids = affected_event_ids
      SecretaryMutation::AdvisoryLock.acquire_targets!(event_ids: target_event_ids)
      Event.where(id: target_event_ids).order(:id).lock.load
      Group.where(owner_id: user_id).order(:id).lock.load
      unless affected_event_ids == target_event_ids
        raise SecretaryMutation::NativeWriterGuard::TargetSetChanged,
          'account deletion event targets changed while waiting'
      end

      destroy_created_events!
      destroy_user_messages!
      destroy_direct_chats!
      detach_linked_contacts!
      destroy_friendships!
      destroy_user_event_requests!
      destroy_user_event_share_requests!
      destroy_user_event_shares!
      destroy_user_access_grants!
      destroy_user_event_types!
      transfer_or_destroy_owned_groups!
      destroy_ai_context_access_logs!

      @user.destroy!
    end
  end

  private

  attr_reader :user_id

  def affected_event_ids
    ids = []
    ids.concat(Event.where(created_by_id: user_id).pluck(:id))
    ids.concat(EventParticipant.where(user_id: user_id).pluck(:event_id))
    ids.concat(EventReminder.where(user_id: user_id).pluck(:event_id))
    ids.concat(EventRequest.where('target_user_id = :id OR requested_by_id = :id', id: user_id).pluck(:event_id))
    ids.concat(EventShareRequest.where(
      'requested_by_id = :id OR responded_by_id = :id OR (target_type = :type AND target_id = :id)',
      id: user_id, type: 'User'
    ).pluck(:event_id))
    ids.concat(EventShare.where('actor_id = :id OR to_user_id = :id', id: user_id).pluck(:event_id))
    ids.concat(EventAccessGrant.where(
      'granted_by_id = :id OR (principal_type = :type AND principal_id = :id)',
      id: user_id, type: 'User'
    ).pluck(:event_id))
    ids.concat(AiContextAccessLog.where(user_id: user_id).where.not(event_id: nil).pluck(:event_id))
    ids.concat(AiRecommendation.where(user_id: user_id).pluck(:source_event_id, :created_event_id).flatten)
    ids.concat(Notification.where(user_id: user_id)
      .where("(payload ->> 'event_id') ~ '^[0-9]+$'")
      .pluck(Arel.sql("(payload ->> 'event_id')::bigint")))
    ids.concat(Message.joins(:chat_room)
      .where(user_id: user_id, chat_rooms: { chatable_type: 'Event' }).pluck('chat_rooms.chatable_id'))
    ids.concat(EventGroup.where(group_id: Group.where(owner_id: user_id)).pluck(:event_id))

    ids = ids.compact.map(&:to_i).select(&:positive?).uniq
    parent_ids = Event.where(id: ids).where.not(parent_id: nil).pluck(:parent_id)
    child_ids = Event.where(parent_id: ids).pluck(:id)
    (ids + parent_ids + child_ids).uniq.sort
  end

  def destroy_created_events!
    Event.where(created_by_id: user_id).find_each(&:destroy!)
  end

  def destroy_user_messages!
    Message.where(user_id: user_id).find_each(&:destroy!)
  end

  def destroy_direct_chats!
    DirectChat.where('user_a_id = :id OR user_b_id = :id', id: user_id).find_each(&:destroy!)
  end

  def detach_linked_contacts!
    Contact.where(linked_user_id: user_id).update_all(linked_user_id: nil, updated_at: Time.current)
  end

  def destroy_friendships!
    connection = Friendship.connection
    quoted_user_id = connection.quote(user_id)
    friendship_ids = connection.select_values(
      "SELECT id FROM friendships WHERE user_id = #{quoted_user_id} OR friend_id = #{quoted_user_id}"
    )
    return if friendship_ids.empty?

    Contact.where(friendship_id: friendship_ids).update_all(friendship_id: nil, updated_at: Time.current)
    quoted_ids = friendship_ids.map { |id| connection.quote(id) }.join(', ')
    connection.execute("DELETE FROM friendships WHERE id IN (#{quoted_ids})")
  end

  def destroy_user_event_requests!
    EventRequest
      .where('target_user_id = :id OR requested_by_id = :id', id: user_id)
      .find_each(&:destroy!)
  end

  def destroy_user_event_share_requests!
    EventShareRequest
      .where(
        'requested_by_id = :id OR responded_by_id = :id OR (target_type = :target_type AND target_id = :id)',
        id: user_id,
        target_type: 'User'
      )
      .find_each(&:destroy!)
  end

  def destroy_user_event_shares!
    EventShare.where('actor_id = :id OR to_user_id = :id', id: user_id).delete_all
  end

  def destroy_user_access_grants!
    EventAccessGrant
      .where('granted_by_id = :id OR (principal_type = :principal_type AND principal_id = :id)', id: user_id, principal_type: 'User')
      .find_each(&:destroy!)

    GroupAccessGrant
      .where('granted_by_id = :id OR (principal_type = :principal_type AND principal_id = :id)', id: user_id, principal_type: 'User')
      .find_each(&:destroy!)
  end

  def destroy_user_event_types!
    EventType.where(user_id: user_id).find_each(&:destroy!)
  end

  def transfer_or_destroy_owned_groups!
    Group.where(owner_id: user_id).find_each do |group|
      next_owner = next_group_owner_for(group)

      if next_owner
        next_owner.update!(role: :admin) if next_owner.respond_to?(:role=)
        group.update!(owner_id: next_owner.user_id)
      else
        group.destroy!
      end
    end
  end

  def next_group_owner_for(group)
    group
      .group_members
      .where.not(user_id: user_id)
      .order(Arel.sql('CASE WHEN role = 1 THEN 0 ELSE 1 END'), :created_at, :id)
      .first
  end

  def destroy_ai_context_access_logs!
    AiContextAccessLog.where(user_id: user_id).delete_all
  end
end
