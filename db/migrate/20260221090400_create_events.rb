# frozen_string_literal: true

class CreateEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :events do |t|
      t.string :title, null: false
      t.text :description
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.boolean :all_day, null: false, default: false

      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :event_type, foreign_key: true
      t.references :parent, foreign_key: { to_table: :events }

      t.timestamps
    end

    add_index :events, :start_at
    add_index :events, :end_at
  end
end
