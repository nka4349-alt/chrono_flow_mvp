# frozen_string_literal: true

class CreateAiContextAccessLogs < ActiveRecord::Migration[7.1]
  def up
    return if table_exists?(:ai_context_access_logs)

    create_table :ai_context_access_logs do |t|
      t.references :user, null: false, foreign_key: true
      t.references :event, foreign_key: true
      t.references :group, foreign_key: true
      t.string :source_type, null: false
      t.string :permission_used, null: false
      t.string :masked_level
      t.string :ai_context_mode, null: false
      t.string :request_id, null: false
      t.timestamps
    end

    add_index :ai_context_access_logs,
              %i[request_id event_id source_type],
              name: 'idx_ai_context_access_logs_request_event'
    add_index :ai_context_access_logs,
              %i[user_id created_at],
              name: 'idx_ai_context_access_logs_user_created'
    add_index :ai_context_access_logs,
              %i[ai_context_mode permission_used],
              name: 'idx_ai_context_access_logs_mode_permission'
  end

  def down
    drop_table :ai_context_access_logs if table_exists?(:ai_context_access_logs)
  end
end
