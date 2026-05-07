# frozen_string_literal: true

class CreateGroupAccessGrants < ActiveRecord::Migration[7.1]
  def up
    return if table_exists?(:group_access_grants)

    create_table :group_access_grants do |t|
      t.references :group, null: false, foreign_key: true
      t.string :principal_type, null: false
      t.bigint :principal_id, null: false
      t.string :permission, null: false, default: 'free_busy'
      t.references :granted_by, foreign_key: { to_table: :users }
      t.datetime :expires_at
      t.timestamps
    end

    add_index :group_access_grants,
              %i[group_id principal_type principal_id],
              unique: true,
              name: 'idx_group_access_grants_unique_principal'
    add_index :group_access_grants,
              %i[principal_type principal_id],
              name: 'idx_group_access_grants_principal'
    add_index :group_access_grants, :expires_at
  end

  def down
    drop_table :group_access_grants if table_exists?(:group_access_grants)
  end
end
