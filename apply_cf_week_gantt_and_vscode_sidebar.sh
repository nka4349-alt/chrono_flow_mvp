#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

say(){ printf "\n\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err(){ printf "\n\033[1;31m%s\033[0m\n" "$*"; }

# --- detect CSS file ---
CSS_FILE=""
for f in \
  app/assets/stylesheets/application.css \
  app/assets/stylesheets/application.scss \
  app/assets/stylesheets/application.sass \
  app/assets/builds/application.css
  do
  if [[ -f "$f" ]]; then CSS_FILE="$f"; break; fi
done

if [[ -z "$CSS_FILE" ]]; then
  err "CSS file not found (expected app/assets/stylesheets/application.css etc.)"
  exit 1
fi

# --- detect JS file containing FullCalendar init ---
JS_FILE=""
# Prefer explicit app/javascript/application.js if it contains FullCalendar
if [[ -f app/javascript/application.js ]] && grep -q "FullCalendar" app/javascript/application.js; then
  JS_FILE="app/javascript/application.js"
fi

if [[ -z "$JS_FILE" ]]; then
  JS_FILE=$(grep -Rsl "new FullCalendar.Calendar" app 2>/dev/null | head -n 1 || true)
fi

if [[ -z "$JS_FILE" ]]; then
  # fallback: any file that mentions dayGridWeek
  JS_FILE=$(grep -Rsl "dayGridWeek" app 2>/dev/null | head -n 1 || true)
fi

if [[ -z "$JS_FILE" ]]; then
  err "JS file not found (could not locate FullCalendar init)."
  err "Try: grep -R \"new FullCalendar.Calendar\" -n app"
  exit 1
fi

say "Using JS:  $JS_FILE"
say "Using CSS: $CSS_FILE"

# --- backup ---
TS=$(date +%Y%m%d_%H%M%S)
cp "$JS_FILE"  "$JS_FILE.bak_$TS"
cp "$CSS_FILE" "$CSS_FILE.bak_$TS"

# --- append CSS blocks (idempotent) ---
if ! grep -q "CF_VSCODE_SIDEBAR" "$CSS_FILE"; then
  cat >> "$CSS_FILE" <<'CSS'

/* === CF_VSCODE_SIDEBAR === */

/* VSCode-like group tree (targets: #cf-group-tree) */
#cf-group-tree{
  list-style:none;
  margin:0;
  padding:6px 4px 10px;
}

#cf-group-tree li{
  display:flex;
  align-items:center;
  gap:6px;
  padding:4px 8px;
  border-radius:6px;
  cursor:pointer;
  user-select:none;
  font-size:13px;
  line-height:1.2;
}

#cf-group-tree li:hover{ background: rgba(148,163,184,0.12); }
#cf-group-tree li.active{ background: rgba(59,130,246,0.22); }

#cf-group-tree li .cf-tree-toggle{
  width:16px;
  height:16px;
  display:inline-flex;
  align-items:center;
  justify-content:center;
  border:none;
  background:transparent;
  color: rgba(148,163,184,0.95);
  padding:0;
  cursor:pointer;
}

#cf-group-tree li .cf-tree-indent{
  flex: 0 0 auto;
}

#cf-group-tree li .cf-tree-label{
  flex:1;
  overflow:hidden;
  text-overflow:ellipsis;
  white-space:nowrap;
  color: rgba(226,232,240,0.92);
}

#cf-group-tree li.active .cf-tree-label{ color: #fff; font-weight: 600; }

/* === CF_WEEK_GANTT_TIMED === */
/* dayGridWeek の「同日イベント」を start/end に応じて帯をずらす（疑似ガント） */
.fc-dayGridWeek-view .cf-week-timed{
  background: transparent !important;
  border-color: transparent !important;
  position: relative;
}

.fc-dayGridWeek-view .cf-week-timed::before{
  content:"";
  position:absolute;
  top:0;
  bottom:0;
  left: calc(var(--cf-start-pct) * 1%);
  width: calc(var(--cf-width-pct) * 1%);
  background: var(--cf-bar-color, rgba(59,130,246,0.9));
  border-radius: 4px;
  z-index:0;
}

.fc-dayGridWeek-view .cf-week-timed .fc-event-main,
.fc-dayGridWeek-view .cf-week-timed .fc-event-main-frame{
  position: relative;
  z-index: 1;
}

/* テキストも帯の開始位置に寄せる */
.fc-dayGridWeek-view .cf-week-timed .fc-event-main-frame{
  padding-left: calc(var(--cf-start-pct) * 1%);
}

/* === END CF_VSCODE_SIDEBAR === */
CSS
  say "Appended VSCode sidebar + week timed gantt CSS"
else
  warn "CSS already contains CF_VSCODE_SIDEBAR block (skip)"
fi

# thin bars for Month/Week (dayGrid) only
if ! grep -q "CF_THIN_DAYGRID_BARS" "$CSS_FILE"; then
  cat >> "$CSS_FILE" <<'CSS'

/* === CF_THIN_DAYGRID_BARS === */
/* Month/Week(dayGrid)だけバーを細く（Day(timeGrid)は触らない） */
.fc-dayGridMonth-view .fc-daygrid-event,
.fc-dayGridWeek-view  .fc-daygrid-event{
  border-radius: 4px;
}

.fc-dayGridMonth-view .fc-daygrid-event .fc-event-main,
.fc-dayGridWeek-view  .fc-daygrid-event .fc-event-main{
  padding: 1px 4px;
  font-size: 11px;
  line-height: 1.15;
}

.fc-dayGridMonth-view .fc-daygrid-event-harness,
.fc-dayGridWeek-view  .fc-daygrid-event-harness{
  margin-top: 1px;
}
/* === END CF_THIN_DAYGRID_BARS === */
CSS
  say "Appended CF_THIN_DAYGRID_BARS"
else
  warn "CSS already contains CF_THIN_DAYGRID_BARS (skip)"
fi

# --- patch JS: inject eventDidMount into FullCalendar options (idempotent) ---
JS_FILE="$JS_FILE" python3 - <<'PY'
import os
import re
from pathlib import Path

js_path = Path(os.environ["JS_FILE"])
text = js_path.read_text(encoding='utf-8')

# Ensure week view is dayGridWeek (free)
if 'timeGridWeek' in text:
    text2 = text.replace('timeGridWeek', 'dayGridWeek')
    if text2 != text:
        text = text2
        js_path.write_text(text, encoding='utf-8')
        print('Replaced timeGridWeek -> dayGridWeek')

text = js_path.read_text(encoding='utf-8')

if 'CF_WEEK_GANTT_EVENT_DID_MOUNT' in text:
    print('JS already contains CF_WEEK_GANTT_EVENT_DID_MOUNT (skip)')
else:
    idx = text.find('new FullCalendar.Calendar')
    if idx == -1:
        idx = text.find('FullCalendar.Calendar')
    if idx == -1:
        raise SystemExit('ERROR: Cannot find FullCalendar.Calendar init in JS file')

    brace_start = text.find('{', idx)
    if brace_start == -1:
        raise SystemExit('ERROR: Cannot find options object "{" after FullCalendar.Calendar')

    # Get indentation after opening brace
    after = text[brace_start+1:]
    m = re.match(r'(\s*\n)(\s*)', after)
    indent = m.group(2) if m else '  '

    # If eventDidMount already exists, do not inject to avoid overwrite
    # (we still can append sidebar enhancer below)
    # But check within first ~800 chars after brace_start to avoid scanning whole file
    sample = text[brace_start:brace_start+2000]
    if re.search(r'\beventDidMount\s*:', sample):
        print('NOTE: eventDidMount already exists near calendar options; skip gantt injection to avoid overwrite.')
    else:
        inject = (
            f"\n{indent}// --- CF_WEEK_GANTT_EVENT_DID_MOUNT ---\n"
            f"{indent}displayEventTime: true,\n"
            f"{indent}displayEventEnd: true,\n"
            f"{indent}eventDidMount: function(info) {{\n"
            f"{indent}  try {{\n"
            f"{indent}    if (!info || !info.view || info.view.type !== 'dayGridWeek') return;\n"
            f"{indent}    const ev = info.event;\n"
            f"{indent}    if (!ev || ev.allDay) return;\n"
            f"{indent}    const start = ev.start;\n"
            f"{indent}    if (!start) return;\n"
            f"{indent}    const end0 = ev.end ? ev.end : new Date(start.getTime() + 30 * 60 * 1000);\n"
            f"{indent}    const startKey = start.toISOString().slice(0,10);\n"
            f"{indent}    const endKey = end0.toISOString().slice(0,10);\n"
            f"{indent}    const endsAtMidnight = (end0.getHours() === 0 && end0.getMinutes() === 0);\n"
            f"{indent}    const endMinus1Key = new Date(end0.getTime() - 1).toISOString().slice(0,10);\n"
            f"{indent}    const sameDay = (startKey === endKey) || (endsAtMidnight && endMinus1Key === startKey);\n"
            f"{indent}    if (!sameDay) return;\n"
            f"{indent}    let startMin = start.getHours() * 60 + start.getMinutes();\n"
            f"{indent}    let endMin = end0.getHours() * 60 + end0.getMinutes();\n"
            f"{indent}    if (startKey !== endKey && endsAtMidnight) endMin = 1440;\n"
            f"{indent}    const dur = Math.max(5, endMin - startMin);\n"
            f"{indent}    const startPct = (startMin / 1440) * 100;\n"
            f"{indent}    const widthPct = (dur / 1440) * 100;\n"
            f"{indent}    const el = info.el;\n"
            f"{indent}    if (!el || !el.classList) return;\n"
            f"{indent}    el.classList.add('cf-week-timed');\n"
            f"{indent}    el.style.setProperty('--cf-start-pct', startPct.toFixed(2));\n"
            f"{indent}    el.style.setProperty('--cf-width-pct', widthPct.toFixed(2));\n"
            f"{indent}    const cs = window.getComputedStyle(el);\n"
            f"{indent}    const bg = (cs && cs.backgroundColor) ? cs.backgroundColor : null;\n"
            f"{indent}    if (bg) el.style.setProperty('--cf-bar-color', bg);\n"
            f"{indent}    const pad = (n)=>String(n).padStart(2,'0');\n"
            f"{indent}    const endLabelH = (startKey !== endKey && endsAtMidnight) ? 24 : end0.getHours();\n"
            f"{indent}    const endLabelM = (startKey !== endKey && endsAtMidnight) ? 0  : end0.getMinutes();\n"
            f"{indent}    const label = `${pad(start.getHours())}:${pad(start.getMinutes())}–${pad(endLabelH)}:${pad(endLabelM)}`;\n"
            f"{indent}    const timeEl = el.querySelector('.fc-event-time');\n"
            f"{indent}    if (timeEl) timeEl.textContent = label;\n"
            f"{indent}  }} catch (e) {{\n"
            f"{indent}    console.warn('[cf-week-gantt] eventDidMount error', e);\n"
            f"{indent}  }}\n"
            f"{indent}}},\n"
            f"{indent}// --- END CF_WEEK_GANTT_EVENT_DID_MOUNT ---\n"
        )

        # insert right after opening brace so we don't rely on a trailing comma
        text = text[:brace_start+1] + inject + text[brace_start+1:]
        js_path.write_text(text, encoding='utf-8')
        print('Injected CF_WEEK_GANTT_EVENT_DID_MOUNT into FullCalendar options')

# --- append group tree enhancer (idempotent) ---
text = js_path.read_text(encoding='utf-8')
if 'CF_VSCODE_SIDEBAR_ENHANCE' in text:
    print('JS already contains CF_VSCODE_SIDEBAR_ENHANCE (skip)')
else:
    addon = r"""

// === CF_VSCODE_SIDEBAR_ENHANCE ===
(function() {
  const STORAGE_KEY = 'chrono:groupTreeCollapsed';

  function enhanceTree() {
    const tree = document.getElementById('cf-group-tree');
    if (!tree) return;
    const items = Array.from(tree.querySelectorAll('li'));
    if (items.length === 0) return;

    let collapsed = {};
    try { collapsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); } catch (e) { collapsed = {}; }

    // compute depth for each li
    const depths = items.map((li) => {
      let d = parseInt(li.dataset.depth || '', 10);
      if (!Number.isFinite(d)) {
        const indent = li.querySelector('.indent');
        if (indent) {
          const w = indent.style.width || window.getComputedStyle(indent).width || '0px';
          const px = parseInt(w, 10) || 0;
          d = Math.round(px / 14);
          indent.classList.add('cf-tree-indent');
        } else {
          d = 0;
        }
      }
      li.dataset.depth = String(d);
      return d;
    });

    // determine hasChildren and insert toggle
    items.forEach((li, idx) => {
      const d = depths[idx];
      const nextDepth = (idx + 1 < depths.length) ? depths[idx + 1] : -1;
      const hasChildren = nextDepth > d;
      li.dataset.hasChildren = hasChildren ? 'true' : 'false';

      // label styling
      Array.from(li.querySelectorAll('span')).forEach((sp) => {
        if (sp.classList.contains('indent') || sp.classList.contains('cf-tree-indent')) return;
        sp.classList.add('cf-tree-label');
      });

      let toggle = li.querySelector('button.cf-tree-toggle');
      if (!toggle) {
        toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'cf-tree-toggle';
        toggle.tabIndex = -1;
        li.insertBefore(toggle, li.firstChild);
      }

      if (!hasChildren) {
        toggle.style.visibility = 'hidden';
        toggle.textContent = '';
        toggle.onclick = null;
        toggle.setAttribute('aria-hidden', 'true');
      } else {
        const id = li.dataset.groupId || li.getAttribute('data-group-id');
        const isCollapsed = !!collapsed[id];
        toggle.style.visibility = 'visible';
        toggle.textContent = isCollapsed ? '▶' : '▼';
        toggle.setAttribute('aria-hidden', 'false');
        toggle.setAttribute('aria-expanded', String(!isCollapsed));
        toggle.onclick = (e) => {
          e.stopPropagation();
          collapsed[id] = !collapsed[id];
          try { localStorage.setItem(STORAGE_KEY, JSON.stringify(collapsed)); } catch (e2) {}
          enhanceTree();
        };
      }
    });

    // apply hide/show based on collapsed ancestors
    const stack = [];
    items.forEach((li, idx) => {
      const id = li.dataset.groupId || li.getAttribute('data-group-id');
      const d = depths[idx];
      while (stack.length && stack[stack.length - 1] >= d) stack.pop();
      const hidden = stack.length > 0;
      li.style.display = hidden ? 'none' : '';
      if (li.dataset.hasChildren === 'true' && collapsed[id]) stack.push(d);
    });
  }

  function boot() {
    const tree = document.getElementById('cf-group-tree');
    if (!tree) return;
    if (tree.dataset.cfEnhanced === '1') return;
    tree.dataset.cfEnhanced = '1';

    let queued = false;
    const schedule = () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        enhanceTree();
      });
    };

    const obs = new MutationObserver(schedule);
    obs.observe(tree, { childList: true, subtree: true });
    schedule();
  }

  document.addEventListener('DOMContentLoaded', boot);
  document.addEventListener('turbo:load', boot);
})();
// === END CF_VSCODE_SIDEBAR_ENHANCE ===
"""

    js_path.write_text(text + addon, encoding='utf-8')
    print('Appended CF_VSCODE_SIDEBAR_ENHANCE block')
PY

say "Patch applied. Backups:"
echo "  $JS_FILE.bak_$TS"
echo "  $CSS_FILE.bak_$TS"

say "Next: restart server and hard reload (Ctrl+Shift+R)."
