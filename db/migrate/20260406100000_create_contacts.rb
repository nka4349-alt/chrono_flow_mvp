# frozen_string_literal: true

class CreateContacts < ActiveRecord::Migration[7.1]
  def change
    create_table :contacts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :linked_user, null: true, foreign_key: { to_table: :users }
      t.references :friendship, null: true, foreign_key: true
      t.string :display_name, null: false
      t.integer :relation_type, null: false, default: 0
      t.integer :source_kind, null: false, default: 0
      t.text :notes
      t.integer :preferred_duration_minutes
      t.boolean :active, null: false, default: true
      t.string :timezone, null: false, default: 'Asia/Tokyo'
      t.timestamps
    end

    add_index :contacts, [:user_id, :display_name]
    add_index :contacts, [:user_id, :linked_user_id], unique: true
  end
end
