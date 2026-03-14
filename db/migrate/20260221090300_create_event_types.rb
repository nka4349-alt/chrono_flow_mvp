# frozen_string_literal: true

class CreateEventTypes < ActiveRecord::Migration[7.0]
  def change
    create_table :event_types do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :color
      t.string :icon

      t.timestamps
    end

    add_index :event_types, %i[user_id name], unique: true
  end
end
