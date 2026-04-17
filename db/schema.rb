# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_04_10_110002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "ai_conversations", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "scope_type", null: false
    t.bigint "group_id"
    t.datetime "last_used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_ai_conversations_on_group_id"
    t.index ["user_id", "scope_type", "group_id"], name: "index_ai_conversations_on_user_scope_group", unique: true, where: "(group_id IS NOT NULL)"
    t.index ["user_id", "scope_type"], name: "index_ai_conversations_on_user_scope_home", unique: true, where: "(group_id IS NULL)"
    t.index ["user_id"], name: "index_ai_conversations_on_user_id"
  end

  create_table "ai_messages", force: :cascade do |t|
    t.bigint "ai_conversation_id", null: false
    t.integer "role", default: 0, null: false
    t.text "body", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_conversation_id", "created_at"], name: "index_ai_messages_on_conversation_and_created"
    t.index ["ai_conversation_id"], name: "index_ai_messages_on_ai_conversation_id"
  end

  create_table "ai_policy_runs", force: :cascade do |t|
    t.bigint "ai_conversation_id", null: false
    t.bigint "user_id", null: false
    t.bigint "group_id"
    t.string "scope_type", null: false
    t.string "provider", default: "rules-v4-work-intent", null: false
    t.string "policy_version"
    t.string "request_kind", default: "chat_message", null: false
    t.integer "duration_ms"
    t.text "user_message"
    t.text "assistant_message"
    t.jsonb "prompt_snapshot", default: {}, null: false
    t.jsonb "context_snapshot", default: {}, null: false
    t.jsonb "result_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_conversation_id", "created_at"], name: "index_ai_policy_runs_on_conversation_and_created"
    t.index ["ai_conversation_id"], name: "index_ai_policy_runs_on_ai_conversation_id"
    t.index ["group_id"], name: "index_ai_policy_runs_on_group_id"
    t.index ["provider", "policy_version"], name: "index_ai_policy_runs_on_provider_and_policy"
    t.index ["user_id", "created_at"], name: "index_ai_policy_runs_on_user_and_created"
    t.index ["user_id"], name: "index_ai_policy_runs_on_user_id"
  end

  create_table "ai_recommendation_feedbacks", force: :cascade do |t|
    t.bigint "ai_recommendation_id", null: false
    t.bigint "ai_conversation_id", null: false
    t.bigint "user_id", null: false
    t.integer "action", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_conversation_id"], name: "index_ai_recommendation_feedbacks_on_ai_conversation_id"
    t.index ["ai_recommendation_id", "created_at"], name: "index_ai_recommendation_feedbacks_on_recommendation_and_created"
    t.index ["ai_recommendation_id"], name: "index_ai_recommendation_feedbacks_on_ai_recommendation_id"
    t.index ["user_id"], name: "index_ai_recommendation_feedbacks_on_user_id"
  end

  create_table "ai_recommendation_impressions", force: :cascade do |t|
    t.bigint "ai_policy_run_id", null: false
    t.bigint "ai_conversation_id", null: false
    t.bigint "ai_recommendation_id"
    t.bigint "user_id", null: false
    t.bigint "group_id"
    t.integer "rank_position", default: 1, null: false
    t.string "kind", null: false
    t.string "recommendation_status", default: "pending", null: false
    t.string "interaction_label"
    t.datetime "interacted_at"
    t.string "title"
    t.datetime "start_at"
    t.datetime "end_at"
    t.jsonb "payload_snapshot", default: {}, null: false
    t.jsonb "features", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_conversation_id"], name: "index_ai_recommendation_impressions_on_ai_conversation_id"
    t.index ["ai_policy_run_id", "rank_position"], name: "index_ai_recommendation_impressions_on_policy_and_rank"
    t.index ["ai_policy_run_id"], name: "index_ai_recommendation_impressions_on_ai_policy_run_id"
    t.index ["ai_recommendation_id", "created_at"], name: "index_ai_reco_impressions_on_recommendation_and_created"
    t.index ["ai_recommendation_id"], name: "index_ai_recommendation_impressions_on_ai_recommendation_id"
    t.index ["group_id"], name: "index_ai_recommendation_impressions_on_group_id"
    t.index ["interaction_label"], name: "index_ai_recommendation_impressions_on_interaction_label"
    t.index ["user_id", "created_at"], name: "index_ai_reco_impressions_on_user_and_created"
    t.index ["user_id"], name: "index_ai_recommendation_impressions_on_user_id"
  end

  create_table "ai_recommendations", force: :cascade do |t|
    t.bigint "ai_conversation_id", null: false
    t.bigint "user_id", null: false
    t.bigint "group_id"
    t.string "kind", null: false
    t.integer "status", default: 0, null: false
    t.string "title", null: false
    t.text "description"
    t.text "reason"
    t.datetime "start_at"
    t.datetime "end_at"
    t.boolean "all_day", default: false, null: false
    t.bigint "source_event_id"
    t.bigint "created_event_id"
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_conversation_id", "status", "created_at"], name: "index_ai_recommendations_on_conversation_status_created"
    t.index ["ai_conversation_id"], name: "index_ai_recommendations_on_ai_conversation_id"
    t.index ["created_event_id"], name: "index_ai_recommendations_on_created_event_id"
    t.index ["group_id"], name: "index_ai_recommendations_on_group_id"
    t.index ["kind"], name: "index_ai_recommendations_on_kind"
    t.index ["source_event_id"], name: "index_ai_recommendations_on_source_event_id"
    t.index ["user_id", "status"], name: "index_ai_recommendations_on_user_status"
    t.index ["user_id"], name: "index_ai_recommendations_on_user_id"
  end

  create_table "ai_tool_invocations", force: :cascade do |t|
    t.bigint "ai_policy_run_id", null: false
    t.bigint "ai_conversation_id", null: false
    t.bigint "user_id", null: false
    t.string "tool_name", null: false
    t.string "status", default: "success", null: false
    t.integer "position", default: 0, null: false
    t.integer "duration_ms"
    t.jsonb "input_payload", default: {}, null: false
    t.jsonb "output_payload", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ai_conversation_id"], name: "index_ai_tool_invocations_on_ai_conversation_id"
    t.index ["ai_policy_run_id", "position"], name: "index_ai_tool_invocations_on_policy_run_and_position"
    t.index ["ai_policy_run_id"], name: "index_ai_tool_invocations_on_ai_policy_run_id"
    t.index ["tool_name", "created_at"], name: "index_ai_tool_invocations_on_tool_and_created"
    t.index ["user_id"], name: "index_ai_tool_invocations_on_user_id"
  end

  create_table "availability_profiles", force: :cascade do |t|
    t.bigint "contact_id", null: false
    t.integer "weekday", null: false
    t.integer "start_minute", null: false
    t.integer "end_minute", null: false
    t.integer "preference_kind", default: 0, null: false
    t.integer "source_kind", default: 0, null: false
    t.text "notes"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contact_id", "weekday", "start_minute", "end_minute", "preference_kind"], name: "index_availability_profiles_uniqueness", unique: true
    t.index ["contact_id", "weekday"], name: "index_availability_profiles_on_contact_id_and_weekday"
    t.index ["contact_id"], name: "index_availability_profiles_on_contact_id"
  end

  create_table "chat_rooms", force: :cascade do |t|
    t.string "chatable_type", null: false
    t.bigint "chatable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chatable_type", "chatable_id"], name: "index_chat_rooms_on_chatable", unique: true
  end

  create_table "contacts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "linked_user_id"
    t.bigint "friendship_id"
    t.string "display_name", null: false
    t.integer "relation_type", default: 0, null: false
    t.integer "source_kind", default: 0, null: false
    t.text "notes"
    t.integer "preferred_duration_minutes"
    t.boolean "active", default: true, null: false
    t.string "timezone", default: "Asia/Tokyo", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["friendship_id"], name: "index_contacts_on_friendship_id"
    t.index ["linked_user_id"], name: "index_contacts_on_linked_user_id"
    t.index ["user_id", "display_name"], name: "index_contacts_on_user_id_and_display_name"
    t.index ["user_id", "linked_user_id"], name: "index_contacts_on_user_id_and_linked_user_id", unique: true
    t.index ["user_id"], name: "index_contacts_on_user_id"
  end

  create_table "direct_chats", force: :cascade do |t|
    t.bigint "user_a_id", null: false
    t.bigint "user_b_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_a_id", "user_b_id"], name: "index_direct_chats_on_user_a_id_and_user_b_id", unique: true
    t.index ["user_a_id"], name: "index_direct_chats_on_user_a_id"
    t.index ["user_b_id"], name: "index_direct_chats_on_user_b_id"
  end

  create_table "event_groups", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "group_id"], name: "index_event_groups_on_event_id_and_group_id", unique: true
    t.index ["event_id"], name: "index_event_groups_on_event_id"
    t.index ["group_id", "event_id"], name: "index_event_groups_on_group_id_and_event_id"
    t.index ["group_id"], name: "index_event_groups_on_group_id"
  end

  create_table "event_participants", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "user_id", null: false
    t.integer "source", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "user_id"], name: "index_event_participants_on_event_id_and_user_id", unique: true
    t.index ["event_id"], name: "index_event_participants_on_event_id"
    t.index ["user_id", "event_id"], name: "index_event_participants_on_user_id_and_event_id"
    t.index ["user_id"], name: "index_event_participants_on_user_id"
  end

  create_table "event_requests", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "group_id", null: false
    t.bigint "target_user_id", null: false
    t.bigint "requested_by_id", null: false
    t.integer "status", default: 0, null: false
    t.text "note"
    t.datetime "responded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "target_user_id"], name: "index_event_requests_on_event_id_and_target_user_id", unique: true
    t.index ["event_id"], name: "index_event_requests_on_event_id"
    t.index ["group_id"], name: "index_event_requests_on_group_id"
    t.index ["requested_by_id"], name: "index_event_requests_on_requested_by_id"
    t.index ["status"], name: "index_event_requests_on_status"
    t.index ["target_user_id"], name: "index_event_requests_on_target_user_id"
  end

  create_table "event_share_requests", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "requested_by_id", null: false
    t.string "target_type", null: false
    t.bigint "target_id", null: false
    t.integer "status", default: 0, null: false
    t.bigint "responded_by_id"
    t.datetime "responded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "target_type", "target_id"], name: "index_event_share_requests_uni", unique: true
    t.index ["event_id"], name: "index_event_share_requests_on_event_id"
    t.index ["requested_by_id"], name: "index_event_share_requests_on_requested_by_id"
    t.index ["responded_by_id"], name: "index_event_share_requests_on_responded_by_id"
    t.index ["target_type", "target_id"], name: "index_event_share_requests_target"
  end

  create_table "event_shares", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.bigint "actor_id", null: false
    t.bigint "to_group_id"
    t.bigint "to_user_id"
    t.string "action", null: false
    t.json "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_event_shares_on_action"
    t.index ["actor_id"], name: "index_event_shares_on_actor_id"
    t.index ["event_id", "created_at"], name: "index_event_shares_on_event_id_and_created_at"
    t.index ["event_id"], name: "index_event_shares_on_event_id"
    t.index ["to_group_id"], name: "index_event_shares_on_to_group_id"
    t.index ["to_user_id"], name: "index_event_shares_on_to_user_id"
  end

  create_table "event_types", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", null: false
    t.string "color"
    t.string "icon"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "name"], name: "index_event_types_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_event_types_on_user_id"
  end

  create_table "events", force: :cascade do |t|
    t.string "title", null: false
    t.text "description"
    t.datetime "start_at", null: false
    t.datetime "end_at", null: false
    t.boolean "all_day", default: false, null: false
    t.bigint "created_by_id", null: false
    t.bigint "event_type_id"
    t.bigint "parent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "location"
    t.string "color"
    t.index ["created_by_id"], name: "index_events_on_created_by_id"
    t.index ["end_at"], name: "index_events_on_end_at"
    t.index ["event_type_id"], name: "index_events_on_event_type_id"
    t.index ["parent_id"], name: "index_events_on_parent_id"
    t.index ["start_at"], name: "index_events_on_start_at"
  end

  create_table "friendships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "friend_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["friend_id"], name: "index_friendships_on_friend_id"
    t.index ["user_id", "friend_id"], name: "index_friendships_on_user_id_and_friend_id", unique: true
    t.index ["user_id"], name: "index_friendships_on_user_id"
  end

  create_table "group_members", force: :cascade do |t|
    t.bigint "group_id", null: false
    t.bigint "user_id", null: false
    t.integer "role", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "user_id"], name: "index_group_members_on_group_id_and_user_id", unique: true
    t.index ["group_id"], name: "index_group_members_on_group_id"
    t.index ["user_id"], name: "index_group_members_on_user_id"
  end

  create_table "groups", force: :cascade do |t|
    t.string "name", null: false
    t.integer "parent_id"
    t.integer "position", default: 0, null: false
    t.bigint "owner_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_groups_on_owner_id"
    t.index ["parent_id"], name: "index_groups_on_parent_id"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "chat_room_id", null: false
    t.bigint "user_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_room_id", "created_at"], name: "index_messages_on_chat_room_id_and_created_at"
    t.index ["chat_room_id"], name: "index_messages_on_chat_room_id"
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.integer "kind", default: 0, null: false
    t.json "payload", default: {}, null: false
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "name"
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "ai_conversations", "groups"
  add_foreign_key "ai_conversations", "users"
  add_foreign_key "ai_messages", "ai_conversations"
  add_foreign_key "ai_policy_runs", "ai_conversations"
  add_foreign_key "ai_policy_runs", "groups"
  add_foreign_key "ai_policy_runs", "users"
  add_foreign_key "ai_recommendation_feedbacks", "ai_conversations"
  add_foreign_key "ai_recommendation_feedbacks", "ai_recommendations"
  add_foreign_key "ai_recommendation_feedbacks", "users"
  add_foreign_key "ai_recommendation_impressions", "ai_conversations"
  add_foreign_key "ai_recommendation_impressions", "ai_policy_runs"
  add_foreign_key "ai_recommendation_impressions", "ai_recommendations"
  add_foreign_key "ai_recommendation_impressions", "groups"
  add_foreign_key "ai_recommendation_impressions", "users"
  add_foreign_key "ai_recommendations", "ai_conversations"
  add_foreign_key "ai_recommendations", "events", column: "created_event_id"
  add_foreign_key "ai_recommendations", "events", column: "source_event_id"
  add_foreign_key "ai_recommendations", "groups"
  add_foreign_key "ai_recommendations", "users"
  add_foreign_key "ai_tool_invocations", "ai_conversations"
  add_foreign_key "ai_tool_invocations", "ai_policy_runs"
  add_foreign_key "ai_tool_invocations", "users"
  add_foreign_key "availability_profiles", "contacts"
  add_foreign_key "contacts", "friendships"
  add_foreign_key "contacts", "users"
  add_foreign_key "contacts", "users", column: "linked_user_id"
  add_foreign_key "direct_chats", "users", column: "user_a_id"
  add_foreign_key "direct_chats", "users", column: "user_b_id"
  add_foreign_key "event_groups", "events"
  add_foreign_key "event_groups", "groups"
  add_foreign_key "event_participants", "events"
  add_foreign_key "event_participants", "users"
  add_foreign_key "event_requests", "events"
  add_foreign_key "event_requests", "groups"
  add_foreign_key "event_requests", "users", column: "requested_by_id"
  add_foreign_key "event_requests", "users", column: "target_user_id"
  add_foreign_key "event_share_requests", "events"
  add_foreign_key "event_share_requests", "users", column: "requested_by_id"
  add_foreign_key "event_share_requests", "users", column: "responded_by_id"
  add_foreign_key "event_shares", "events"
  add_foreign_key "event_shares", "groups", column: "to_group_id"
  add_foreign_key "event_shares", "users", column: "actor_id"
  add_foreign_key "event_shares", "users", column: "to_user_id"
  add_foreign_key "event_types", "users"
  add_foreign_key "events", "event_types"
  add_foreign_key "events", "events", column: "parent_id"
  add_foreign_key "events", "users", column: "created_by_id"
  add_foreign_key "friendships", "users"
  add_foreign_key "friendships", "users", column: "friend_id"
  add_foreign_key "group_members", "groups"
  add_foreign_key "group_members", "users"
  add_foreign_key "groups", "users", column: "owner_id"
  add_foreign_key "messages", "chat_rooms"
  add_foreign_key "messages", "users"
  add_foreign_key "notifications", "users"
end
