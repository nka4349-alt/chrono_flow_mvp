// ChronoFlow front

function getCsrfToken() {
  const el = document.querySelector('meta[name="csrf-token"]');
  return el ? el.getAttribute('content') : null;
}

async function apiFetch(path, { method = 'GET', body = null } = {}) {
  const headers = { Accept: 'application/json' };
  const csrf = getCsrfToken();
  if (csrf) headers['X-CSRF-Token'] = csrf;
  if (body !== null) headers['Content-Type'] = 'application/json';

  const res = await fetch(path, {
    method,
    headers,
    body: body !== null ? JSON.stringify(body) : null,
    credentials: 'same-origin'
  });

  const isJson = (res.headers.get('content-type') || '').includes('application/json');
  const data = isJson ? await res.json().catch(() => null) : null;

  if (!res.ok) {
    const msg = (data && (data.error || data.message)) ? `${data.error || data.message}` : `HTTP ${res.status}`;
    const err = new Error(msg);
    err.status = res.status;
    err.data = data;
    throw err;
  }

  return data;
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

function toLocalInputValue(date) {
  if (!date) return '';
  const d = (date instanceof Date) ? date : new Date(date);
  if (Number.isNaN(d.getTime())) return '';
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}T${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

function fromLocalInputValue(str) {
  if (!str) return null;
  const d = new Date(str);
  if (Number.isNaN(d.getTime())) return null;
  return d.toISOString();
}

function escapeHtml(s) {
  return String(s || '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function cfBootHome() {
  const root = document.querySelector('.cf-root[data-page="home"]');
  if (!root) return;
  if (root.dataset.cfBooted === '1') return;
  root.dataset.cfBooted = '1';

  const currentUserId = Number(root.dataset.currentUserId || '0');

  // ---- state ----
  let mode = 'home'; // home | group
  let selectedGroupId = null;
  let groupsCache = [];
  let groupOwnerId = null;
  let chatPollTimer = null;
  let calendar = null;

  let chatContext = { type: 'none' }; // none | group | event | direct

  // ---- elements ----
  const groupTreeEl = document.getElementById('cf-group-tree');
  const selectedGroupLabelEl = document.getElementById('cf-selected-group');
  const membersEl = document.getElementById('cf-members');
  const rightTitleEl = document.getElementById('cf-right-title');
  const shareRequestsEl = document.getElementById('cf-share-requests');

  const chatScopeEl = document.getElementById('cf-chat-scope');
  const chatMessagesEl = document.getElementById('cf-chat-messages');
  const chatFormEl = document.getElementById('cf-chat-form');
  const chatInputEl = document.getElementById('cf-chat-input');
  const chatBackBtn = document.getElementById('cf-chat-back');

  const btnModeHome = document.getElementById('cf-mode-home');
  const btnCreateGroup = document.getElementById('cf-create-group');

  const calendarEl = document.getElementById('cf-calendar');

  // modal
  const modalEl = document.getElementById('cf-event-modal');
  const modalTitleEl = document.getElementById('cf-event-modal-title');
  const modalMetaEl = document.getElementById('cf-ev-meta');
  const evTitleEl = document.getElementById('cf-ev-title');
  const evStartEl = document.getElementById('cf-ev-start');
  const evEndEl = document.getElementById('cf-ev-end');
  const evAllDayEl = document.getElementById('cf-ev-all-day');
  const evLocationEl = document.getElementById('cf-ev-location');
  const evColorEl = document.getElementById('cf-ev-color');
  const evNotesEl = document.getElementById('cf-ev-notes');
  const evSaveEl = document.getElementById('cf-ev-save');
  const evDeleteEl = document.getElementById('cf-ev-delete');
  const evAddLinkEl = document.getElementById('cf-ev-add-link');
  const evAddCopyEl = document.getElementById('cf-ev-add-copy');
  const evShareEl = document.getElementById('cf-ev-share');
  const evCloseEl = document.getElementById('cf-event-modal-close');

  const shareModalEl = document.getElementById('cf-share-modal');
  const shareGroupsEl = document.getElementById('cf-share-groups');
  const shareUsersEl = document.getElementById('cf-share-users');
  const shareSubmitEl = document.getElementById('cf-share-submit');
  const shareCloseEl = document.getElementById('cf-share-modal-close');

  let modalEventId = null;


  const EVENT_COLORS = ['#ef4444', '#3b82f6', '#facc15', '#22c55e', '#06b6d4', '#ec4899', '#8b5cf6', '#f97316', '#84cc16', '#111827'];

  function updateColorPaletteSelection() {
    const palette = document.getElementById('cf-ev-color-palette');
    if (!palette || !evColorEl) return;
    const current = (evColorEl.value || '').toLowerCase();
    palette.querySelectorAll('.cf-color-swatch').forEach((btn) => {
      const v = (btn.dataset.color || '').toLowerCase();
      btn.classList.toggle('active', v === current);
    });
  }

  function setEventColor(color) {
    if (!evColorEl) return;
    evColorEl.value = color || EVENT_COLORS[0];
    updateColorPaletteSelection();
  }

  function ensureColorPalette() {
    if (!evColorEl) return;
    let palette = document.getElementById('cf-ev-color-palette');
    if (!palette) {
      palette = document.createElement('div');
      palette.id = 'cf-ev-color-palette';
      palette.className = 'cf-color-palette';
      EVENT_COLORS.forEach((hex) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'cf-color-swatch';
        btn.dataset.color = hex;
        btn.style.background = hex;
        btn.title = hex;
        btn.addEventListener('click', () => setEventColor(hex));
        palette.appendChild(btn);
      });
      evColorEl.type = 'hidden';
      evColorEl.insertAdjacentElement('afterend', palette);
    }
    updateColorPaletteSelection();
  }

  const COLLAPSE_KEY = 'chronoflow:tree-collapsed';
  let collapsed = {};
  try {
    collapsed = JSON.parse(localStorage.getItem(COLLAPSE_KEY) || '{}');
  } catch (e) {
    collapsed = {};
  }

  function saveCollapsed() {
    try {
      localStorage.setItem(COLLAPSE_KEY, JSON.stringify(collapsed));
    } catch (e) {}
  }

  function expandChatComposer() {
    const bar = document.querySelector('.cf-chatbar');
    if (!bar) return;
    bar.classList.add('expanded');
  }

  function collapseChatComposer(force = false) {
    const bar = document.querySelector('.cf-chatbar');
    if (!bar) return;
    if (!force && chatInputEl && chatInputEl.value.trim() !== '') return;
    bar.classList.remove('expanded');
  }

  async function loadShareRequests() {
    if (!shareRequestsEl) return;
    try {
      const data = await apiFetch('/api/event_share_requests');
      const reqs = data.requests || [];
      if (!reqs.length) {
        shareRequestsEl.innerHTML = '<div class="cf-share-title">共有リクエスト</div><div class="cf-muted">リクエストはありません</div>';
        return;
      }
      shareRequestsEl.innerHTML = '<div class="cf-share-title">共有リクエスト</div>' + reqs.map((r) => `
        <div class="cf-share-request">
          <div class="cf-share-request-title">${escapeHtml(r.event_title || 'イベント')}</div>
          <div class="cf-share-request-meta">${escapeHtml(r.requested_by_name || '')} → ${escapeHtml(r.target_name || '')}</div>
          <div class="cf-share-request-actions">
            <button class="cf-btn small cf-share-approve" data-id="${r.id}">承認</button>
            <button class="cf-btn small cf-share-reject" data-id="${r.id}">却下</button>
          </div>
        </div>`).join('');

      shareRequestsEl.querySelectorAll('.cf-share-approve').forEach((btn) => {
        btn.addEventListener('click', async () => {
          try {
            await apiFetch(`/api/event_share_requests/${btn.dataset.id}`, { method: 'PATCH', body: { decision: 'approve' } });
            await loadShareRequests();
            if (calendar) calendar.refetchEvents();
          } catch (e) { alert(`承認失敗: ${e.message}`); }
        });
      });
      shareRequestsEl.querySelectorAll('.cf-share-reject').forEach((btn) => {
        btn.addEventListener('click', async () => {
          try {
            await apiFetch(`/api/event_share_requests/${btn.dataset.id}`, { method: 'PATCH', body: { decision: 'reject' } });
            await loadShareRequests();
          } catch (e) { alert(`却下失敗: ${e.message}`); }
        });
      });
    } catch (e) {
      shareRequestsEl.innerHTML = '<div class="cf-share-title">共有リクエスト</div><div class="cf-muted">読み込み失敗</div>';
    }
  }

  async function openShareModalForEvent() {
    if (!modalEventId) { alert('先にイベントを保存してください'); return; }
    if (!shareGroupsEl || !shareUsersEl) return;

    const groups = groupsCache;
    const usersMap = new Map();

    // friends
    try {
      const fd = await apiFetch('/api/friends');
      const friends = Array.isArray(fd) ? fd : (fd.friends || fd.users || []);
      friends.forEach((u) => usersMap.set(Number(u.id), { id: Number(u.id), name: u.name || u.email || `User#${u.id}`, email: u.email || '', source: 'friend' }));
    } catch (e) {}

    // group members from all visible groups
    for (const g of groups) {
      try {
        const md = await apiFetch(`/api/groups/${g.id}/members`);
        (md.members || []).forEach((u) => {
          const uid = Number(u.user_id || u.id);
          if (uid === currentUserId) return;
          const prev = usersMap.get(uid);
          usersMap.set(uid, {
            id: uid,
            name: u.name || u.email || `User#${uid}`,
            email: u.email || '',
            source: prev ? prev.source : `group:${g.name}`
          });
        });
      } catch (e) {}
    }

    shareGroupsEl.innerHTML = groups.map((g) => `
      <label class="cf-check-row">
        <input type="checkbox" class="cf-share-group" value="${g.id}">
        <span>${escapeHtml(g.name)}</span>
      </label>`).join('');

    shareUsersEl.innerHTML = Array.from(usersMap.values()).map((u) => `
      <label class="cf-check-row">
        <input type="checkbox" class="cf-share-user" value="${u.id}">
        <span>${escapeHtml(u.name)}</span>
        <small class="cf-muted">${escapeHtml(u.email || u.source || '')}</small>
      </label>`).join('');

    openShareModal();
  }

  function openModal() {
    if (modalEl) modalEl.classList.remove('hidden');
  }

  function closeModal() {
    if (modalEl) modalEl.classList.add('hidden');
    modalEventId = null;
    if (modalMetaEl) modalMetaEl.textContent = '';
  }

  function openShareModal() {
    if (shareModalEl) shareModalEl.classList.remove('hidden');
  }

  function closeShareModal() {
    if (shareModalEl) shareModalEl.classList.add('hidden');
  }

  if (modalEl) {
    modalEl.addEventListener('click', (e) => {
      if (e.target && e.target.dataset && e.target.dataset.close) closeModal();
    });
  }
  if (evCloseEl) evCloseEl.addEventListener('click', closeModal);

  if (shareModalEl) {
    shareModalEl.addEventListener('click', (e) => {
      if (e.target && e.target.dataset && e.target.dataset.closeShare) closeShareModal();
    });
  }
  if (shareCloseEl) shareCloseEl.addEventListener('click', closeShareModal);

  ensureColorPalette();

  // ---- group tree helpers ----
  function buildChildrenMap(groups) {
    const map = new Map();
    groups.forEach((g) => {
      const key = g.parent_id == null ? 'root' : String(g.parent_id);
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(g);
    });

    for (const [, arr] of map.entries()) {
      arr.sort((a, b) => {
        const ap = a.position ?? 0;
        const bp = b.position ?? 0;
        if (ap !== bp) return ap - bp;
        return Number(a.id) - Number(b.id);
      });
    }
    return map;
  }

  async function loadGroups() {
    const data = await apiFetch('/api/groups');
    groupsCache = Array.isArray(data) ? data : (data.groups || []);
    renderGroupTree();
  }

  function renderGroupTree() {
    if (!groupTreeEl) return;
    groupTreeEl.innerHTML = '';

    const childrenMap = buildChildrenMap(groupsCache);

    function renderNodes(parentKey, depth) {
      const nodes = childrenMap.get(parentKey) || [];

      nodes.forEach((g) => {
        const gid = Number(g.id);
        const childKey = String(g.id);
        const hasChildren = (childrenMap.get(childKey) || []).length > 0;
        const isCollapsed = !!collapsed[gid];

        const li = document.createElement('li');
        li.className = 'cf-tree-item';
        li.dataset.groupId = String(g.id);
        li.dataset.depth = String(depth);
        if (mode === 'group' && Number(selectedGroupId) === gid) li.classList.add('active');

        const indent = document.createElement('span');
        indent.className = 'indent';
        indent.style.width = `${depth * 14}px`;

        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'cf-tree-toggle';
        if (hasChildren) {
          toggle.textContent = isCollapsed ? '▶' : '▼';
          toggle.addEventListener('click', (e) => {
            e.stopPropagation();
            collapsed[gid] = !collapsed[gid];
            saveCollapsed();
            renderGroupTree();
          });
        } else {
          toggle.classList.add('placeholder');
          toggle.textContent = '';
        }

        const name = document.createElement('span');
        name.className = 'cf-tree-name';
        name.textContent = g.name;

        li.appendChild(indent);
        li.appendChild(toggle);
        li.appendChild(name);

        li.addEventListener('click', () => selectGroup(gid));
        groupTreeEl.appendChild(li);

        if (hasChildren && !isCollapsed) {
          renderNodes(childKey, depth + 1);
        }
      });
    }

    renderNodes('root', 0);
  }

  // ---- sidebar (members / friends) ----
  async function loadMembers(groupId = selectedGroupId) {
    if (!membersEl) return;

    if (!groupId) {
      membersEl.innerHTML = '<div class="cf-muted">未選択</div>';
      return;
    }

    membersEl.innerHTML = '<div class="cf-muted">読み込み中...</div>';

    try {
      const data = await apiFetch(`/api/groups/${groupId}/members`);
      const members = data.members || [];
      const ownerId = data.owner_user_id || data.owner_id || null;
      const canManage = !!data.can_manage_roles || (data.current_user_role === 'admin');
      const currentUser = data.current_user_id || null;
      groupOwnerId = ownerId;

      membersEl.innerHTML = '';

      if (!members.length) {
        membersEl.innerHTML = '<div class="cf-muted">メンバーがいません</div>';
        return;
      }

      members.forEach((m) => {
        const uid = Number(m.user_id || m.id || 0);
        const role = (m.role || '').toString();
        const isOwner = !!m.is_owner || (ownerId && Number(ownerId) === uid);

        const row = document.createElement('div');
        row.className = 'cf-member-row';

        const left = document.createElement('div');
        left.innerHTML = `
          <div class="cf-member-name">${escapeHtml(m.name || m.email || `User#${uid}`)}</div>
          <div class="cf-member-role">${escapeHtml(role)}${isOwner ? ' (owner)' : ''}</div>
        `;

        const right = document.createElement('div');
        right.className = 'cf-member-actions';

        const dmBtn = document.createElement('button');
        dmBtn.type = 'button';
        dmBtn.className = 'cf-btn small';
        dmBtn.textContent = '💬';
        dmBtn.title = 'ダイレクトメッセージ';
        dmBtn.addEventListener('click', (e) => {
          e.stopPropagation();
          startDirectChat(uid, m.name || m.email || `User#${uid}`);
        });
        right.appendChild(dmBtn);

        if (canManage && uid && !isOwner && uid !== Number(currentUser || 0)) {
          const sel = document.createElement('select');
          sel.className = 'cf-select';
          sel.innerHTML = `
            <option value="member">member</option>
            <option value="admin">admin</option>
          `;
          sel.value = role;
          sel.addEventListener('change', async () => {
            const nextRole = sel.value;
            try {
              await apiFetch(`/api/groups/${groupId}/members/${uid}/role`, {
                method: 'PATCH',
                body: { role: nextRole }
              });
              await loadMembers(groupId);
            } catch (e) {
              alert(`更新に失敗: ${e.message}`);
              sel.value = role;
            }
          });
          right.appendChild(sel);
        }

        row.appendChild(left);
        row.appendChild(right);

        row.addEventListener('click', () => {
          startDirectChat(uid, m.name || m.email || `User#${uid}`);
        });

        membersEl.appendChild(row);
      });
    } catch (e) {
      console.error(e);
      membersEl.innerHTML = `<div class="cf-muted">読み込み失敗: ${escapeHtml(e.message)}</div>`;
    }
  }

  async function loadFriends() {
    if (!membersEl) return;

    membersEl.innerHTML = '<div class="cf-muted">読み込み中...</div>';

    try {
      const data = await apiFetch('/api/friends');
      const friends = Array.isArray(data) ? data : (data.friends || data.users || []);

      membersEl.innerHTML = '';

      if (!friends.length) {
        membersEl.innerHTML = '<div class="cf-muted">フレンドがいません</div>';
        return;
      }

      friends.forEach((f) => {
        const uid = Number(f.id);
        const label = f.name || f.email || `User#${uid}`;

        const row = document.createElement('div');
        row.className = 'cf-friend-row';
        row.innerHTML = `
          <div>
            <div class="cf-member-name">${escapeHtml(label)}</div>
            <div class="cf-member-role">${escapeHtml(f.email || '')}</div>
          </div>
          <div class="cf-member-actions">
            <button type="button" class="cf-btn small cf-dm-btn">💬</button>
          </div>
        `;

        row.addEventListener('click', () => {
          startDirectChat(uid, label);
        });

        const dm = row.querySelector('.cf-dm-btn');
        if (dm) {
          dm.addEventListener('click', (e) => {
            e.stopPropagation();
            startDirectChat(uid, label);
          });
        }

        membersEl.appendChild(row);
      });
    } catch (e) {
      console.error(e);
      membersEl.innerHTML = `<div class="cf-muted">フレンド取得失敗: ${escapeHtml(e.message)}</div>`;
    }
  }

  async function selectGroup(groupId) {
    mode = 'group';
    selectedGroupId = Number(groupId);

    const g = groupsCache.find((x) => Number(x.id) === Number(groupId));
    if (selectedGroupLabelEl) {
      selectedGroupLabelEl.textContent = g ? g.name : `Group#${groupId}`;
    }
    if (rightTitleEl) rightTitleEl.textContent = 'メンバー';

    renderGroupTree();
    await loadMembers(selectedGroupId);
    await loadShareRequests();
    setChatContext({ type: 'group', groupId: selectedGroupId });

    if (calendar) calendar.refetchEvents();
  }

  async function selectHome() {
    mode = 'home';
    selectedGroupId = null;
    groupOwnerId = null;

    if (selectedGroupLabelEl) selectedGroupLabelEl.textContent = '未選択';
    if (rightTitleEl) rightTitleEl.textContent = 'フレンド';

    renderGroupTree();
    await loadFriends();
    await loadShareRequests();
    setChatContext({ type: 'none' });

    if (calendar) calendar.refetchEvents();
  }

  if (chatInputEl) {
    chatInputEl.addEventListener('focus', () => expandChatComposer());
  }

  document.addEventListener('mousedown', (e) => {
    const bar = document.querySelector('.cf-chatbar');
    if (!bar || !bar.classList.contains('expanded')) return;
    if (chatFormEl && chatFormEl.contains(e.target)) return;
    collapseChatComposer(true);
  });

  if (btnModeHome) {
    btnModeHome.addEventListener('click', () => { selectHome(); });
  }

  if (btnCreateGroup && !btnCreateGroup.dataset.cfBound) {
    btnCreateGroup.dataset.cfBound = '1';
    btnCreateGroup.addEventListener('click', async () => {
      const name = prompt('新しいグループ名');
      if (!name) return;

      const parentId = (mode === 'group' && selectedGroupId) ? selectedGroupId : null;

      try {
        await apiFetch('/api/groups', {
          method: 'POST',
          body: { group: { name, parent_id: parentId, position: 0 } }
        });
        await loadGroups();
      } catch (e) {
        alert(`作成に失敗: ${e.message}`);
      }
    });
  }

  // ---- chat ----
  function chatEndpointFor(ctx) {
    if (!ctx || ctx.type === 'none') return null;
    if (ctx.type === 'group' && ctx.groupId) return `/api/groups/${ctx.groupId}/chat_messages`;
    if (ctx.type === 'event' && ctx.eventId) return `/api/events/${ctx.eventId}/chat_messages`;
    if (ctx.type === 'direct' && ctx.directChatId) return `/api/direct_chats/${ctx.directChatId}/chat_messages`;
    return null;
  }

  function stopChat() {
    if (chatPollTimer) {
      clearInterval(chatPollTimer);
      chatPollTimer = null;
    }
  }

  function updateChatHeader() {
    if (!chatScopeEl) return;

    if (chatContext.type === 'none') {
      chatScopeEl.textContent = '（グループ未選択）';
      if (chatBackBtn) chatBackBtn.classList.add('hidden');
      return;
    }

    if (chatContext.type === 'group') {
      const g = groupsCache.find((x) => Number(x.id) === Number(chatContext.groupId));
      chatScopeEl.textContent = g ? `（${g.name}）` : `（Group#${chatContext.groupId}）`;
      if (chatBackBtn) chatBackBtn.classList.add('hidden');
      return;
    }

    if (chatContext.type === 'event') {
      const title = (chatContext.eventTitle || '').toString().trim();
      chatScopeEl.textContent = title ? `（${title}）` : `（Event#${chatContext.eventId}）`;
      if (chatBackBtn) {
        if (mode === 'group' && selectedGroupId) chatBackBtn.classList.remove('hidden');
        else chatBackBtn.classList.add('hidden');
      }
      return;
    }

    if (chatContext.type === 'direct') {
      const name = (chatContext.userName || '').toString().trim();
      chatScopeEl.textContent = name ? `（${name}）` : '（ダイレクトメッセージ）';
      if (chatBackBtn) chatBackBtn.classList.remove('hidden');
    }
  }

  async function loadChatMessages() {
    const endpoint = chatEndpointFor(chatContext);
    if (!endpoint) {
      if (chatMessagesEl) chatMessagesEl.innerHTML = '';
      return;
    }

    const data = await apiFetch(`${endpoint}?limit=80`);
    const msgs = data.messages || [];

    chatMessagesEl.innerHTML = '';
    msgs.forEach((m) => {
      const p = document.createElement('p');
      p.className = 'cf-chat-line';

      const t = m.created_at ? new Date(m.created_at) : null;
      const at = t && !Number.isNaN(t.getTime()) ? `${pad2(t.getHours())}:${pad2(t.getMinutes())}` : '';

      const who = m.user_name || (m.user && (m.user.name || m.user.email)) || 'user';
      p.innerHTML = `<span class="who">${escapeHtml(who)}</span><span class="at">${escapeHtml(at)}</span>：${escapeHtml(m.body)}`;
      chatMessagesEl.appendChild(p);
    });

    chatMessagesEl.scrollTop = chatMessagesEl.scrollHeight;
  }

  function setChatContext(ctx) {
    chatContext = ctx || { type: 'none' };
    updateChatHeader();
    stopChat();

    const endpoint = chatEndpointFor(chatContext);
    if (!endpoint) {
      if (chatMessagesEl) chatMessagesEl.innerHTML = '';
      return;
    }

    loadChatMessages().catch((e) => console.error(e));
    chatPollTimer = setInterval(() => {
      loadChatMessages().catch((e) => console.error(e));
    }, 5000);
    root._cfChatPollTimer = chatPollTimer;
    root._cfChatPollTimer = chatPollTimer;
  }

  async function startDirectChat(userId, userLabel) {
    try {
      const data = await apiFetch('/api/direct_chats', {
        method: 'POST',
        body: { user_id: Number(userId) }
      });

      const directChatId =
        (data && data.direct_chat && data.direct_chat.id) ||
        data.id ||
        data.direct_chat_id;

      if (!directChatId) throw new Error('direct_chat_id not returned');

      setChatContext({
        type: 'direct',
        directChatId: Number(directChatId),
        userId: Number(userId),
        userName: userLabel || (data.peer && data.peer.name) || ''
      });
    } catch (e) {
      alert(`DM開始に失敗: ${e.message}`);
    }
  }

  if (chatBackBtn) {
    chatBackBtn.addEventListener('click', () => {
      if (mode === 'group' && selectedGroupId) {
        setChatContext({ type: 'group', groupId: Number(selectedGroupId) });
      } else {
        setChatContext({ type: 'none' });
      }
    });
  }

  if (chatFormEl) {
    chatFormEl.addEventListener('submit', async (e) => {
      e.preventDefault();
      const text = chatInputEl.value.trim();
      if (!text) return;

      const endpoint = chatEndpointFor(chatContext);
      if (!endpoint) {
        alert('送信先がありません');
        return;
      }

      try {
        await apiFetch(endpoint, {
          method: 'POST',
          body: { body: text }
        });
        chatInputEl.value = '';
        await loadChatMessages();
        collapseChatComposer(true);
      } catch (err) {
        alert(`送信に失敗: ${err.message}`);
      }
    });
  }

  // ---- calendar ----
  if (!calendarEl) return;

  if (calendarEl._cfCalendar) {
    try { calendarEl._cfCalendar.destroy(); } catch (e) {}
    calendarEl._cfCalendar = null;
    calendarEl.innerHTML = '';
  }

  function ensureFullCalendarReady() {
    return typeof window.FullCalendar !== 'undefined' && window.FullCalendar && window.FullCalendar.Calendar;
  }

  function initCalendar() {
    calendar = new window.FullCalendar.Calendar(calendarEl, {
      initialView: 'dayGridMonth',
      height: '100%',
      fixedWeekCount: true,
      expandRows: true,
      dayMaxEventRows: 2,
      moreLinkClick: 'popover',
      headerToolbar: {
        left: 'prev,next today',
        center: 'title',
        right: 'dayGridMonth,timeGridWeek,timeGridDay'
      },
      nowIndicator: true,
      selectable: true,
      eventDisplay: 'block',
      eventTimeFormat: { hour: '2-digit', minute: '2-digit', hour12: false },

      views: {
        dayGridMonth: {
          fixedWeekCount: true,
          dayMaxEventRows: 2,
          moreLinkClick: 'popover'
        },
        timeGridWeek: {
          slotMinTime: '06:00:00',
          slotMaxTime: '24:00:00',
          slotDuration: '00:30:00',
          slotEventOverlap: false,
          eventMaxStack: 12,
          allDaySlot: true
        },
        timeGridDay: {
          slotMinTime: '06:00:00',
          slotMaxTime: '24:00:00',
          slotDuration: '00:30:00',
          slotEventOverlap: false,
          eventMaxStack: 12
        }
      },

      datesSet: (info) => {
        calendarEl.classList.toggle('cf-month-view', info.view.type === 'dayGridMonth');
        calendarEl.classList.toggle('cf-week-view', info.view.type === 'timeGridWeek');
        calendarEl.classList.toggle('cf-day-view', info.view.type === 'timeGridDay');
      },

      // Week pseudo gantt for same-day timed events
      eventDidMount: (info) => {
        try {
          if (!info || !info.view || info.view.type !== 'dayGridWeek') return;
          const ev = info.event;
          if (!ev || ev.allDay) return;

          const start = ev.start;
          if (!start) return;
          const end0 = ev.end ? ev.end : new Date(start.getTime() + 30 * 60 * 1000);

          const startKey = start.toISOString().slice(0, 10);
          const endKey = end0.toISOString().slice(0, 10);
          const endsAtMidnight = (end0.getHours() === 0 && end0.getMinutes() === 0);
          const endMinus1Key = new Date(end0.getTime() - 1).toISOString().slice(0, 10);
          const sameDay = (startKey === endKey) || (endsAtMidnight && endMinus1Key === startKey);
          if (!sameDay) return;

          let startMin = start.getHours() * 60 + start.getMinutes();
          let endMin = end0.getHours() * 60 + end0.getMinutes();
          if (startKey !== endKey && endsAtMidnight) endMin = 1440;

          const dur = Math.max(5, endMin - startMin);
          const startPct = (startMin / 1440) * 100;
          const widthPct = (dur / 1440) * 100;

          const el = info.el;
          el.classList.add('cf-week-timed');
          el.style.setProperty('--cf-start-pct', startPct.toFixed(2));
          el.style.setProperty('--cf-width-pct', widthPct.toFixed(2));

          const cs = window.getComputedStyle(el);
          const bg = cs && cs.backgroundColor ? cs.backgroundColor : null;
          if (bg) el.style.setProperty('--cf-bar-color', bg);

          const endLabelH = (startKey !== endKey && endsAtMidnight) ? 24 : end0.getHours();
          const endLabelM = (startKey !== endKey && endsAtMidnight) ? 0 : end0.getMinutes();
          const label = `${pad2(start.getHours())}:${pad2(start.getMinutes())}–${pad2(endLabelH)}:${pad2(endLabelM)}`;
          const timeEl = el.querySelector('.fc-event-time');
          if (timeEl) timeEl.textContent = label;
        } catch (e) {
          console.warn('[cf-week-gantt] eventDidMount error', e);
        }
      },

      events: async (fetchInfo, success, failure) => {
        try {
          const params = new URLSearchParams();
          params.set('start', fetchInfo.startStr);
          params.set('end', fetchInfo.endStr);

          let data;
          if (mode === 'group' && selectedGroupId) {
            data = await apiFetch(`/api/groups/${selectedGroupId}/events?${params.toString()}`);
          } else {
            params.set('scope', 'home');
            data = await apiFetch(`/api/events?${params.toString()}`);
          }

          const evs = Array.isArray(data) ? data : ((data && data.events) ? data.events : []);
          success(evs);
        } catch (err) {
          console.error(err);
          failure(err);
        }
      },

      dateClick: (info) => {
        openCreateModal(info.date);
      },

      eventClick: (info) => {
        openEditModal(info.event);
        setChatContext({
          type: 'event',
          eventId: Number(info.event.id),
          eventTitle: info.event.title || ''
        });
      }
    });

    calendarEl._cfCalendar = calendar;
    calendar.render();

    loadGroups()
      .then(() => selectHome())
      .catch((e) => {
        console.error(e);
        alert('グループ読み込みに失敗しました。ログイン状態を確認してください。');
      });
  }

  if (!ensureFullCalendarReady()) {
    const t0 = Date.now();
    const timer = setInterval(() => {
      if (ensureFullCalendarReady() || Date.now() - t0 > 3000) {
        clearInterval(timer);
        initCalendar();
      }
    }, 50);
  } else {
    initCalendar();
  }

  // ---- modal ----
  function openCreateModal(date) {
    modalEventId = null;
    modalTitleEl.textContent = 'イベント作成';

    evTitleEl.value = '';
    evStartEl.value = toLocalInputValue(date);
    const endDate = new Date(date);
    endDate.setHours(endDate.getHours() + 1);
    evEndEl.value = toLocalInputValue(endDate);
    evAllDayEl.checked = false;
    if (evLocationEl) evLocationEl.value = '';
    setEventColor('#3b82f6');
    if (evNotesEl) evNotesEl.value = '';

    evDeleteEl.style.display = 'none';
    evAddLinkEl.style.display = 'none';
    evAddCopyEl.style.display = 'none';
    if (evShareEl) evShareEl.style.display = 'none';

    if (modalMetaEl) {
      const cg = (mode === 'group' && selectedGroupId)
        ? groupsCache.find(x => Number(x.id) === Number(selectedGroupId))
        : null;

      modalMetaEl.textContent = (mode === 'group' && selectedGroupId)
        ? `作成先：${cg ? cg.name : 'グループ'}`
        : '作成先：個人';
    }

    openModal();
  }

  function openEditModal(fcEvent) {
    modalEventId = Number(fcEvent.id);
    modalTitleEl.textContent = 'イベント編集';

    evTitleEl.value = fcEvent.title || '';
    evStartEl.value = toLocalInputValue(fcEvent.start);
    evEndEl.value = toLocalInputValue(fcEvent.end);
    evAllDayEl.checked = !!fcEvent.allDay;
    const ext = fcEvent.extendedProps || {};
    if (evLocationEl) evLocationEl.value = ext.location || '';
    setEventColor(fcEvent.backgroundColor || ext.color || '#3b82f6');
    if (evNotesEl) evNotesEl.value = ext.description || '';

    evDeleteEl.style.display = 'inline-block';
    evAddLinkEl.style.display = 'inline-block';
    evAddCopyEl.style.display = 'inline-block';
    if (evShareEl) evShareEl.style.display = 'inline-block';
    const gids = Array.isArray(ext.group_ids) ? ext.group_ids : [];
    const groupNames = gids.map((id) => {
      const g = groupsCache.find(x => Number(x.id) === Number(id));
      return g ? g.name : null;
    }).filter(Boolean);

    if (modalMetaEl) {
      modalMetaEl.textContent = groupNames.length
        ? `共有先：${groupNames.join(' / ')}`
        : '';
    }

    openModal();
  }

  if (evSaveEl) {
    evSaveEl.addEventListener('click', async () => {
      const title = evTitleEl.value.trim();
      if (!title) {
        alert('タイトルは必須です');
        return;
      }

      const payload = {
        event: {
          title,
          start_at: fromLocalInputValue(evStartEl.value),
          end_at: fromLocalInputValue(evEndEl.value),
          all_day: !!evAllDayEl.checked,
          location: evLocationEl ? evLocationEl.value.trim() : '',
          color: evColorEl ? evColorEl.value : '',
          description: evNotesEl ? evNotesEl.value : ''
        }
      };

      if (mode === 'group' && selectedGroupId && modalEventId === null) {
        payload.group_ids = [selectedGroupId];
      }

      try {
        if (modalEventId === null) {
          await apiFetch('/api/events', { method: 'POST', body: payload });
        } else {
          await apiFetch(`/api/events/${modalEventId}`, { method: 'PATCH', body: payload });
        }

        closeModal();
        if (calendar) calendar.refetchEvents();
      } catch (e) {
        alert(`保存に失敗: ${e.message}`);
      }
    });
  }

  if (evDeleteEl) {
    evDeleteEl.addEventListener('click', async () => {
      if (!modalEventId) return;
      if (!confirm('削除しますか？')) return;

      try {
        await apiFetch(`/api/events/${modalEventId}`, { method: 'DELETE' });
        closeModal();
        if (calendar) calendar.refetchEvents();
      } catch (e) {
        alert(`削除に失敗: ${e.message}`);
      }
    });
  }

  if (evAddLinkEl) {
    evAddLinkEl.addEventListener('click', async () => {
      if (!modalEventId) return;
      try {
        await apiFetch(`/api/events/${modalEventId}/add_to_my_calendar`, {
          method: 'POST',
          body: { mode: 'link' }
        });
        alert('取り込みました（リンク）');
        if (calendar) calendar.refetchEvents();
      } catch (e) {
        alert(`取り込みに失敗: ${e.message}`);
      }
    });
  }

  if (evAddCopyEl) {
    evAddCopyEl.addEventListener('click', async () => {
      if (!modalEventId) return;
      try {
        await apiFetch(`/api/events/${modalEventId}/add_to_my_calendar`, {
          method: 'POST',
          body: { mode: 'copy' }
        });
        alert('取り込みました（コピー）');
        closeModal();
        if (calendar) calendar.refetchEvents();
      } catch (e) {
        alert(`取り込みに失敗: ${e.message}`);
      }
    });
  }

  if (evShareEl) {
    evShareEl.addEventListener('click', async () => {
      await openShareModalForEvent();
    });
  }

  if (shareSubmitEl) {
    shareSubmitEl.addEventListener('click', async () => {
      if (!modalEventId) return;

      const groupIds = Array.from(document.querySelectorAll('.cf-share-group:checked')).map((el) => Number(el.value));
      const userIds = Array.from(document.querySelectorAll('.cf-share-user:checked')).map((el) => Number(el.value));

      try {
        await apiFetch(`/api/events/${modalEventId}/share_requests`, {
          method: 'POST',
          body: { group_ids: groupIds, user_ids: userIds }
        });
        alert('共有リクエストを送信しました');
        closeShareModal();
        await loadShareRequests();
      } catch (e) {
        alert(`共有に失敗: ${e.message}`);
      }
    });
  }
}

// ---- boot / turbo ----
(function() {
  const boot = () => {
    try { cfBootHome(); } catch (e) { console.error(e); }
  };

  document.addEventListener('DOMContentLoaded', boot);
  document.addEventListener('turbo:load', boot);

  document.addEventListener('turbo:before-cache', () => {
    try {
      const root = document.querySelector('.cf-root[data-page="home"]');
      if (root) {
        delete root.dataset.cfBooted;
        if (root._cfChatPollTimer) {
          clearInterval(root._cfChatPollTimer);
          root._cfChatPollTimer = null;
        }
      }

      const calEl = document.getElementById('cf-calendar');
      if (calEl && calEl._cfCalendar) {
        try { calEl._cfCalendar.destroy(); } catch (e) {}
        calEl._cfCalendar = null;
        calEl.innerHTML = '';
      }
    } catch (e) {}
  });
})();

/* === CF_CHAT_EXPAND_HIDE_LINK_PATCH === */
(function() {
  function bootChatExpandPatch() {
    const chatbar = document.querySelector('.cf-chatbar');
    const form = document.getElementById('cf-chat-form');
    const input = document.getElementById('cf-chat-input');
    const linkBtn = document.getElementById('cf-ev-add-link');

    if (!chatbar || !form || !input) return;
    if (chatbar.dataset.cfExpandPatchBound === '1') return;
    chatbar.dataset.cfExpandPatchBound = '1';

    function openChatbar() {
      chatbar.classList.add('expanded');
    }

    function closeChatbar(force) {
      const hasText = !!(input.value && input.value.trim().length > 0);
      if (force || !hasText) {
        chatbar.classList.remove('expanded');
      }
    }

    input.addEventListener('focus', openChatbar);
    input.addEventListener('click', openChatbar);
    form.addEventListener('click', function(e) {
      e.stopPropagation();
      openChatbar();
    });

    document.addEventListener('click', function(e) {
      if (!chatbar.classList.contains('expanded')) return;
      if (chatbar.contains(e.target)) return;
      closeChatbar(false);
    });

    document.addEventListener('keydown', function(e) {
      if (e.key === 'Escape') closeChatbar(true);
    });

    form.addEventListener('submit', function() {
      setTimeout(function() {
        if (!input.value || input.value.trim().length === 0) {
          closeChatbar(true);
        }
      }, 250);
    });

    if (linkBtn) {
      linkBtn.style.display = 'none';
    }
  }

  document.addEventListener('DOMContentLoaded', bootChatExpandPatch);
  document.addEventListener('turbo:load', bootChatExpandPatch);
})();
// === CF_GROUP_EDIT_PROMPT_PATCH ===
(function () {
  if (window.__cfGroupEditPatchLoaded) return;
  window.__cfGroupEditPatchLoaded = true;

  async function fetchGroupsForEdit() {
    const data = await apiFetch('/api/groups');
    return Array.isArray(data) ? data : (data.groups || []);
  }

  function buildChildrenMap(groups) {
    const map = new Map();
    groups.forEach((g) => {
      const key = g.parent_id == null ? 'root' : String(g.parent_id);
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(g);
    });
    return map;
  }

  function collectDescendants(groups, rootId) {
    const map = buildChildrenMap(groups);
    const out = new Set();
    const stack = [String(rootId)];

    while (stack.length) {
      const key = stack.pop();
      const children = map.get(key) || [];
      children.forEach((g) => {
        const gid = Number(g.id);
        if (!out.has(gid)) {
          out.add(gid);
          stack.push(String(g.id));
        }
      });
    }

    return out;
  }

  async function openEditGroupPrompt(groupId) {
    const groups = await fetchGroupsForEdit();
    const target = groups.find((g) => Number(g.id) === Number(groupId));
    if (!target) {
      alert('グループが見つかりません');
      return;
    }

    const newName = prompt('グループ名を入力してください', target.name || '');
    if (newName === null) return;
    if (!newName.trim()) {
      alert('グループ名は必須です');
      return;
    }

    const excluded = collectDescendants(groups, target.id);
    excluded.add(Number(target.id));

    const parentCandidates = groups
      .filter((g) => !excluded.has(Number(g.id)))
      .map((g) => `${g.id}: ${g.name}`)
      .join('\n');

    const currentParent = target.parent_id == null ? '' : String(target.parent_id);
    const parentInput = prompt(
      `親グループIDを入力してください（空欄でルート）\n\n選択候補:\n${parentCandidates}`,
      currentParent
    );
    if (parentInput === null) return;

    const parentId = parentInput.trim() === '' ? null : Number(parentInput);
    if (parentInput.trim() !== '' && Number.isNaN(parentId)) {
      alert('親グループIDが不正です');
      return;
    }

    try {
      await apiFetch(`/api/groups/${target.id}`, {
        method: 'PATCH',
        body: {
          group: {
            name: newName.trim(),
            parent_id: parentId
          }
        }
      });
      window.location.reload();
    } catch (e) {
      alert(`グループ更新に失敗: ${e.message}`);
    }
  }

  function injectEditButtons() {
    const tree = document.getElementById('cf-group-tree');
    if (!tree) return;

    tree.querySelectorAll('li[data-group-id], li[data-groupid], li').forEach((li) => {
      const gid = li.dataset.groupId || li.getAttribute('data-group-id');
      if (!gid) return;
      if (li.querySelector('.cf-group-edit-btn')) return;

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'cf-btn small cf-group-edit-btn';
      btn.textContent = '✎';
      btn.title = 'グループ編集';
      btn.style.marginLeft = '6px';

      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        openEditGroupPrompt(gid);
      });

      li.appendChild(btn);
    });
  }

  function bootGroupEditButtons() {
    injectEditButtons();

    const tree = document.getElementById('cf-group-tree');
    if (!tree || tree.dataset.cfGroupEditObserved === '1') return;

    tree.dataset.cfGroupEditObserved = '1';
    const obs = new MutationObserver(() => injectEditButtons());
    obs.observe(tree, { childList: true, subtree: true });
  }

  document.addEventListener('DOMContentLoaded', bootGroupEditButtons);
  document.addEventListener('turbo:load', bootGroupEditButtons);
})();
/* === END CF_CHAT_EXPAND_HIDE_LINK_PATCH === */

// === CF_GROUP_EDIT_MODAL_FORMAL ===
(function () {
  if (window.__CF_GROUP_EDIT_MODAL_FORMAL__) return;
  window.__CF_GROUP_EDIT_MODAL_FORMAL__ = true;

  async function cfFetchGroups() {
    const data = await apiFetch('/api/groups');
    return Array.isArray(data) ? data : (data.groups || []);
  }

  function cfBuildChildrenMap(groups) {
    const map = new Map();
    groups.forEach((g) => {
      const key = g.parent_id == null ? 'root' : String(g.parent_id);
      if (!map.has(key)) map.set(key, []);
      map.get(key).push(g);
    });
    return map;
  }

  function cfCollectDescendants(groups, rootId) {
    const map = cfBuildChildrenMap(groups);
    const out = new Set();
    const stack = [String(rootId)];

    while (stack.length) {
      const key = stack.pop();
      const children = map.get(key) || [];
      children.forEach((g) => {
        const gid = Number(g.id);
        if (!out.has(gid)) {
          out.add(gid);
          stack.push(String(g.id));
        }
      });
    }
    return out;
  }

  function cfEnsureGroupModal() {
    let modal = document.getElementById('cf-group-edit-modal');
    if (modal) return modal;

    modal = document.createElement('div');
    modal.id = 'cf-group-edit-modal';
    modal.className = 'cf-modal hidden';
    modal.innerHTML = `
      <div class="cf-modal-backdrop" data-close-group-modal="1"></div>
      <div class="cf-modal-panel">
        <div class="cf-modal-header">
          <strong id="cf-group-edit-title">グループ編集</strong>
          <button id="cf-group-edit-close" class="cf-btn small" type="button">×</button>
        </div>
        <div class="cf-modal-body">
          <div class="cf-field">
            <label>グループ名</label>
            <input id="cf-group-edit-name" type="text" />
          </div>
          <div class="cf-field">
            <label>親グループ</label>
            <select id="cf-group-edit-parent"></select>
          </div>
          <div class="cf-modal-actions">
            <button id="cf-group-edit-save" class="cf-btn" type="button">保存</button>
            <button id="cf-group-edit-delete" class="cf-btn danger" type="button">削除</button>
            <button class="cf-btn" type="button" data-close-group-modal="1">閉じる</button>
          </div>
        </div>
      </div>
    `;
    document.body.appendChild(modal);

    modal.addEventListener('click', (e) => {
      if (e.target && e.target.dataset && e.target.dataset.closeGroupModal) {
        modal.classList.add('hidden');
      }
    });
    modal.querySelector('#cf-group-edit-close').addEventListener('click', () => {
      modal.classList.add('hidden');
    });

    return modal;
  }

  function cfFillParentOptions(selectEl, groups, excludeIds, selectedParentId) {
    const map = cfBuildChildrenMap(groups);
    selectEl.innerHTML = '';

    const rootOpt = document.createElement('option');
    rootOpt.value = '';
    rootOpt.textContent = '（ルート）';
    selectEl.appendChild(rootOpt);

    function walk(parentKey, depth) {
      const nodes = map.get(parentKey) || [];
      nodes.forEach((g) => {
        if (excludeIds.has(Number(g.id))) return;

        const opt = document.createElement('option');
        opt.value = String(g.id);
        opt.textContent = `${'—'.repeat(depth)} ${g.name}`.trim();
        if (selectedParentId != null && Number(selectedParentId) === Number(g.id)) {
          opt.selected = true;
        }
        selectEl.appendChild(opt);

        walk(String(g.id), depth + 1);
      });
    }

    walk('root', 0);
  }

  async function cfOpenGroupEditModal(groupId) {
    const groups = await cfFetchGroups();
    const target = groups.find((g) => Number(g.id) === Number(groupId));
    if (!target) {
      alert('グループが見つかりません');
      return;
    }

    const modal = cfEnsureGroupModal();
    const nameEl = modal.querySelector('#cf-group-edit-name');
    const parentEl = modal.querySelector('#cf-group-edit-parent');
    const saveEl = modal.querySelector('#cf-group-edit-save');
    const deleteEl = modal.querySelector('#cf-group-edit-delete');

    nameEl.value = target.name || '';

    const excludeIds = new Set([Number(target.id)]);
    cfCollectDescendants(groups, target.id).forEach((id) => excludeIds.add(Number(id)));
    cfFillParentOptions(parentEl, groups, excludeIds, target.parent_id);

    modal.classList.remove('hidden');

    saveEl.onclick = async () => {
      const payload = {
        group: {
          name: nameEl.value.trim(),
          parent_id: parentEl.value ? Number(parentEl.value) : null
        }
      };

      if (!payload.group.name) {
        alert('グループ名を入力してください');
        return;
      }

      try {
        await apiFetch(`/api/groups/${target.id}`, {
          method: 'PATCH',
          body: payload
        });
        window.location.reload();
      } catch (e) {
        alert(`更新に失敗: ${e.message}`);
      }
    };

    deleteEl.onclick = async () => {
      if (!confirm(`グループ「${target.name}」を削除しますか？\n子グループは親へ繰り上げられます。`)) {
        return;
      }

      try {
        await apiFetch(`/api/groups/${target.id}`, {
          method: 'DELETE'
        });
        window.location.reload();
      } catch (e) {
        alert(`削除に失敗: ${e.message}`);
      }
    };
  }

  function cfInjectFormalEditButtons() {
    const tree = document.getElementById('cf-group-tree');
    if (!tree) return;

    tree.querySelectorAll('li').forEach((li) => {
      const gid = li.dataset.groupId || li.getAttribute('data-group-id');
      if (!gid) return;

      // 以前の簡易版ボタンを消す
      li.querySelectorAll('.cf-group-edit-btn').forEach((oldBtn) => oldBtn.remove());

      if (li.querySelector('.cf-group-edit-formal-btn')) return;

      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'cf-btn small cf-group-edit-formal-btn';
      btn.textContent = '✎';
      btn.title = 'グループ編集';
      btn.style.marginLeft = '6px';

      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        cfOpenGroupEditModal(gid);
      });

      li.appendChild(btn);
    });
  }

  function cfBootFormalGroupEdit() {
    cfInjectFormalEditButtons();

    const tree = document.getElementById('cf-group-tree');
    if (!tree || tree.dataset.cfFormalEditObserved === '1') return;

    tree.dataset.cfFormalEditObserved = '1';
    const obs = new MutationObserver(() => cfInjectFormalEditButtons());
    obs.observe(tree, { childList: true, subtree: true });
  }

  document.addEventListener('DOMContentLoaded', cfBootFormalGroupEdit);
  document.addEventListener('turbo:load', cfBootFormalGroupEdit);
})();
// === END CF_GROUP_EDIT_MODAL_FORMAL ===
