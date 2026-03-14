# frozen_string_literal: true

module Api
  # Friends list for personal-mode sidebar
  #
  # Route (added by patcher):
  #   GET /api/friends
  class FriendsController < BaseController
    def index
      return render(json: { friends: [] }) unless defined?(Friendship)

      uid = current_user.id
      ids = []
      ids.concat Friendship.where(user_id: uid).pluck(:friend_id)
      ids.concat Friendship.where(friend_id: uid).pluck(:user_id)
      ids = ids.compact.map(&:to_i).uniq

      users = User.where(id: ids).order(:id)

      friends = users.map do |u|
        {
          id: u.id,
          name: (u.respond_to?(:display_name) ? u.display_name : (u.try(:name) || u.try(:email) || 'user')),
          email: (u.respond_to?(:email) ? u.email : nil)
        }
      end

      render json: { friends: friends }
    end
  end
end
