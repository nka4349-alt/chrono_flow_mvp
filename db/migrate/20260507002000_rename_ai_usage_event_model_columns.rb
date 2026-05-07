# frozen_string_literal: true

class RenameAiUsageEventModelColumns < ActiveRecord::Migration[7.1]
  def change
    return unless table_exists?(:ai_usage_events)

    if column_exists?(:ai_usage_events, :model_name) && !column_exists?(:ai_usage_events, :ai_model_name)
      rename_column :ai_usage_events, :model_name, :ai_model_name
    end

    if column_exists?(:ai_usage_events, :model_version) && !column_exists?(:ai_usage_events, :ai_model_version)
      rename_column :ai_usage_events, :model_version, :ai_model_version
    end
  end
end
