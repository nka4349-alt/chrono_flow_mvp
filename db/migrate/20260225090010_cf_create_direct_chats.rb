# frozen_string_literal: true

class CfCreateDirectChats < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:direct_chats)

    create_table :direct_chats do |t|
      t.bigint :user_a_id, null: false
      t.bigint :user_b_id, null: false
      t.timestamps
    end

    add_index :direct_chats, %i[user_a_id user_b_id], unique: true
    add_index :direct_chats, :user_b_id
  end
end
