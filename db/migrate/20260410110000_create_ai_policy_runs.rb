# frozen_string_literal: true

class CreateAiPolicyRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_policy_runs do |t|
      t.references :ai_conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :group, foreign_key: true
      t.string :scope_type, null: false
      t.string :provider, null: false, default: 'rules-v4-work-intent'
      t.string :policy_version
      t.string :request_kind, null: false, default: 'chat_message'
      t.integer :duration_ms
      t.text :user_message
      t.text :assistant_message
      t.jsonb :prompt_snapshot, null: false, default: {}
      t.jsonb :context_snapshot, null: false, default: {}
      t.jsonb :result_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :ai_policy_runs, %i[ai_conversation_id created_at], name: 'index_ai_policy_runs_on_conversation_and_created'
    add_index :ai_policy_runs, %i[user_id created_at], name: 'index_ai_policy_runs_on_user_and_created'
    add_index :ai_policy_runs, %i[provider policy_version], name: 'index_ai_policy_runs_on_provider_and_policy'
  end
end
