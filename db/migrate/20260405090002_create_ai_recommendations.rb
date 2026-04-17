# frozen_string_literal: true

class CreateAiRecommendations < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_recommendations do |t|
      t.references :ai_conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :group, null: true, foreign_key: true
      t.string :kind, null: false
      t.integer :status, null: false, default: 0
      t.string :title, null: false
      t.text :description
      t.text :reason
      t.datetime :start_at
      t.datetime :end_at
      t.boolean :all_day, null: false, default: false
      t.references :source_event, null: true, foreign_key: { to_table: :events }
      t.references :created_event, null: true, foreign_key: { to_table: :events }
      t.jsonb :payload, null: false, default: {}

      t.timestamps
    end

    add_index :ai_recommendations, %i[ai_conversation_id status created_at], name: 'index_ai_recommendations_on_conversation_status_created'
    add_index :ai_recommendations, %i[user_id status], name: 'index_ai_recommendations_on_user_status'
    add_index :ai_recommendations, :kind
  end
end
