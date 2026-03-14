# frozen_string_literal: true

class CreateDirectChats < ActiveRecord::Migration[7.1]
  def change
    create_table :direct_chats do |t|
      t.references :user_a, null: false, foreign_key: { to_table: :users }
      t.references :user_b, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :direct_chats, %i[user_a_id user_b_id], unique: true
  end
end
