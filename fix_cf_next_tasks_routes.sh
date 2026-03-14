#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

cd "$ROOT"

ROUTES_FILE="config/routes.rb"

if [[ ! -f "$ROUTES_FILE" ]]; then
  echo "[ERR] routes.rb not found: $ROUTES_FILE"
  exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
cp "$ROUTES_FILE" "$ROUTES_FILE.bak_${STAMP}"
echo "Backup: $ROUTES_FILE.bak_${STAMP}"

python3 - <<'PY'
from pathlib import Path

routes_path = Path("config/routes.rb")
s = routes_path.read_text(encoding="utf-8")

# 1) Remove broken appended outer block (if present)
start = s.find("# === CF_NEXT_TASKS_ROUTES ===")
end = s.find("# === END CF_NEXT_TASKS_ROUTES ===")
if start != -1 and end != -1:
    end = end + len("# === END CF_NEXT_TASKS_ROUTES ===")
    # remove through end-of-line
    eol = s.find("\n", end)
    if eol != -1:
        end = eol + 1
    # remove one leading blank line too
    prev = s.rfind("\n", 0, start)
    if prev != -1:
        chunk = s[prev+1:start]
        if chunk.strip() == "":
            start = prev+1
    s = s[:start] + s[end:]
    print("Removed CF_NEXT_TASKS_ROUTES outer block")
else:
    print("No CF_NEXT_TASKS_ROUTES outer block found (skip)")

marker_inner = "# === CF_NEXT_TASKS_ROUTES_INNER ==="
if marker_inner in s:
    print("Inner routes marker already present (skip insert)")
    routes_path.write_text(s, encoding="utf-8")
    raise SystemExit(0)

# 2) Insert required routes INSIDE existing namespace :api do
needle = "namespace :api do"
idx = s.find(needle)
if idx == -1:
    raise SystemExit("[ERR] Could not find 'namespace :api do' in config/routes.rb")

# compute indentation of that line
line_start = s.rfind("\n", 0, idx) + 1
line_end = s.find("\n", idx)
if line_end == -1:
    line_end = len(s)
line = s[line_start:line_end]
indent = line[: len(line) - len(line.lstrip())]
inner_indent = indent + "  "

snippet_lines = [
    marker_inner,
    "# Friends sidebar (home)",
    "resources :friends, only: %i[index]",
    "",
    "# Event chat (event context)",
    "resources :events, only: [] do",
    "  resources :chat_messages, only: %i[index create]",
    "end",
    "",
    "# Direct chat (DM / user context)",
    "resources :users, only: [] do",
    "  resources :chat_messages, only: %i[index create]",
    "end",
    "# === END CF_NEXT_TASKS_ROUTES_INNER ===",
    "",
]

snippet = "\n".join(inner_indent + ln if ln != "" else "" for ln in snippet_lines)

insert_pos = line_end + 1
s = s[:insert_pos] + snippet + "\n" + s[insert_pos:]

routes_path.write_text(s, encoding="utf-8")
print("Inserted inner routes snippet inside namespace :api do")
PY

echo "OK: routes.rb fixed."
echo "Now run: bin/rails db:migrate"
