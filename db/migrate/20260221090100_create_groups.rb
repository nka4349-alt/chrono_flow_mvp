# frozen_string_literal: true

class CreateGroups < ActiveRecord::Migration[7.0]
  def change
    create_table :groups do |t|
      t.string :name, null: false
      t.integer :parent_id
      t.integer :position, null: false, default: 0
      t.references :owner, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :groups, :parent_id
  end
end
