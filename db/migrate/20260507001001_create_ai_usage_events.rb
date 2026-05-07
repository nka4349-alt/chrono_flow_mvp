# frozen_string_literal: true

class CreateAiUsageEvents < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:ai_usage_events)

    create_table :ai_usage_events do |t|
      t.references :user, null: false, foreign_key: true
      t.references :ai_conversation, foreign_key: true
      t.references :ai_policy_run, foreign_key: true
      t.references :group, foreign_key: true
      t.string :feature_key, null: false, default: 'ai_chat'
      t.string :route, null: false, default: 'unknown'
      t.string :provider, null: false, default: 'unknown'
      t.string :model_name
      t.string :model_version
      t.string :status, null: false, default: 'success'
      t.integer :input_chars, null: false, default: 0
      t.integer :output_chars, null: false, default: 0
      t.integer :recommendation_count, null: false, default: 0
      t.integer :latency_ms
      t.integer :queue_ms
      t.integer :inference_ms
      t.decimal :estimated_cost, precision: 12, scale: 6
      t.string :error_class
      t.text :error_message
      t.string :request_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :ai_usage_events, [:status, :created_at], name: 'idx_ai_usage_events_status_created'
    add_index :ai_usage_events, [:provider, :created_at], name: 'idx_ai_usage_events_provider_created'
    add_index :ai_usage_events, [:user_id, :created_at], name: 'idx_ai_usage_events_user_created'
    add_index :ai_usage_events, :request_id
  end
end
