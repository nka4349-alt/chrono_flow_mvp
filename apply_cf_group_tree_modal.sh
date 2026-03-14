#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

pick_file() {
  local root="$1"; shift
  for rel in "$@"; do
    if [ -f "$root/$rel" ]; then
      echo "$root/$rel";
      return 0
    fi
  done
  return 1
}

JS_FILE="$(pick_file "$ROOT" \
  app/javascript/application.js \
  app/assets/javascripts/application.js \
  app/assets/builds/application.js \
  )" || { echo "[ERR] application.js not found"; exit 1; }

CSS_FILE="$(pick_file "$ROOT" \
  app/assets/stylesheets/application.css \
  app/assets/stylesheets/application.scss \
  app/assets/stylesheets/application.sass \
  )" || { echo "[ERR] application.css(.scss) not found"; exit 1; }

STAMP="$(date +%Y%m%d_%H%M%S)"
cp -a "$JS_FILE"  "$JS_FILE.bak_${STAMP}"
cp -a "$CSS_FILE" "$CSS_FILE.bak_${STAMP}"

echo "Using JS : $JS_FILE"
echo "Using CSS: $CSS_FILE"

echo "--- Patching JS (group tree collapse + group create/edit modal) ---"
python3 - <<PY
from __future__ import annotations
from pathlib import Path

js_path = Path(r"$JS_FILE")
src = js_path.read_text(encoding="utf-8")

MARK = "CF_GROUP_TREE_MODAL_V1"
if MARK in src:
    print("JS already patched (marker found), skip")
else:
    needle = "function renderGroupTree()"
    idx = src.find(needle)
    if idx == -1:
        raise SystemExit("[ERR] Could not find function renderGroupTree() in application.js")

    brace_open = src.find("{", idx)
    if brace_open == -1:
        raise SystemExit("[ERR] Could not find opening brace for renderGroupTree")

    depth = 0
    in_str = None
    escape = False
    i = brace_open
    func_end = None
    while i < len(src):
        ch = src[i]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == in_str:
                in_str = None
        else:
            if ch in ('"', "'", "`"):
                in_str = ch
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    func_end = i
                    break
        i += 1

    if func_end is None:
        raise SystemExit("[ERR] Could not match closing brace for renderGroupTree")

    inject = """

  // === CF_GROUP_TREE_MODAL_V1 ===
  // VSCode-like group collapse + group create/edit modal (parent selectable)
  const CF_GROUP_TREE_STORAGE_KEY = 'cf:groupTreeCollapsed:v1';
  let cfGroupCollapsed = {};
  try { cfGroupCollapsed = JSON.parse(localStorage.getItem(CF_GROUP_TREE_STORAGE_KEY) || '{}'); } catch (e) { cfGroupCollapsed = {}; }

  function cfSaveGroupCollapsed() {
    try { localStorage.setItem(CF_GROUP_TREE_STORAGE_KEY, JSON.stringify(cfGroupCollapsed)); } catch (e) {}
  }

  function cfChildrenMap() {
    return buildChildrenMap(groupsCache);
  }

  function cfCollectSubtreeIds(rootId) {
    const childrenMap = cfChildrenMap();
    const out = new Set([Number(rootId)]);
    const stack = [String(rootId)];
    while (stack.length) {
      const k = stack.pop();
      const kids = childrenMap.get(k) || [];
      for (const child of kids) {
        const cid = Number(child.id);
        if (!out.has(cid)) {
          out.add(cid);
          stack.push(String(child.id));
        }
      }
    }
    return out;
  }

  function cfFlattenGroups(excludeIds = new Set()) {
    const childrenMap = cfChildrenMap();
    const out = [];
    const walk = (parentKey, depth) => {
      const kids = childrenMap.get(parentKey) || [];
      for (const g of kids) {
        const gid = Number(g.id);
        if (!excludeIds.has(gid)) out.push({ group: g, depth });
        walk(String(g.id), depth + 1);
      }
    };
    walk('root', 0);
    return out;
  }

  function cfEnsureGroupModal() {
    let modal = document.getElementById('cf-group-modal');
    if (modal) return modal;

    modal = document.createElement('div');
    modal.id = 'cf-group-modal';
    modal.className = 'cf-modal hidden';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');

    modal.innerHTML = `
      <div class="cf-modal-backdrop" data-close="1"></div>
      <div class="cf-modal-panel">
        <div class="cf-modal-header">
          <strong id="cf-group-modal-title">グループ</strong>
          <button id="cf-group-modal-close" class="cf-btn small" type="button">×</button>
        </div>
        <div class="cf-modal-body">
          <div class="cf-field">
            <label>グループ名</label>
            <input id="cf-gm-name" type="text" />
          </div>
          <div class="cf-field">
            <label>親グループ</label>
            <select id="cf-gm-parent"></select>
          </div>
          <div class="cf-modal-actions" style="gap:8px;">
            <button id="cf-gm-save" class="cf-btn" type="button">保存</button>
            <button id="cf-gm-cancel" class="cf-btn" type="button">キャンセル</button>
          </div>
          <div id="cf-gm-hint" class="cf-muted" style="margin-top:8px;"></div>
        </div>
      </div>
    `;
    document.body.appendChild(modal);

    const close = () => modal.classList.add('hidden');
    modal.querySelector('[data-close="1"]').addEventListener('click', close);
    modal.querySelector('#cf-group-modal-close').addEventListener('click', close);
    modal.querySelector('#cf-gm-cancel').addEventListener('click', close);
    return modal;
  }

  async function cfOpenGroupModal({ mode: formMode, group = null, parentId = null } = {}) {
    const modal = cfEnsureGroupModal();
    const titleEl = modal.querySelector('#cf-group-modal-title');
    const nameEl = modal.querySelector('#cf-gm-name');
    const parentEl = modal.querySelector('#cf-gm-parent');
    const hintEl = modal.querySelector('#cf-gm-hint');
    const saveBtn = modal.querySelector('#cf-gm-save');

    const isEdit = formMode === 'edit';
    const editingGroup = isEdit ? group : null;

    titleEl.textContent = isEdit ? 'グループ編集' : 'グループ作成';
    hintEl.textContent = isEdit ? '名前/親を変更できます（自分自身や子孫は親にできません）' : '名前と親を選んで作成します';

    nameEl.value = isEdit ? (editingGroup?.name || '') : '';
    nameEl.focus();

    parentEl.innerHTML = '';
    const rootOpt = document.createElement('option');
    rootOpt.value = '';
    rootOpt.textContent = '（ルート）';
    parentEl.appendChild(rootOpt);

    let exclude = new Set();
    if (isEdit && editingGroup) exclude = cfCollectSubtreeIds(editingGroup.id);

    const rows = cfFlattenGroups(exclude);
    for (const row of rows) {
      const opt = document.createElement('option');
      opt.value = String(row.group.id);
      const pad = '—'.repeat(row.depth);
      opt.textContent = `${pad}${pad ? ' ' : ''}${row.group.name}`;
      parentEl.appendChild(opt);
    }

    const selected = isEdit
      ? (editingGroup?.parent_id ? String(editingGroup.parent_id) : '')
      : (parentId ? String(parentId) : ((mode === 'group' && selectedGroupId) ? String(selectedGroupId) : ''));

    parentEl.value = selected;

    const handler = async () => {
      const name = (nameEl.value || '').trim();
      if (!name) { alert('グループ名を入力してください'); nameEl.focus(); return; }
      const pid = parentEl.value ? Number(parentEl.value) : null;

      saveBtn.disabled = true;
      try {
        let result = null;
        if (isEdit && editingGroup) {
          result = await apiFetch(`/api/groups/${editingGroup.id}`, {
            method: 'PATCH',
            body: { group: { name: name, parent_id: pid } }
          });
        } else {
          result = await apiFetch('/api/groups', {
            method: 'POST',
            body: { group: { name: name, parent_id: pid } }
          });
        }

        modal.classList.add('hidden');
        await loadGroups();

        const createdId = (!isEdit && result && (result.group?.id || result.id))
          ? Number(result.group?.id || result.id)
          : null;

        if (createdId) {
          selectGroup(createdId);
        } else {
          renderGroupTree();
          if (mode === 'group' && selectedGroupId && selectedGroupLabelEl) {
            const g2 = groupsCache.find(x => Number(x.id) === Number(selectedGroupId));
            selectedGroupLabelEl.textContent = g2 ? g2.name : '未選択';
          }
        }
      } catch (err) {
        console.error(err);
        alert('保存に失敗しました（権限/入力/サーバログを確認してください）');
      } finally {
        saveBtn.disabled = false;
      }
    };

    if (saveBtn._cfHandler) saveBtn.removeEventListener('click', saveBtn._cfHandler);
    saveBtn._cfHandler = handler;
    saveBtn.addEventListener('click', handler);

    modal.classList.remove('hidden');
  }

  function cfRenderGroupTreeVscode() {
    if (!groupTreeEl) return;
    groupTreeEl.innerHTML = '';

    const childrenMap = cfChildrenMap();

    const renderNodes = (parentKey, depth) => {
      const kids = childrenMap.get(parentKey) || [];
      for (const g of kids) {
        const gid = Number(g.id);
        const hasKids = (childrenMap.get(String(g.id)) || []).length > 0;
        const isCollapsed = !!cfGroupCollapsed[gid];

        const li = document.createElement('li');
        li.className = 'cf-tree-item';
        if (mode === 'group' && Number(selectedGroupId) === gid) li.classList.add('active');

        const indent = document.createElement('span');
        indent.className = 'indent';
        indent.style.width = `${depth * 14}px`;

        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'cf-tree-toggle';
        if (!hasKids) {
          toggle.classList.add('placeholder');
          toggle.disabled = true;
          toggle.textContent = '';
        } else {
          toggle.textContent = isCollapsed ? '▶' : '▼';
          toggle.setAttribute('aria-label', isCollapsed ? '展開' : '折りたたみ');
          toggle.addEventListener('click', (e) => {
            e.stopPropagation();
            cfGroupCollapsed[gid] = !cfGroupCollapsed[gid];
            cfSaveGroupCollapsed();
            cfRenderGroupTreeVscode();
          });
        }

        const name = document.createElement('span');
        name.className = 'cf-tree-name';
        name.textContent = g.name;

        const actions = document.createElement('span');
        actions.className = 'cf-tree-actions';

        const addBtn = document.createElement('button');
        addBtn.type = 'button';
        addBtn.className = 'cf-tree-action';
        addBtn.title = '子グループを追加';
        addBtn.textContent = '+';
        addBtn.addEventListener('click', (e) => { e.stopPropagation(); cfOpenGroupModal({ mode: 'create', parentId: gid }); });

        const editBtn = document.createElement('button');
        editBtn.type = 'button';
        editBtn.className = 'cf-tree-action';
        editBtn.title = '編集';
        editBtn.textContent = '✎';
        editBtn.addEventListener('click', (e) => { e.stopPropagation(); cfOpenGroupModal({ mode: 'edit', group: g }); });

        actions.appendChild(addBtn);
        actions.appendChild(editBtn);

        li.appendChild(indent);
        li.appendChild(toggle);
        li.appendChild(name);
        li.appendChild(actions);

        li.addEventListener('click', () => selectGroup(gid));
        groupTreeEl.appendChild(li);

        if (hasKids && !isCollapsed) {
          renderNodes(String(g.id), depth + 1);
        }
      }
    };

    renderNodes('root', 0);
  }

  // Override original renderer with VSCode-like one
  renderGroupTree = cfRenderGroupTreeVscode;

  // Override "+追加" button to open modal (keep parent selectable)
  if (btnCreateGroup) {
    btnCreateGroup.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopImmediatePropagation();
      const pid = (mode === 'group' && selectedGroupId) ? Number(selectedGroupId) : null;
      cfOpenGroupModal({ mode: 'create', parentId: pid });
    }, true);
  }
  // === END CF_GROUP_TREE_MODAL_V1 ===
"""

    patched = src[:func_end + 1] + inject + src[func_end + 1:]
    js_path.write_text(patched, encoding="utf-8")
    print("Injected CF_GROUP_TREE_MODAL_V1 block")
PY

echo "--- Patching CSS (tree item controls) ---"
python3 - <<PY
from __future__ import annotations
from pathlib import Path

css_path = Path(r"$CSS_FILE")
src = css_path.read_text(encoding="utf-8")

MARK = "CF_GROUP_TREE_VSCODE_UI_V1"
if MARK in src:
    print("CSS already patched (marker found), skip")
else:
    block = """

/* === CF_GROUP_TREE_VSCODE_UI_V1 === */
#cf-group-tree { list-style: none; padding-left: 0; margin: 0; }
#cf-group-tree .cf-tree-item {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 8px;
  border-radius: 8px;
  cursor: pointer;
  user-select: none;
}
#cf-group-tree .cf-tree-item:hover { background: rgba(255,255,255,0.06); }
#cf-group-tree .cf-tree-item.active {
  background: rgba(99,102,241,0.14);
  outline: 1px solid rgba(99,102,241,0.45);
}
#cf-group-tree .indent { display: inline-block; }
#cf-group-tree .cf-tree-toggle {
  width: 16px;
  height: 16px;
  padding: 0;
  border: none;
  background: transparent;
  color: inherit;
  opacity: 0.85;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
}
#cf-group-tree .cf-tree-toggle.placeholder { opacity: 0.25; cursor: default; }
#cf-group-tree .cf-tree-toggle:disabled { cursor: default; }
#cf-group-tree .cf-tree-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
#cf-group-tree .cf-tree-actions {
  display: flex;
  gap: 6px;
  margin-left: auto;
  opacity: 0;
}
#cf-group-tree .cf-tree-item:hover .cf-tree-actions { opacity: 1; }
#cf-group-tree .cf-tree-action {
  width: 26px;
  height: 22px;
  border-radius: 8px;
  border: 1px solid rgba(255,255,255,0.16);
  background: rgba(255,255,255,0.05);
  color: inherit;
  cursor: pointer;
}
#cf-group-tree .cf-tree-action:hover { background: rgba(255,255,255,0.09); }
/* === END CF_GROUP_TREE_VSCODE_UI_V1 === */
"""

    css_path.write_text(src + block, encoding="utf-8")
    print("Appended CF_GROUP_TREE_VSCODE_UI_V1 block")
PY

echo "OK: patched files"
echo "Backups:"
echo "  $JS_FILE.bak_${STAMP}"
echo "  $CSS_FILE.bak_${STAMP}"

echo "Next: restart rails server and hard reload (Ctrl+Shift+R)"
