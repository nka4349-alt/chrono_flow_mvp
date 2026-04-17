# frozen_string_literal: true

class CreateAiRecommendationFeedbacks < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_recommendation_feedbacks do |t|
      t.references :ai_recommendation, null: false, foreign_key: true
      t.references :ai_conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :action, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :ai_recommendation_feedbacks,
              %i[ai_recommendation_id created_at],
              name: 'index_ai_recommendation_feedbacks_on_recommendation_and_created'
  end
end
