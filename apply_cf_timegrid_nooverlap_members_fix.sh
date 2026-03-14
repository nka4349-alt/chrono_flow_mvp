#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

JS_FILE="$ROOT/app/javascript/application.js"
CSS_FILE="$ROOT/app/assets/stylesheets/application.css"

echo "Using JS : $JS_FILE"
echo "Using CSS: $CSS_FILE"

if [ ! -f "$JS_FILE" ]; then
  echo "ERROR: not found: $JS_FILE"
  exit 1
fi
if [ ! -f "$CSS_FILE" ]; then
  echo "ERROR: not found: $CSS_FILE"
  exit 1
fi

ts="$(date +%Y%m%d_%H%M%S)"
cp "$JS_FILE"  "$JS_FILE.bak_$ts"
cp "$CSS_FILE" "$CSS_FILE.bak_$ts"

python3 - "$JS_FILE" "$CSS_FILE" <<'PY'
import sys, re
from pathlib import Path

js_path = Path(sys.argv[1])
css_path = Path(sys.argv[2])

js = js_path.read_text(encoding="utf-8")
css = css_path.read_text(encoding="utf-8")

# --- CSS: remove old fixed-height timegrid block (it breaks duration display) ---
css_before = css
css = re.sub(r"/\* === CF_THIN_TIMEGRID_BARS === \*/.*?/\* === END CF_THIN_TIMEGRID_BARS === \*/\s*", "", css, flags=re.S)

# --- CSS: add thinner but duration-preserving timeGrid styling ---
if "CF_TIMEGRID_NO_OVERLAP_THIN" not in css:
    css += """

/* === CF_TIMEGRID_NO_OVERLAP_THIN === */
/* timeGridDay/timeGridWeek: keep duration height, but make bars visually slimmer */
.fc .fc-timegrid-event {
  border-radius: 6px;
}

.fc .fc-timegrid-event .fc-event-main {
  padding: 1px 4px;
  font-size: 12px;
  line-height: 1.15;
}

.fc .fc-timegrid-event .fc-event-time {
  font-size: 11px;
  opacity: 0.92;
}

/* ensure stacked columns are readable */
.fc .fc-timegrid-event-harness {
  margin-top: 2px;
}

/* right sidebar member cards (if missing) */
#cf-members-list .cf-member-card {
  border: 1px solid rgba(255,255,255,0.10);
  border-radius: 10px;
  padding: 10px 12px;
  margin: 10px 0;
  background: rgba(255,255,255,0.04);
}
#cf-members-list .cf-member-name {
  font-weight: 600;
  margin-bottom: 4px;
}
#cf-members-list .cf-member-sub {
  font-size: 12px;
  opacity: 0.9;
}
#cf-members-list select.cf-role-select {
  width: 100%;
  background: rgba(255,255,255,0.06);
  color: inherit;
  border: 1px solid rgba(255,255,255,0.15);
  border-radius: 8px;
  padding: 6px 8px;
}
/* === END CF_TIMEGRID_NO_OVERLAP_THIN === */
"""

# --- JS: inject timeGrid "no overlap" options (so simultaneous events become columns, not overlapped) ---
def inject_timegrid_options(source: str):
    # find FullCalendar Calendar options object
    patterns = ["new window.FullCalendar.Calendar", "new FullCalendar.Calendar", "FullCalendar.Calendar"]
    idx = -1
    for p in patterns:
        idx = source.find(p)
        if idx != -1:
            break
    if idx == -1:
        return source, False, "FullCalendar.Calendar init not found"

    brace = source.find("{", idx)
    if brace == -1:
        return source, False, "Options '{' not found"

    # don't duplicate
    if "CF_TIMEGRID_NO_OVERLAP_OPTIONS" in source:
        return source, False, "Already injected"

    # if options already contains slotEventOverlap/eventOverlap near top, skip injecting to avoid duplicates
    head = source[brace:brace+2500]
    if re.search(r"\bslotEventOverlap\s*:", head) or re.search(r"\beventOverlap\s*:", head):
        # still add marker comment? no, keep minimal
        return source, False, "slotEventOverlap/eventOverlap already present"

    # determine indent after opening brace
    after = source[brace+1:]
    m = re.match(r"(\s*\n)(\s*)", after)
    indent = m.group(2) if m else "  "

    insert = (
        f"\n{indent}// --- CF_TIMEGRID_NO_OVERLAP_OPTIONS ---\n"
        f"{indent}eventOverlap: false,\n"
        f"{indent}slotEventOverlap: false,\n"
        f"{indent}eventMaxStack: 12,\n"
        f"{indent}// --- END CF_TIMEGRID_NO_OVERLAP_OPTIONS ---\n"
    )
    out = source[:brace+1] + insert + source[brace+1:]
    return out, True, "Injected options"

js2, did, msg = inject_timegrid_options(js)
print(msg)

# --- JS: append a robust "group click -> load members" handler ---
if "CF_MEMBERS_CLICK_FIX" not in js2:
    members_block = r"""

/* === CF_MEMBERS_CLICK_FIX === */
(function () {
  async function cfApiFetch(url, opts) {
    if (typeof window.apiFetch === 'function') return window.apiFetch(url, opts);
    const res = await fetch(url, Object.assign({ credentials: 'same-origin' }, opts || {}));
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return res.json();
  }

  function findRightSidebar() {
    return (
      document.querySelector('#cf-right-sidebar') ||
      document.querySelector('.cf-sidebar-right') ||
      document.querySelector('.sidebar-right') ||
      document.querySelector('.right-sidebar') ||
      document.querySelector('[data-sidebar="right"]') ||
      null
    );
  }

  function ensureMembersListEl() {
    const sidebar = findRightSidebar();
    if (!sidebar) return null;

    let list = document.getElementById('cf-members-list') || sidebar.querySelector('#cf-members-list');
    if (list) return list;

    // If a placeholder text exists (e.g. "未選択"), reuse it.
    const leafEls = Array.from(sidebar.querySelectorAll('*')).filter((el) => el.children.length === 0);
    const placeholder = leafEls.find((el) => (el.textContent || '').trim() === '未選択');
    if (placeholder) {
      placeholder.id = 'cf-members-list';
      return placeholder;
    }

    list = document.createElement('div');
    list.id = 'cf-members-list';
    sidebar.appendChild(list);
    return list;
  }

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  async function cfLoadMembersForGroup(groupId) {
    const list = ensureMembersListEl();
    if (!list) return;

    if (!groupId) {
      list.textContent = '未選択';
      return;
    }

    try {
      const data = await cfApiFetch('/api/groups/' + groupId + '/members');
      const members = (data && data.members) ? data.members : [];
      const canManage = !!(data && data.can_manage_roles) || (data && data.current_user_role === 'admin');
      const ownerId = (data && (data.owner_user_id || data.owner_id)) || null;
      const currentUserId = (data && data.current_user_id) || null;

      if (!members.length) {
        list.innerHTML = '<div class="cf-muted">メンバーなし</div>';
        return;
      }

      list.innerHTML = members
        .map((m) => {
          const uid = m.user_id || m.id;
          const name = esc(m.name || m.email || ('User#' + uid));
          const role = String(m.role || '');
          const isOwner = ownerId && String(uid) === String(ownerId);

          let roleHtml = '<span class="cf-role-label">' + esc(role + (isOwner ? ' (owner)' : '')) + '</span>';

          // show role select only when manageable and not owner and not self
          if (canManage && !isOwner && currentUserId && String(uid) !== String(currentUserId)) {
            roleHtml =
              '<select class="cf-role-select" data-user-id="' + esc(uid) + '">' +
              '<option value="member"' + (role === 'member' ? ' selected' : '') + '>member</option>' +
              '<option value="admin"' + (role === 'admin' ? ' selected' : '') + '>admin</option>' +
              '</select>';
          }

          return (
            '<div class="cf-member-card">' +
            '<div class="cf-member-name">' + name + '</div>' +
            '<div class="cf-member-sub">' + roleHtml + '</div>' +
            '</div>'
          );
        })
        .join('');

      // role update handler (if endpoint exists)
      list.querySelectorAll('select.cf-role-select').forEach((sel) => {
        sel.addEventListener('change', async () => {
          const uid = sel.getAttribute('data-user-id');
          const role = sel.value;
          try {
            await cfApiFetch('/api/groups/' + groupId + '/members/' + uid + '/role', {
              method: 'PATCH',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ role: role }),
            });
            await cfLoadMembersForGroup(groupId);
          } catch (e) {
            console.error(e);
            alert('権限更新に失敗しました');
          }
        });
      });
    } catch (e) {
      console.error(e);
      list.innerHTML = '<div class="cf-muted">メンバー取得に失敗</div>';
    }
  }

  function groupIdFromTarget(t) {
    const tree = document.getElementById('cf-group-tree');
    if (!tree) return null;

    const li = t.closest('#cf-group-tree li');
    if (!li) return null;

    // ignore toggle button click
    if (t.closest('button.cf-tree-toggle')) return null;

    return li.dataset.groupId || li.getAttribute('data-group-id') || null;
  }

  document.addEventListener('click', (e) => {
    const gid = groupIdFromTarget(e.target);
    if (!gid) return;
    window.CF_SELECTED_GROUP_ID = gid;
    cfLoadMembersForGroup(gid);
  });

  // Expose for manual debug from console
  window.cfLoadMembersForGroup = cfLoadMembersForGroup;
})();
/* === END CF_MEMBERS_CLICK_FIX === */
"""
    js2 += members_block
    print("Appended CF_MEMBERS_CLICK_FIX")

js_path.write_text(js2, encoding="utf-8")
css_path.write_text(css, encoding="utf-8")
print("OK: patched files")
PY

echo "Done."
echo "Backups:"
echo "  $JS_FILE.bak_$ts"
echo "  $CSS_FILE.bak_$ts"
