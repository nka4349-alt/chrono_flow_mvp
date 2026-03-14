# frozen_string_literal: true

class CreateNotifications < ActiveRecord::Migration[7.1]
  def change
    # SQLite uses :json (stored as TEXT) rather than :jsonb.
    create_table :notifications, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :kind, null: false, default: 0
      t.json :payload, null: false, default: {}
      t.datetime :read_at
      t.timestamps
    end

    add_index :notifications, %i[user_id read_at], if_not_exists: true
  end
end
