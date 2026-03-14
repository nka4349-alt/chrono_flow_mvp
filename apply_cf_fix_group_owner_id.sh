#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
CTRL="$ROOT/app/controllers/api/groups_controller.rb"

if [ ! -f "$CTRL" ]; then
  echo "[ERR] not found: $CTRL" >&2
  echo "      (expected API groups controller)" >&2
  exit 1
fi

TS=$(date +%Y%m%d_%H%M%S)
cp -a "$CTRL" "$CTRL.bak_$TS"

echo "Patching: $CTRL"

python3 - "$CTRL" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

# Quick exit if already fixed
if re.search(r'\bowner_id\b.*current_user', text) and re.search(r'GroupMember\.find_or_create_by!\(', text):
    print('[SKIP] owner_id + GroupMember already handled')
    sys.exit(0)

lines = text.splitlines(True)

# Find create method
create_idx = None
for i, ln in enumerate(lines):
    if re.match(r'^\s*def\s+create\b', ln):
        create_idx = i
        break
if create_idx is None:
    raise SystemExit('[ERR] def create not found')

# Find variable assigned to Group in create
var = None
assign_idx = None
for j in range(create_idx+1, min(len(lines), create_idx+200)):
    ln = lines[j]
    m = re.match(r'^\s*(?P<var>@?\w+)\s*=\s*(?:Group\.|current_user\.)?\w*groups?\.new\b', ln)
    if m:
        var = m.group('var')
        assign_idx = j
        break
    m = re.match(r'^\s*(?P<var>@?\w+)\s*=\s*Group\.new\b', ln)
    if m:
        var = m.group('var')
        assign_idx = j
        break
    # Group.create / create!
    m = re.match(r'^\s*(?P<var>@?\w+)\s*=\s*Group\.create!?\b', ln)
    if m:
        var = m.group('var')
        assign_idx = j
        break

if var is None:
    var = '@group'  # best guess

# Helper to insert if missing

def has_line(pattern: str) -> bool:
    return re.search(pattern, ''.join(lines[create_idx:create_idx+220]), re.M) is not None

# Insert owner_id assignment near group instantiation
if not has_line(r'\bowner_id\b\s*=\s*current_user') and not has_line(r'\bowner\b\s*=\s*current_user'):
    # Insert after assignment if we found it, else right after def create
    insert_at = (assign_idx + 1) if assign_idx is not None else (create_idx + 1)

    # Use same indentation as the next line after def create, else 4 spaces
    indent = re.match(r'^(\s*)', lines[insert_at-1]).group(1) if insert_at-1 < len(lines) else '  '
    # Ensure we are inside method body: add two spaces more than def line
    def_indent = re.match(r'^(\s*)', lines[create_idx]).group(1)
    body_indent = def_indent + '  '

    block = [
        body_indent + '# owner_id はDBで NOT NULL（作成者を必ずownerにする）\n',
        body_indent + f"{var}.owner_id ||= current_user.id\n",
    ]

    lines[insert_at:insert_at] = block

# Insert GroupMember/ChatRoom creation after successful save
# Strategy:
# - If we find `if <var>.save` line, insert right after it inside the if-block.
# - Else if we find `<var>.save!` line, insert right after it.
# - Else insert just before the first `render` line in create (best effort).

create_block = ''.join(lines[create_idx:create_idx+260])

needs_member = 'GroupMember.find_or_create_by!' not in create_block

if needs_member:
    # locate within window
    window_start = create_idx
    window_end = min(len(lines), create_idx+260)

    save_if_idx = None
    save_bang_idx = None
    render_idx = None

    save_if_re = re.compile(r'^\s*if\s+' + re.escape(var) + r'\.save\b')
    save_bang_re = re.compile(r'^\s*' + re.escape(var) + r'\.save!\b')

    for k in range(window_start, window_end):
        ln = lines[k]
        if render_idx is None and re.match(r'^\s*render\b', ln):
            render_idx = k
        if save_if_idx is None and save_if_re.match(ln):
            save_if_idx = k
            break
        if save_bang_idx is None and save_bang_re.match(ln):
            save_bang_idx = k

    if save_if_idx is not None:
        base_indent = re.match(r'^(\s*)', lines[save_if_idx]).group(1)
        ins_indent = base_indent + '  '
        block = [
            ins_indent + 'GroupMember.find_or_create_by!(group: ' + var + ', user: current_user) { |gm| gm.role = :admin }\n',
            ins_indent + 'ChatRoom.find_or_create_by!(chatable: ' + var + ') if defined?(ChatRoom)\n',
        ]
        lines[save_if_idx+1:save_if_idx+1] = block
    elif save_bang_idx is not None:
        base_indent = re.match(r'^(\s*)', lines[save_bang_idx]).group(1)
        block = [
            base_indent + 'GroupMember.find_or_create_by!(group: ' + var + ', user: current_user) { |gm| gm.role = :admin }\n',
            base_indent + 'ChatRoom.find_or_create_by!(chatable: ' + var + ') if defined?(ChatRoom)\n',
        ]
        lines[save_bang_idx+1:save_bang_idx+1] = block
    elif render_idx is not None:
        base_indent = re.match(r'^(\s*)', lines[render_idx]).group(1)
        block = [
            base_indent + 'GroupMember.find_or_create_by!(group: ' + var + ', user: current_user) { |gm| gm.role = :admin }\n',
            base_indent + 'ChatRoom.find_or_create_by!(chatable: ' + var + ') if defined?(ChatRoom)\n',
        ]
        lines[render_idx:render_idx] = block

new_text = ''.join(lines)
path.write_text(new_text, encoding='utf-8')
print('[OK] patched create() to set owner_id and ensure GroupMember/Admin')
PY

echo "Done. Backup: $CTRL.bak_$TS"
