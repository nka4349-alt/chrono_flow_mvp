# frozen_string_literal: true

class NullifyAiRecommendationEventRefsOnDelete < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:ai_recommendations) && table_exists?(:events)

    change_event_fk(:source_event_id, on_delete: :nullify)
    change_event_fk(:created_event_id, on_delete: :nullify)
  end

  def down
    return unless table_exists?(:ai_recommendations) && table_exists?(:events)

    change_event_fk(:source_event_id, on_delete: nil)
    change_event_fk(:created_event_id, on_delete: nil)
  end

  private

  def change_event_fk(column, on_delete:)
    return unless column_exists?(:ai_recommendations, column)

    remove_foreign_key :ai_recommendations, column: column if foreign_key_exists?(:ai_recommendations, :events, column: column)

    options = { column: column }
    options[:on_delete] = on_delete if on_delete
    add_foreign_key :ai_recommendations, :events, **options
  end
end
