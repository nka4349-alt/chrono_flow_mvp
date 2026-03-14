# frozen_string_literal: true

class CreateEventParticipants < ActiveRecord::Migration[7.0]
  def change
    create_table :event_participants do |t|
      t.references :event, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :source, null: false, default: 0

      t.timestamps
    end

    add_index :event_participants, %i[event_id user_id], unique: true
    add_index :event_participants, %i[user_id event_id]
  end
end
