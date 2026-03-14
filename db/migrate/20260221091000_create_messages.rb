# frozen_string_literal: true

class CreateMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :messages, if_not_exists: true do |t|
      t.references :chat_room, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false
      t.timestamps
    end

    add_index :messages, %i[chat_room_id created_at], if_not_exists: true
  end
end
