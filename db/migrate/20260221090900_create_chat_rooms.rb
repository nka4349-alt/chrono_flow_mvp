# frozen_string_literal: true

class CreateChatRooms < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_rooms, if_not_exists: true do |t|
      t.string :chatable_type, null: false
      t.bigint :chatable_id, null: false
      t.timestamps
    end

    add_index :chat_rooms, %i[chatable_type chatable_id],
              unique: true,
              name: "index_chat_rooms_on_chatable",
              if_not_exists: true
  end
end
