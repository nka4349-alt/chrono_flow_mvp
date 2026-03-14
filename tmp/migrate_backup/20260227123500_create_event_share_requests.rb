# frozen_string_literal: true

class CreateEventShareRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :event_share_requests do |t|
      t.references :event, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :target_user, null: false, foreign_key: { to_table: :users }
      t.references :target_group, null: true, foreign_key: { to_table: :groups }

      # 0: add_to_user, 1: add_to_group
      t.integer :purpose, null: false, default: 0

      # 0: pending, 1: approved, 2: rejected
      t.integer :status, null: false, default: 0

      t.text :note
      t.datetime :responded_at

      t.timestamps
    end

    add_index :event_share_requests,
              %i[event_id target_user_id target_group_id purpose],
              unique: true,
              name: 'index_event_share_requests_unique'
  end
end
