#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
JS_FILE="$ROOT/app/javascript/application.js"

if [ ! -f "$JS_FILE" ]; then
  echo "[ERR] not found: $JS_FILE"
  exit 1
fi

ts="$(date +%Y%m%d_%H%M%S)"
cp -f "$JS_FILE" "${JS_FILE}.bak_${ts}"

# overwrite
cp -f "$(dirname "$0")/app/javascript/application.js" "$JS_FILE"

echo "OK: patched $JS_FILE"
echo "Backup: ${JS_FILE}.bak_${ts}"
