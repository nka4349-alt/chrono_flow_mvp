# frozen_string_literal: true

class CreateEventGroups < ActiveRecord::Migration[7.0]
  def change
    create_table :event_groups do |t|
      t.references :event, null: false, foreign_key: true
      t.references :group, null: false, foreign_key: true

      t.timestamps
    end

    add_index :event_groups, %i[event_id group_id], unique: true
    add_index :event_groups, %i[group_id event_id]
  end
end
