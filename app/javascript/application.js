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
  const btnOpenSearch = document.getElementById('cf-open-search');
  const mobileOverlayEl = document.getElementById('cf-mobile-overlay');
  const mobileMenuHomeEl = document.getElementById('cf-mobile-menu-home');
  const mobileMenuGroupsEl = document.getElementById('cf-mobile-menu-groups');
  const mobileMenuMembersEl = document.getElementById('cf-mobile-menu-members');
  const mobileMenuCreateEl = document.getElementById('cf-mobile-menu-create');
  const mobileMenuSearchEl = document.getElementById('cf-mobile-menu-search');
  const mobileLayoutMq = window.matchMedia('(max-width: 900px)');

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

  const groupModalEl = document.getElementById('cf-group-modal');
  const groupModalTitleEl = document.getElementById('cf-group-modal-title');
  const groupModalCloseEl = document.getElementById('cf-group-modal-close');
  const groupModalHintEl = document.getElementById('cf-group-modal-hint');
  const groupModalErrorEl = document.getElementById('cf-group-modal-error');
  const groupNameEl = document.getElementById('cf-group-name');
  const groupParentEl = document.getElementById('cf-group-parent');
  const groupSaveEl = document.getElementById('cf-group-save');
  const groupDeleteEl = document.getElementById('cf-group-delete');
  const groupFriendsSectionEl = document.getElementById('cf-group-friends-section');
  const groupFriendFilterEl = document.getElementById('cf-group-friend-filter');
  const groupFriendListEl = document.getElementById('cf-group-friend-list');
  const groupInviteEl = document.getElementById('cf-group-invite');

  const searchModalEl = document.getElementById('cf-search-modal');
  const searchModalCloseEl = document.getElementById('cf-search-modal-close');
  const searchInputEl = document.getElementById('cf-search-input');
  const searchGroupsEl = document.getElementById('cf-search-groups');
  const searchUsersEl = document.getElementById('cf-search-users');

  let modalEventId = null;
  let groupModalState = { formMode: 'create', groupId: null };
  let groupInviteCandidates = [];
  const sentFriendRequestUserIds = new Set();
  let searchDebounceTimer = null;
  let searchRequestSeq = 0;


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

  function isMobileLayout() {
    return !!(mobileLayoutMq && mobileLayoutMq.matches);
  }

  function syncMobileMenuState() {
    if (mobileMenuMembersEl) {
      mobileMenuMembersEl.textContent = (mode === 'group' && selectedGroupId) ? 'メンバー' : 'フレンド';
    }
  }

  function closeMobilePanels() {
    root.classList.remove('cf-mobile-left-open', 'cf-mobile-right-open', 'cf-mobile-menu-open');
    if (btnCreateGroup) btnCreateGroup.setAttribute('aria-expanded', 'false');
  }

  function openMobileLeftSidebar() {
    if (!isMobileLayout()) return;
    root.classList.remove('cf-mobile-right-open', 'cf-mobile-menu-open');
    root.classList.add('cf-mobile-left-open');
    if (btnCreateGroup) btnCreateGroup.setAttribute('aria-expanded', 'true');
  }

  function openMobileRightSidebar() {
    if (!isMobileLayout()) return;
    syncMobileMenuState();
    root.classList.remove('cf-mobile-left-open', 'cf-mobile-menu-open');
    root.classList.add('cf-mobile-right-open');
    if (btnCreateGroup) btnCreateGroup.setAttribute('aria-expanded', 'true');
  }

  function toggleMobileMenu() {
    if (!isMobileLayout()) return false;
    const nextOpen = !root.classList.contains('cf-mobile-menu-open');
    closeMobilePanels();
    if (nextOpen) {
      syncMobileMenuState();
      root.classList.add('cf-mobile-menu-open');
      if (btnCreateGroup) btnCreateGroup.setAttribute('aria-expanded', 'true');
    }
    return true;
  }

  function handleMobileLayoutChange() {
    syncMobileMenuState();
    if (!isMobileLayout()) {
      closeMobilePanels();
      collapseChatComposer(true);
      return;
    }

    const bar = document.querySelector('.cf-chatbar');
    if (bar && bar.classList.contains('expanded')) {
      root.classList.add('cf-mobile-chat-open');
    }
  }

  function expandChatComposer() {
    const bar = document.querySelector('.cf-chatbar');
    if (!bar) return;
    if (isMobileLayout()) {
      root.classList.add('cf-mobile-chat-open');
      bar.classList.add('expanded');
      return;
    }
    // Desktop keeps chat inline to avoid blocking the calendar.
    root.classList.remove('cf-mobile-chat-open');
    bar.classList.remove('expanded');
  }

  function collapseChatComposer(force = false) {
    const bar = document.querySelector('.cf-chatbar');
    if (!bar) return;
    if (!force && chatInputEl && chatInputEl.value.trim() !== '') return;
    root.classList.remove('cf-mobile-chat-open');
    bar.classList.remove('expanded');
  }

  async function loadShareRequests() {
    if (!shareRequestsEl) return;

    shareRequestsEl.innerHTML = '<div class="cf-muted">読み込み中...</div>';

    try {
      const [eventResult, friendResult] = await Promise.allSettled([
        apiFetch('/api/event_share_requests'),
        apiFetch('/api/friend_requests')
      ]);

      const eventRequests = eventResult.status === 'fulfilled' ? (eventResult.value.requests || []) : [];
      const friendRequests = friendResult.status === 'fulfilled' ? (friendResult.value.requests || []) : [];

      const eventHtml = eventRequests.length
        ? eventRequests.map((request) => `
          <div class="cf-share-request">
            <div class="cf-share-request-title">${escapeHtml(request.event_title || 'イベント')}</div>
            <div class="cf-share-request-meta">${escapeHtml(request.requested_by_name || '')} → ${escapeHtml(request.target_name || '')}</div>
            <div class="cf-share-request-actions">
              <button class="cf-btn small cf-share-approve" data-id="${request.id}">承認</button>
              <button class="cf-btn small cf-share-reject" data-id="${request.id}">却下</button>
            </div>
          </div>`).join('')
        : '<div class="cf-muted">リクエストはありません</div>';

      const friendHtml = friendRequests.length
        ? friendRequests.map((request) => `
          <div class="cf-share-request">
            <div class="cf-share-request-title">${escapeHtml(request.from_user_name || 'ユーザー')}</div>
            <div class="cf-share-request-meta">${escapeHtml(request.from_user_email || '')}</div>
            <div class="cf-share-request-actions">
              <button class="cf-btn small cf-friend-approve" data-id="${request.id}">承認</button>
              <button class="cf-btn small cf-friend-reject" data-id="${request.id}">却下</button>
            </div>
          </div>`).join('')
        : '<div class="cf-muted">リクエストはありません</div>';

      shareRequestsEl.innerHTML = `
        <div class="cf-share-title">共有リクエスト</div>
        ${eventHtml}
        <div class="cf-share-title" style="margin-top:12px;">フレンドリクエスト</div>
        ${friendHtml}
      `;

      shareRequestsEl.querySelectorAll('.cf-share-approve').forEach((btn) => {
        btn.addEventListener('click', async () => {
          try {
            await apiFetch(`/api/event_share_requests/${btn.dataset.id}`, { method: 'PATCH', body: { decision: 'approve' } });
            await loadShareRequests();
            if (calendar) calendar.refetchEvents();
          } catch (e) {
            alert(`承認失敗: ${e.message}`);
          }
        });
      });

      shareRequestsEl.querySelectorAll('.cf-share-reject').forEach((btn) => {
        btn.addEventListener('click', async () => {
          try {
            await apiFetch(`/api/event_share_requests/${btn.dataset.id}`, { method: 'PATCH', body: { decision: 'reject' } });
            await loadShareRequests();
          } catch (e) {
            alert(`却下失敗: ${e.message}`);
          }
        });
      });

      shareRequestsEl.querySelectorAll('.cf-friend-approve').forEach((btn) => {
        btn.addEventListener('click', async () => {
          try {
            await apiFetch(`/api/friend_requests/${btn.dataset.id}`, { method: 'PATCH', body: { decision: 'approve' } });
            await loadShareRequests();
            if (mode === 'home') await loadFriends();
            await refreshSearchResultsIfOpen();
          } catch (e) {
            alert(`承認失敗: ${e.message}`);
          }
        });
      });

      shareRequestsEl.querySelectorAll('.cf-friend-reject').forEach((btn) => {
        btn.addEventListener('click', async () => {
          try {
            await apiFetch(`/api/friend_requests/${btn.dataset.id}`, { method: 'PATCH', body: { decision: 'reject' } });
            await loadShareRequests();
            await refreshSearchResultsIfOpen();
          } catch (e) {
            alert(`却下失敗: ${e.message}`);
          }
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

  function normalizeSearchText(value) {
    return String(value || '').trim().toLowerCase();
  }

  function renderEmptyState(message) {
    return `<div class="cf-empty-state">${escapeHtml(message)}</div>`;
  }

  function setGroupModalError(message = '') {
    if (!groupModalErrorEl) return;
    groupModalErrorEl.textContent = message;
    groupModalErrorEl.classList.toggle('hidden', !message);
  }

  function openGroupModalShell() {
    if (groupModalEl) groupModalEl.classList.remove('hidden');
  }

  function closeGroupModal() {
    if (groupModalEl) groupModalEl.classList.add('hidden');
    groupModalState = { formMode: 'create', groupId: null };
    groupInviteCandidates = [];
    if (groupFriendFilterEl) groupFriendFilterEl.value = '';
    if (groupFriendListEl) groupFriendListEl.innerHTML = '';
    setGroupModalError('');
  }

  function populateGroupParentOptions({ targetGroup = null, defaultParentId = null } = {}) {
    if (!groupParentEl) return;

    groupParentEl.innerHTML = '';

    const rootOpt = document.createElement('option');
    rootOpt.value = '';
    rootOpt.textContent = '（ルート）';
    groupParentEl.appendChild(rootOpt);

    const excludeIds = targetGroup ? collectSubtreeIds(targetGroup.id) : new Set();
    const rows = flattenGroups(excludeIds);
    rows.forEach(({ group, depth }) => {
      const opt = document.createElement('option');
      opt.value = String(group.id);
      opt.textContent = `${'—'.repeat(depth)}${depth > 0 ? ' ' : ''}${group.name}`;
      groupParentEl.appendChild(opt);
    });

    const targetValue = defaultParentId == null ? '' : String(defaultParentId);
    const optionValues = Array.from(groupParentEl.options).map((opt) => opt.value);
    groupParentEl.value = optionValues.includes(targetValue) ? targetValue : '';
  }

  function renderGroupInviteCandidates() {
    if (!groupFriendListEl) return;

    const filter = normalizeSearchText(groupFriendFilterEl ? groupFriendFilterEl.value : '');
    const visible = groupInviteCandidates.filter((friend) => {
      const haystack = `${friend.name || ''} ${friend.email || ''}`.toLowerCase();
      return !filter || haystack.includes(filter);
    });

    if (!visible.length) {
      groupFriendListEl.innerHTML = renderEmptyState('招待できるフレンドはいません');
      return;
    }

    groupFriendListEl.innerHTML = visible.map((friend) => `
      <label class="cf-check-row">
        <input type="checkbox" class="cf-group-friend-check" value="${friend.id}">
        <span>${escapeHtml(friend.name || friend.email || `User#${friend.id}`)}</span>
        <small>${escapeHtml(friend.email || '')}</small>
      </label>`).join('');
  }

  async function loadGroupInviteCandidates(groupId) {
    if (!groupFriendListEl) return;

    groupFriendListEl.innerHTML = renderEmptyState('読み込み中...');
    groupInviteCandidates = [];

    try {
      const [friendsData, membersData] = await Promise.all([
        apiFetch('/api/friends'),
        apiFetch(`/api/groups/${groupId}/members`)
      ]);

      const friends = Array.isArray(friendsData) ? friendsData : (friendsData.friends || friendsData.users || []);
      const memberIds = new Set((membersData.members || []).map((member) => Number(member.user_id || member.id)));

      groupInviteCandidates = friends
        .map((friend) => ({
          id: Number(friend.id),
          name: friend.name || friend.email || `User#${friend.id}`,
          email: friend.email || ''
        }))
        .filter((friend) => friend.id > 0 && friend.id !== currentUserId && !memberIds.has(friend.id))
        .sort((a, b) => {
          const cmp = normalizeSearchText(a.name || a.email).localeCompare(normalizeSearchText(b.name || b.email), 'ja');
          return cmp || (Number(a.id) - Number(b.id));
        });

      renderGroupInviteCandidates();
    } catch (e) {
      console.error(e);
      groupFriendListEl.innerHTML = renderEmptyState(`フレンド一覧の取得に失敗: ${e.message}`);
    }
  }

  async function openGroupModal({ formMode = 'create', group = null, parentId = null } = {}) {
    closeMobilePanels();
    if (!groupModalEl) return;

    if (!groupsCache.length) {
      try {
        await loadGroups();
      } catch (e) {
        console.error(e);
      }
    }

    const isEdit = formMode === 'edit' && group;
    groupModalState = {
      formMode,
      groupId: isEdit ? Number(group.id) : null
    };

    if (groupModalTitleEl) groupModalTitleEl.textContent = isEdit ? 'グループ編集' : 'グループ作成';
    if (groupModalHintEl) {
      groupModalHintEl.textContent = isEdit
        ? '親変更 / 削除 / フレンド招待ができます。子孫グループは親にできません。'
        : '新しいグループを作成します。選択中のグループ配下にも作れます。';
    }

    if (groupNameEl) groupNameEl.value = isEdit ? (group.name || '') : '';

    const defaultParentId = isEdit
      ? group.parent_id
      : (parentId != null ? parentId : ((mode === 'group' && selectedGroupId) ? selectedGroupId : null));

    populateGroupParentOptions({ targetGroup: isEdit ? group : null, defaultParentId });
    setGroupModalError('');

    if (groupDeleteEl) groupDeleteEl.classList.toggle('hidden', !isEdit);
    if (groupFriendsSectionEl) groupFriendsSectionEl.classList.toggle('hidden', !isEdit);

    if (groupFriendFilterEl) groupFriendFilterEl.value = '';

    if (isEdit) {
      await loadGroupInviteCandidates(group.id);
    } else if (groupFriendListEl) {
      groupFriendListEl.innerHTML = '';
    }

    openGroupModalShell();
    setTimeout(() => {
      try {
        if (groupNameEl) groupNameEl.focus();
      } catch (e) {}
    }, 0);
  }

  async function saveGroupModal() {
    const name = groupNameEl ? groupNameEl.value.trim() : '';
    const parentId = groupParentEl && groupParentEl.value !== '' ? Number(groupParentEl.value) : null;
    const isEdit = groupModalState.formMode === 'edit' && groupModalState.groupId;

    if (!name) {
      setGroupModalError('グループ名を入力してください。');
      if (groupNameEl) groupNameEl.focus();
      return;
    }

    if (groupSaveEl) groupSaveEl.disabled = true;
    if (groupDeleteEl) groupDeleteEl.disabled = true;
    setGroupModalError('');

    try {
      let response;
      if (isEdit) {
        response = await apiFetch(`/api/groups/${groupModalState.groupId}`, {
          method: 'PATCH',
          body: { group: { name, parent_id: parentId } }
        });
      } else {
        response = await apiFetch('/api/groups', {
          method: 'POST',
          body: { group: { name, parent_id: parentId, position: 0 } }
        });
      }

      const responseGroupId = isEdit
        ? Number(groupModalState.groupId)
        : Number((response && response.group && response.group.id) || 0);

      closeGroupModal();
      await loadGroups();

      if (responseGroupId > 0) {
        await selectGroup(responseGroupId);
      } else if (mode === 'group' && selectedGroupId) {
        renderGroupTree();
      }
    } catch (e) {
      setGroupModalError(e.message || '保存に失敗しました。');
    } finally {
      if (groupSaveEl) groupSaveEl.disabled = false;
      if (groupDeleteEl) groupDeleteEl.disabled = false;
    }
  }

  async function deleteCurrentGroup() {
    if (!(groupModalState.formMode === 'edit' && groupModalState.groupId)) return;
    if (!confirm('このグループを削除しますか？')) return;

    if (groupSaveEl) groupSaveEl.disabled = true;
    if (groupDeleteEl) groupDeleteEl.disabled = true;
    setGroupModalError('');

    const targetGroupId = Number(groupModalState.groupId);

    try {
      await apiFetch(`/api/groups/${targetGroupId}`, { method: 'DELETE' });
      closeGroupModal();
      await loadGroups();
      if (Number(selectedGroupId) === targetGroupId) {
        await selectHome();
      } else {
        renderGroupTree();
      }
    } catch (e) {
      setGroupModalError(e.message || '削除に失敗しました。');
    } finally {
      if (groupSaveEl) groupSaveEl.disabled = false;
      if (groupDeleteEl) groupDeleteEl.disabled = false;
    }
  }

  async function inviteSelectedFriends() {
    if (!(groupModalState.formMode === 'edit' && groupModalState.groupId)) return;

    const friendIds = Array.from(document.querySelectorAll('.cf-group-friend-check:checked')).map((el) => Number(el.value)).filter((id) => id > 0);
    if (!friendIds.length) {
      setGroupModalError('招待するフレンドを選択してください。');
      return;
    }

    if (groupInviteEl) groupInviteEl.disabled = true;
    setGroupModalError('');

    try {
      const data = await apiFetch(`/api/groups/${groupModalState.groupId}/invite_friends`, {
        method: 'POST',
        body: { friend_ids: friendIds }
      });

      await loadGroupInviteCandidates(groupModalState.groupId);
      if (Number(selectedGroupId) === Number(groupModalState.groupId)) {
        await loadMembers(groupModalState.groupId);
      }

      alert(`${data.invited_count || 0}人を招待しました`);
    } catch (e) {
      setGroupModalError(e.message || 'フレンド招待に失敗しました。');
    } finally {
      if (groupInviteEl) groupInviteEl.disabled = false;
    }
  }

  function openSearchModal() {
    closeMobilePanels();
    if (!searchModalEl) return;
    searchModalEl.classList.remove('hidden');
    if (searchInputEl) searchInputEl.value = '';
    runSearchModalSearch().catch((e) => console.error(e));
    setTimeout(() => {
      try {
        if (searchInputEl) searchInputEl.focus();
      } catch (e) {}
    }, 0);
  }

  function closeSearchModal() {
    if (!searchModalEl) return;
    searchModalEl.classList.add('hidden');
    searchRequestSeq += 1;
    if (searchDebounceTimer) {
      clearTimeout(searchDebounceTimer);
      searchDebounceTimer = null;
    }
  }

  function renderSearchGroupResults(groups) {
    if (!searchGroupsEl) return;

    if (!groups.length) {
      searchGroupsEl.innerHTML = renderEmptyState('該当するグループはありません');
      return;
    }

    searchGroupsEl.innerHTML = groups.map((group) => `
      <div class="cf-search-row clickable cf-search-group-row" data-group-id="${group.id}">
        <div class="cf-search-row-main">
          <div class="cf-search-row-title">${escapeHtml(group.name)}</div>
          <div class="cf-search-row-meta">
            <span class="cf-tag">Group #${group.id}</span>
            ${group.parent_id == null ? '<span class="cf-tag">ルート</span>' : `<span class="cf-tag">親: ${group.parent_id}</span>`}
          </div>
        </div>
        <div class="cf-search-row-actions">
          ${mode === 'group' && Number(selectedGroupId) === Number(group.id) ? '<span class="cf-tag success">選択中</span>' : '<span class="cf-tag">開く</span>'}
        </div>
      </div>`).join('');

    searchGroupsEl.querySelectorAll('.cf-search-group-row').forEach((row) => {
      row.addEventListener('click', async () => {
        closeSearchModal();
        await selectGroup(Number(row.dataset.groupId));
      });
    });
  }

  async function sendFriendRequest(userId) {
    try {
      const data = await apiFetch('/api/friend_requests', {
        method: 'POST',
        body: { user_id: Number(userId) }
      });

      if (!(data.auto_accepted || data.already_friend)) {
        sentFriendRequestUserIds.add(Number(userId));
        alert('フレンドリクエストを送信しました');
      } else if (data.auto_accepted) {
        alert('相手からの申請を自動承認してフレンドになりました');
      }

      if (mode === 'home') await loadFriends();
      await loadShareRequests();
      await refreshSearchResultsIfOpen();
    } catch (e) {
      alert(`フレンドリクエスト送信に失敗: ${e.message}`);
    }
  }

  function renderSearchUserResults(users, query) {
    if (!searchUsersEl) return;

    if (!query) {
      searchUsersEl.innerHTML = renderEmptyState('ユーザー名またはメールを入力すると表示されます');
      return;
    }

    if (!users.length) {
      searchUsersEl.innerHTML = renderEmptyState('該当するユーザーはありません');
      return;
    }

    searchUsersEl.innerHTML = users.map((user) => {
      const userId = Number(user.id);
      const requestSent = !!user.pending_sent || sentFriendRequestUserIds.has(userId);
      const meta = [];
      if (user.email) meta.push(escapeHtml(user.email));
      if (Number(user.shared_group_count || 0) > 0) meta.push(`共通グループ ${Number(user.shared_group_count)}`);

      let actions = '';
      if (user.is_friend) {
        actions = `<button class="cf-btn small cf-search-dm" data-user-id="${userId}">DM</button>`;
      } else if (user.pending_received) {
        actions = '<span class="cf-tag pending">受信中</span>';
      } else if (requestSent) {
        actions = '<span class="cf-tag pending">送信済み</span>';
      } else {
        actions = `<button class="cf-btn small cf-search-request" data-user-id="${userId}">申請</button>`;
      }

      return `
        <div class="cf-search-row">
          <div class="cf-search-row-main">
            <div class="cf-search-row-title">${escapeHtml(user.name || user.email || `User#${userId}`)}</div>
            <div class="cf-search-row-meta">${meta.length ? meta.map((part) => `<span>${part}</span>`).join('') : '<span>ユーザー</span>'}</div>
          </div>
          <div class="cf-search-row-actions">${actions}</div>
        </div>`;
    }).join('');

    searchUsersEl.querySelectorAll('.cf-search-dm').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const row = btn.closest('.cf-search-row');
        const label = row ? (row.querySelector('.cf-search-row-title')?.textContent || '') : '';
        closeSearchModal();
        await startDirectChat(Number(btn.dataset.userId), label);
      });
    });

    searchUsersEl.querySelectorAll('.cf-search-request').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await sendFriendRequest(Number(btn.dataset.userId));
      });
    });
  }

  async function runSearchModalSearch() {
    if (!searchGroupsEl || !searchUsersEl) return;

    const query = searchInputEl ? searchInputEl.value.trim() : '';
    const seq = ++searchRequestSeq;

    searchGroupsEl.innerHTML = renderEmptyState('読み込み中...');
    searchUsersEl.innerHTML = query ? renderEmptyState('読み込み中...') : renderEmptyState('ユーザー名またはメールを入力すると表示されます');

    try {
      const [groupsData, usersData] = await Promise.all([
        apiFetch(query ? `/api/groups?q=${encodeURIComponent(query)}` : '/api/groups'),
        query ? apiFetch(`/api/users?q=${encodeURIComponent(query)}`) : Promise.resolve({ users: [] })
      ]);

      if (seq !== searchRequestSeq) return;

      renderSearchGroupResults(Array.isArray(groupsData) ? groupsData : (groupsData.groups || []));
      renderSearchUserResults(Array.isArray(usersData) ? usersData : (usersData.users || []), query);
    } catch (e) {
      if (seq !== searchRequestSeq) return;
      searchGroupsEl.innerHTML = renderEmptyState(`グループ検索に失敗: ${e.message}`);
      searchUsersEl.innerHTML = renderEmptyState(`ユーザー検索に失敗: ${e.message}`);
    }
  }

  async function refreshSearchResultsIfOpen() {
    if (!searchModalEl || searchModalEl.classList.contains('hidden')) return;
    await runSearchModalSearch();
  }

  if (groupModalEl) {
    groupModalEl.addEventListener('click', (e) => {
      if (e.target && e.target.dataset && e.target.dataset.closeGroup) closeGroupModal();
    });
  }
  if (groupModalCloseEl) groupModalCloseEl.addEventListener('click', closeGroupModal);
  if (groupSaveEl) groupSaveEl.addEventListener('click', saveGroupModal);
  if (groupDeleteEl) groupDeleteEl.addEventListener('click', deleteCurrentGroup);
  if (groupInviteEl) groupInviteEl.addEventListener('click', inviteSelectedFriends);
  if (groupFriendFilterEl) groupFriendFilterEl.addEventListener('input', renderGroupInviteCandidates);

  if (searchModalEl) {
    searchModalEl.addEventListener('click', (e) => {
      if (e.target && e.target.dataset && e.target.dataset.closeSearch) closeSearchModal();
    });
  }
  if (searchModalCloseEl) searchModalCloseEl.addEventListener('click', closeSearchModal);
  if (btnOpenSearch) btnOpenSearch.addEventListener('click', openSearchModal);
  if (searchInputEl) {
    searchInputEl.addEventListener('input', () => {
      if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
      searchDebounceTimer = setTimeout(() => {
        runSearchModalSearch().catch((e) => console.error(e));
      }, 180);
    });
  }

  if (mobileOverlayEl) {
    mobileOverlayEl.addEventListener('click', closeMobilePanels);
  }
  if (mobileMenuHomeEl) {
    mobileMenuHomeEl.addEventListener('click', async () => {
      closeMobilePanels();
      await selectHome();
    });
  }
  if (mobileMenuGroupsEl) {
    mobileMenuGroupsEl.addEventListener('click', () => {
      openMobileLeftSidebar();
    });
  }
  if (mobileMenuMembersEl) {
    mobileMenuMembersEl.addEventListener('click', () => {
      openMobileRightSidebar();
    });
  }
  if (mobileMenuCreateEl) {
    mobileMenuCreateEl.addEventListener('click', async () => {
      closeMobilePanels();
      const parentId = (mode === 'group' && selectedGroupId) ? selectedGroupId : null;
      await openGroupModal({ formMode: 'create', parentId });
    });
  }
  if (mobileMenuSearchEl) {
    mobileMenuSearchEl.addEventListener('click', () => {
      closeMobilePanels();
      openSearchModal();
    });
  }

  if (mobileLayoutMq) {
    if (typeof mobileLayoutMq.addEventListener === 'function') {
      mobileLayoutMq.addEventListener('change', handleMobileLayoutChange);
    } else if (typeof mobileLayoutMq.addListener === 'function') {
      mobileLayoutMq.addListener(handleMobileLayoutChange);
    }
  }

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') closeMobilePanels();
  });

  ensureColorPalette();
  syncMobileMenuState();
  handleMobileLayoutChange();

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

  function collectSubtreeIds(rootId) {
    const map = buildChildrenMap(groupsCache);
    const out = new Set([Number(rootId)]);
    const stack = [String(rootId)];

    while (stack.length) {
      const key = stack.pop();
      const children = map.get(key) || [];
      children.forEach((child) => {
        const childId = Number(child.id);
        if (out.has(childId)) return;
        out.add(childId);
        stack.push(String(child.id));
      });
    }

    return out;
  }

  function flattenGroups(excludeIds = new Set()) {
    const childrenMap = buildChildrenMap(groupsCache);
    const rows = [];
    const seenGroupIds = new Set();
    const stack = [{ parentKey: 'root', depth: 0 }];

    while (stack.length) {
      const { parentKey, depth } = stack.pop();
      const children = (childrenMap.get(parentKey) || []).slice().reverse();

      children.forEach((group) => {
        const groupId = Number(group.id);
        if (seenGroupIds.has(groupId)) return;

        seenGroupIds.add(groupId);
        if (!excludeIds.has(groupId)) {
          rows.push({ group, depth });
        }

        stack.push({ parentKey: String(group.id), depth: depth + 1 });
      });
    }

    groupsCache.forEach((group) => {
      const groupId = Number(group.id);
      if (seenGroupIds.has(groupId)) return;
      if (!excludeIds.has(groupId)) rows.push({ group, depth: 0 });
    });

    return rows;
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
    const renderedIds = new Set();

    function appendNode(g, depth) {
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

      const actions = document.createElement('span');
      actions.className = 'cf-tree-actions';

      const addBtn = document.createElement('button');
      addBtn.type = 'button';
      addBtn.className = 'cf-tree-action';
      addBtn.title = '子グループを追加';
      addBtn.textContent = '+';
      addBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await openGroupModal({ formMode: 'create', parentId: gid });
      });

      const editBtn = document.createElement('button');
      editBtn.type = 'button';
      editBtn.className = 'cf-tree-action';
      editBtn.title = 'グループ編集';
      editBtn.textContent = '✎';
      editBtn.addEventListener('click', async (e) => {
        e.stopPropagation();
        await openGroupModal({ formMode: 'edit', group: g });
      });

      actions.appendChild(addBtn);
      actions.appendChild(editBtn);

      li.appendChild(indent);
      li.appendChild(toggle);
      li.appendChild(name);
      li.appendChild(actions);

      li.addEventListener('click', () => selectGroup(gid));
      groupTreeEl.appendChild(li);

      if (hasChildren && !isCollapsed) {
        renderNodes(childKey, depth + 1);
      }
    }

    function renderNodes(parentKey, depth) {
      const nodes = childrenMap.get(parentKey) || [];

      nodes.forEach((g) => {
        const gid = Number(g.id);
        if (renderedIds.has(gid)) return;
        renderedIds.add(gid);
        appendNode(g, depth);
      });
    }

    renderNodes('root', 0);

    groupsCache.forEach((g) => {
      const gid = Number(g.id);
      if (renderedIds.has(gid)) return;
      renderedIds.add(gid);
      appendNode(g, 0);
    });
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
    closeMobilePanels();
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
    closeMobilePanels();
    mode = 'home';
    selectedGroupId = null;
    groupOwnerId = null;

    if (selectedGroupLabelEl) selectedGroupLabelEl.textContent = '個人';
    if (rightTitleEl) rightTitleEl.textContent = 'フレンド';

    renderGroupTree();
    await loadFriends();
    await loadShareRequests();
    setChatContext({ type: 'none' });

    if (calendar) calendar.refetchEvents();
  }

  if (chatInputEl) {
    chatInputEl.addEventListener('focus', () => expandChatComposer());
    chatInputEl.addEventListener('click', () => expandChatComposer());
  }

  function maybeCollapseExpandedChat(e) {
    const bar = document.querySelector('.cf-chatbar');
    if (!bar || !bar.classList.contains('expanded')) return;
    if (bar.contains(e.target)) return;
    collapseChatComposer(true);
  }

  document.addEventListener('mousedown', maybeCollapseExpandedChat);
  document.addEventListener('touchstart', maybeCollapseExpandedChat, { passive: true });

  if (btnModeHome) {
    btnModeHome.addEventListener('click', () => { closeMobilePanels(); selectHome(); });
  }

  if (btnCreateGroup && !btnCreateGroup.dataset.cfBound) {
    btnCreateGroup.dataset.cfBound = '1';
    btnCreateGroup.addEventListener('click', async () => {
      if (toggleMobileMenu()) return;
      const parentId = (mode === 'group' && selectedGroupId) ? selectedGroupId : null;
      await openGroupModal({ formMode: 'create', parentId });
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
    closeMobilePanels();
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
    const mobile = isMobileLayout();
    calendar = new window.FullCalendar.Calendar(calendarEl, {
      initialView: 'dayGridMonth',
      height: '100%',
      fixedWeekCount: !mobile,
      expandRows: true,
      dayMaxEventRows: mobile ? 1 : 2,
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
          fixedWeekCount: !mobile,
          dayMaxEventRows: mobile ? 1 : 2,
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
    const root = document.querySelector('.cf-root[data-page="home"]');
    const chatbar = document.querySelector('.cf-chatbar');
    const linkBtn = document.getElementById('cf-ev-add-link');
    const mobile = window.matchMedia('(max-width: 900px)').matches;

    if (chatbar) {
      if (!mobile) {
        chatbar.classList.remove('expanded');
      }
      if (root && !mobile) {
        root.classList.remove('cf-mobile-chat-open');
      }
      chatbar.dataset.cfExpandPatchBound = '1';
    }

    if (linkBtn) {
      linkBtn.style.display = 'none';
    }
  }

  document.addEventListener('DOMContentLoaded', bootChatExpandPatch);
  document.addEventListener('turbo:load', bootChatExpandPatch);
})();
/* === END CF_CHAT_EXPAND_HIDE_LINK_PATCH === */
