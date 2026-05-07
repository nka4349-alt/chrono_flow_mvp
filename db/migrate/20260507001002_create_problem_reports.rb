# frozen_string_literal: true

class CreateProblemReports < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:problem_reports)

    create_table :problem_reports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :ai_usage_event, foreign_key: true
      t.references :ai_recommendation, foreign_key: true
      t.string :status, null: false, default: 'open'
      t.string :priority, null: false, default: 'normal'
      t.string :category, null: false, default: 'general'
      t.string :subject, null: false
      t.text :body, null: false
      t.string :page_url
      t.string :request_id
      t.string :user_agent
      t.text :admin_notes
      t.datetime :resolved_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :problem_reports, [:status, :created_at], name: 'idx_problem_reports_status_created'
    add_index :problem_reports, [:category, :created_at], name: 'idx_problem_reports_category_created'
    add_index :problem_reports, [:user_id, :created_at], name: 'idx_problem_reports_user_created'
    add_index :problem_reports, :request_id
  end
end
