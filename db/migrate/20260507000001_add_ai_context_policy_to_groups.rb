# frozen_string_literal: true

class AddAiContextPolicyToGroups < ActiveRecord::Migration[7.1]
  def up
    add_column :groups, :ai_context_mode, :string, null: false, default: 'personal_simple' unless column_exists?(:groups, :ai_context_mode)
    add_column :groups, :inheritance_mode, :string, null: false, default: 'none' unless column_exists?(:groups, :inheritance_mode)

    add_index :groups, :ai_context_mode unless index_exists?(:groups, :ai_context_mode)
    add_index :groups, :inheritance_mode unless index_exists?(:groups, :inheritance_mode)
  end

  def down
    remove_index :groups, :inheritance_mode if index_exists?(:groups, :inheritance_mode)
    remove_index :groups, :ai_context_mode if index_exists?(:groups, :ai_context_mode)
    remove_column :groups, :inheritance_mode if column_exists?(:groups, :inheritance_mode)
    remove_column :groups, :ai_context_mode if column_exists?(:groups, :ai_context_mode)
  end
end
