# frozen_string_literal: true

class CreateAiMemoryTables < ActiveRecord::Migration[7.1]
  def change
    create_table :user_places do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :label, null: false
      t.string :place_name, null: false
      t.string :address_text
      t.text :notes
      t.string :source, null: false, default: 'ai'
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :user_places, %i[user_id kind]
    add_index :user_places, %i[user_id active]

    create_table :user_travel_routes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :origin_name, null: false
      t.string :origin_kind
      t.string :destination_name, null: false
      t.integer :travel_minutes, null: false
      t.string :transport_mode
      t.integer :arrival_buffer_minutes
      t.text :notes
      t.string :source, null: false, default: 'ai'
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :user_travel_routes, %i[user_id origin_name destination_name], name: 'idx_user_travel_routes_on_user_origin_destination'
    add_index :user_travel_routes, %i[user_id active]

    create_table :ai_user_preferences do |t|
      t.references :user, null: false, foreign_key: true
      t.string :key, null: false
      t.text :value, null: false
      t.string :value_type
      t.string :source, null: false, default: 'ai'

      t.timestamps
    end

    add_index :ai_user_preferences, %i[user_id key], unique: true
  end
end
