# frozen_string_literal: true

class CreateAiConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_conversations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :scope_type, null: false
      t.references :group, null: true, foreign_key: true
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :ai_conversations,
              %i[user_id scope_type group_id],
              unique: true,
              where: 'group_id IS NOT NULL',
              name: 'index_ai_conversations_on_user_scope_group'

    add_index :ai_conversations,
              %i[user_id scope_type],
              unique: true,
              where: 'group_id IS NULL',
              name: 'index_ai_conversations_on_user_scope_home'
  end
end
