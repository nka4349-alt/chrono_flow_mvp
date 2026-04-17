# frozen_string_literal: true

class CreateAiRecommendationImpressions < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_recommendation_impressions do |t|
      t.references :ai_policy_run, null: false, foreign_key: true
      t.references :ai_conversation, null: false, foreign_key: true
      t.references :ai_recommendation, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :group, foreign_key: true
      t.integer :rank_position, null: false, default: 1
      t.string :kind, null: false
      t.string :recommendation_status, null: false, default: 'pending'
      t.string :interaction_label
      t.datetime :interacted_at
      t.string :title
      t.datetime :start_at
      t.datetime :end_at
      t.jsonb :payload_snapshot, null: false, default: {}
      t.jsonb :features, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :ai_recommendation_impressions, %i[ai_policy_run_id rank_position], name: 'index_ai_recommendation_impressions_on_policy_and_rank'
    add_index :ai_recommendation_impressions, %i[ai_recommendation_id created_at], name: 'index_ai_reco_impressions_on_recommendation_and_created'
    add_index :ai_recommendation_impressions, %i[user_id created_at], name: 'index_ai_reco_impressions_on_user_and_created'
    add_index :ai_recommendation_impressions, :interaction_label
  end
end
