# frozen_string_literal: true

class CreateEventShares < ActiveRecord::Migration[7.1]
  def change
    # SQLite uses :json (stored as TEXT) rather than :jsonb.
    create_table :event_shares, if_not_exists: true do |t|
      t.references :event, null: false, foreign_key: true
      t.references :actor, null: false, foreign_key: { to_table: :users }
      t.references :to_group, null: true, foreign_key: { to_table: :groups }
      t.references :to_user, null: true, foreign_key: { to_table: :users }

      t.string :action, null: false
      t.json :payload, null: false, default: {}
      t.timestamps
    end

    add_index :event_shares, :action, if_not_exists: true
    add_index :event_shares, %i[event_id created_at], if_not_exists: true
  end
end
