# frozen_string_literal: true

class CreateAvailabilityProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :availability_profiles do |t|
      t.references :contact, null: false, foreign_key: true
      t.integer :weekday, null: false
      t.integer :start_minute, null: false
      t.integer :end_minute, null: false
      t.integer :preference_kind, null: false, default: 0
      t.integer :source_kind, null: false, default: 0
      t.text :notes
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_index :availability_profiles, [:contact_id, :weekday]
    add_index :availability_profiles,
              [:contact_id, :weekday, :start_minute, :end_minute, :preference_kind],
              unique: true,
              name: 'index_availability_profiles_uniqueness'
  end
end
