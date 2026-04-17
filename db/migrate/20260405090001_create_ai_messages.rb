# frozen_string_literal: true

class CreateAiMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_messages do |t|
      t.references :ai_conversation, null: false, foreign_key: true
      t.integer :role, null: false, default: 0
      t.text :body, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :ai_messages, %i[ai_conversation_id created_at], name: 'index_ai_messages_on_conversation_and_created'
  end
end
