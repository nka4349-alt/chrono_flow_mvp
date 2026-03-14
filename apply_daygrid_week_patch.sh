#!/usr/bin/env bash
set -euo pipefail

# ChronoFlow: switch FullCalendar week view from timeGridWeek -> dayGridWeek (free dayGrid)

ROOT_DIR="${1:-.}"
cd "$ROOT_DIR"

# target file candidates
CANDIDATES=(
  "app/javascript/application.js"
  "app/assets/javascripts/application.js"
)

TARGET=""
for f in "${CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    TARGET="$f"
    break
  fi
done

if [ -z "$TARGET" ]; then
  echo "ERROR: application.js not found. Looked for:" >&2
  printf ' - %s\n' "${CANDIDATES[@]}" >&2
  exit 1
fi

TS=$(date +%Y%m%d_%H%M%S)
BACKUP="${TARGET}.bak_${TS}"
cp "$TARGET" "$BACKUP"

echo "Backup created: $BACKUP"

echo "Patching: $TARGET"
python3 - "$TARGET" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
s = path.read_text(encoding='utf-8')

before = s
# Main change: week view -> dayGridWeek
s = s.replace('timeGridWeek', 'dayGridWeek')

if s == before:
  print('NOTE: No "timeGridWeek" found. File was not changed.')
  sys.exit(0)

path.write_text(s, encoding='utf-8')
print('OK: replaced timeGridWeek -> dayGridWeek')

# Print the changed/related lines (line numbers) so user can verify quickly
for i, line in enumerate(s.splitlines(), 1):
  if 'dayGridWeek' in line:
    print(f'{i}: {line.strip()}')
PY

echo "Done. Restart Rails server and hard-reload browser."
