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

ActiveRecord::Schema[7.1].define(version: 2026_03_14_183000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "chat_rooms", force: :cascade do |t|
    t.string "chatable_type", null: false
    t.bigint "chatable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chatable_type", "chatable_id"], name: "index_chat_rooms_on_chatable", unique: true
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
