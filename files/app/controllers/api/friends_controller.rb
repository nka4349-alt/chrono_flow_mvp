# frozen_string_literal: true

module Api
  class FriendsController < BaseController
    # GET /api/friends
    def index
      # MVP: friendship is symmetric. We accept either direction.
      ids = Friendship.where(user_id: current_user.id).pluck(:friend_id) +
            Friendship.where(friend_id: current_user.id).pluck(:user_id)

      friends = User.where(id: ids.uniq).order(:name, :id)

      render json: {
        friends: friends.map { |u| { id: u.id, name: u.name } }
      }
    end
  end
end
