# frozen_string_literal: true

class CreateEventRequests < ActiveRecord::Migration[7.1]
  def change
    # NOTE:
    # t.references automatically creates an index for *_id columns.
    # Do NOT add a duplicated add_index for group_id, or SQLite will raise
    # "index ... already exists".
    create_table :event_requests, if_not_exists: true do |t|
      t.references :event, null: false, foreign_key: true
      t.references :group, null: false, foreign_key: true

      t.references :target_user, null: false, foreign_key: { to_table: :users }
      t.references :requested_by, null: false, foreign_key: { to_table: :users }

      t.integer :status, null: false, default: 0
      t.text :note
      t.datetime :responded_at

      t.timestamps
    end

    add_index :event_requests, %i[event_id target_user_id],
              unique: true,
              name: "index_event_requests_on_event_id_and_target_user_id",
              if_not_exists: true

    add_index :event_requests, :status, if_not_exists: true
  end
end
