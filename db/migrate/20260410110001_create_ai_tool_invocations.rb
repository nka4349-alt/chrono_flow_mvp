# frozen_string_literal: true

class CreateAiToolInvocations < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_tool_invocations do |t|
      t.references :ai_policy_run, null: false, foreign_key: true
      t.references :ai_conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :tool_name, null: false
      t.string :status, null: false, default: 'success'
      t.integer :position, null: false, default: 0
      t.integer :duration_ms
      t.jsonb :input_payload, null: false, default: {}
      t.jsonb :output_payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :ai_tool_invocations, %i[ai_policy_run_id position], name: 'index_ai_tool_invocations_on_policy_run_and_position'
    add_index :ai_tool_invocations, %i[tool_name created_at], name: 'index_ai_tool_invocations_on_tool_and_created'
  end
end
