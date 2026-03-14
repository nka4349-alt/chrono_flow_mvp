# frozen_string_literal: true

class CfCreateFriendships < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:friendships)

    create_table :friendships do |t|
      t.bigint :user_id, null: false
      t.bigint :friend_id, null: false
      t.timestamps
    end

    add_index :friendships, %i[user_id friend_id], unique: true
    add_index :friendships, :friend_id
  end
end
