#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

STAMP="$(date +%Y%m%d_%H%M%S)"

copy_with_backup() {
  local src="$1"
  local rel="$2"
  local dst="$ROOT/$rel"
  mkdir -p "$(dirname "$dst")"
  if [[ -f "$dst" ]]; then
    cp "$dst" "$dst.bak_${STAMP}"
  fi
  cp "$src" "$dst"
  echo "Wrote: $rel"
}

append_css_block() {
  local css_file="$ROOT/app/assets/stylesheets/application.css"
  local marker="CF_NEXT_TASKS_UI"
  if [[ ! -f "$css_file" ]]; then
    echo "[WARN] CSS not found: $css_file (skip append)"
    return
  fi
  if grep -q "$marker" "$css_file"; then
    echo "CSS already contains $marker (skip)"
    return
  fi
  cp "$css_file" "$css_file.bak_${STAMP}"
  cat "$(dirname "$0")/files/CF_NEXT_TASKS.css" >> "$css_file"
  echo "Appended CSS block to app/assets/stylesheets/application.css"
}

append_routes_block() {
  local routes_file="$ROOT/config/routes.rb"
  local marker="CF_NEXT_TASKS_ROUTES"
  if [[ ! -f "$routes_file" ]]; then
    echo "[WARN] routes.rb not found: $routes_file (skip append)"
    return
  fi
  if grep -q "$marker" "$routes_file"; then
    echo "routes.rb already contains $marker (skip)"
    return
  fi
  cp "$routes_file" "$routes_file.bak_${STAMP}"
  cat >> "$routes_file" <<'RUBY'

# === CF_NEXT_TASKS_ROUTES ===
namespace :api do
  # Friends sidebar (home)
  resources :friends, only: %i[index]

  # Event chat
  resources :events, only: [] do
    resources :chat_messages, only: %i[index create]
  end

  # Direct chat (DM)
  resources :users, only: [] do
    resources :chat_messages, only: %i[index create]
  end

  # Group chat (if not already present)
  resources :groups, only: [] do
    member do
      get :events
      get :members, to: 'group_members#index'
      patch 'members/:user_id/role', to: 'group_members#update_role'
    end
    resources :chat_messages, only: %i[index create]
  end
end
# === END CF_NEXT_TASKS_ROUTES ===
RUBY
  echo "Appended routes block to config/routes.rb"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

copy_with_backup "$SCRIPT_DIR/files/app/javascript/application.js" "app/javascript/application.js"

copy_with_backup "$SCRIPT_DIR/files/app/controllers/api/chat_messages_controller.rb" "app/controllers/api/chat_messages_controller.rb"
copy_with_backup "$SCRIPT_DIR/files/app/controllers/api/friends_controller.rb" "app/controllers/api/friends_controller.rb"
copy_with_backup "$SCRIPT_DIR/files/app/controllers/api/groups_controller.rb" "app/controllers/api/groups_controller.rb"
copy_with_backup "$SCRIPT_DIR/files/app/controllers/api/events_controller.rb" "app/controllers/api/events_controller.rb"

copy_with_backup "$SCRIPT_DIR/files/app/models/friendship.rb" "app/models/friendship.rb"
copy_with_backup "$SCRIPT_DIR/files/app/models/direct_chat.rb" "app/models/direct_chat.rb"

copy_with_backup "$SCRIPT_DIR/files/db/migrate/20260223090000_create_friendships.rb" "db/migrate/20260223090000_create_friendships.rb"
copy_with_backup "$SCRIPT_DIR/files/db/migrate/20260223090001_create_direct_chats.rb" "db/migrate/20260223090001_create_direct_chats.rb"

append_css_block
append_routes_block

echo ""
echo "Done. Next steps:"
echo "  1) bin/rails db:migrate"
echo "  2) bin/rails s"
