# frozen_string_literal: true

class CreateEventShareRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :event_share_requests do |t|
      t.references :event, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.integer :status, null: false, default: 0
      t.references :responded_by, null: true, foreign_key: { to_table: :users }
      t.datetime :responded_at
      t.timestamps
    end

    add_index :event_share_requests, [:event_id, :target_type, :target_id], unique: true, name: 'index_event_share_requests_uni'
    add_index :event_share_requests, [:target_type, :target_id], name: 'index_event_share_requests_target'
  end
end
