# frozen_string_literal: true

class CreateEventReminders < ActiveRecord::Migration[7.1]
  def change
    create_table :event_reminders do |t|
      t.references :user, null: false, foreign_key: true
      t.references :event, null: false, foreign_key: true
      t.datetime :remind_at, null: false
      t.integer :minutes_before, null: false, default: 30
      t.integer :status, null: false, default: 0
      t.datetime :delivered_at
      t.jsonb :payload, null: false, default: {}

      t.timestamps
    end

    add_index :event_reminders, [:user_id, :status, :remind_at]
    add_index :event_reminders, [:event_id, :user_id, :remind_at], unique: true, name: 'index_event_reminders_unique_event_user_time'
  end
end
