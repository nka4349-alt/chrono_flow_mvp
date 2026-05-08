class AllowEventDeleteWithAiContextLogs < ActiveRecord::Migration[7.1]
  def up
    replace_event_foreign_key(:ai_context_access_logs, on_delete: :nullify)
    replace_event_foreign_key(:event_access_grants, on_delete: :cascade)
  end

  def down
    replace_event_foreign_key(:ai_context_access_logs)
    replace_event_foreign_key(:event_access_grants)
  end

  private

  def replace_event_foreign_key(from_table, **options)
    return unless table_exists?(from_table) && table_exists?(:events)

    remove_foreign_key(from_table, :events) if foreign_key_exists?(from_table, :events)
    add_foreign_key(from_table, :events, **options)
  end
end
