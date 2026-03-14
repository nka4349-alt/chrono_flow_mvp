// ChronoFlow front-end (no framework)
// - Calendar: FullCalendar
// - Groups: VSCode-like tree (collapse) + create/edit modal with parent selection
// - Chat: bottom bar switches between Group / Event / Direct(User) contexts
// - Home sidebar: show Friends (right)
// - Day view: timeGridDay (vertical timeline) with non-overlap

(() => {
  // ---------- DOM helpers ----------
  const $ = (id) => document.getElementById(id);
  const q = (sel, root = document) => root.querySelector(sel);
  const qa = (sel, root = document) => Array.from(root.querySelectorAll(sel));

  const safeText = (s) => (s == null ? "" : String(s));

  // ---------- API ----------
  async function apiFetch(path, options = {}) {
    const opts = {
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        ...(options.body ? { "Content-Type": "application/json" } : {}),
        ...(options.headers || {}),
      },
      ...options,
    };

    const res = await fetch(path, opts);
    if (!res.ok) {
      let detail = "";
      try {
        const txt = await res.text();
        detail = txt ? `\n${txt}` : "";
      } catch (_) {}
      const err = new Error(`HTTP ${res.status}${detail}`);
      err.status = res.status;
      throw err;
    }
    const ct = res.headers.get("content-type") || "";
    if (ct.includes("application/json")) return res.json();
    return res.text();
  }

  // ---------- State ----------
  const state = {
    mode: "home", // 'home' | 'group'
    groupId: null,
    groups: [],
    collapsed: new Set(),
    calendar: null,
    chatContext: { type: "none", id: null, label: "" }, // group|event|direct|none
    chatPollTimer: null,
    lastChatKey: null,
    // event modal
    modalEventId: null,
    prevChatContext: null,
  };

  // ---------- Elements ----------
  const el = {
    groupTree: $("cf-group-tree"),
    addGroupBtn: $("cf-add-group"),
    homeBtn: $("cf-home-cal"),
    selectedGroup: $("cf-selected-group"),
    members: $("cf-members"),
    chatLog: $("cf-chat-log"),
    chatForm: $("cf-chat-form"),
    chatInput: $("cf-chat-input"),
    chatScope: $("cf-chat-scope"),
    prevBtn: $("cf-prev"),
    nextBtn: $("cf-next"),
    todayBtn: $("cf-today"),
    calendar: $("calendar"),
    // event modal
    modal: $("cf-modal"),
    modalTitle: $("cf-modal-title"),
    evTitle: $("cf-ev-title"),
    evStart: $("cf-ev-start"),
    evEnd: $("cf-ev-end"),
    evAllDay: $("cf-ev-all-day"),
    evType: $("cf-ev-type"),
    evDesc: $("cf-ev-desc"),
    evSave: $("cf-ev-save"),
    evDelete: $("cf-ev-delete"),
    evShare: $("cf-ev-share"),
    evAddMy: $("cf-ev-add-my"),
    evClose: $("cf-ev-close"),
  };

  // Some layouts may not include some elements (defensive)
  if (!el.calendar) return;

  // ---------- Group tree collapse ----------
  const LS_COLLAPSED = "cf_collapsed_group_ids";
  function loadCollapsedFromStorage() {
    try {
      const raw = localStorage.getItem(LS_COLLAPSED);
      if (!raw) return;
      const arr = JSON.parse(raw);
      if (Array.isArray(arr)) state.collapsed = new Set(arr.map((n) => Number(n)).filter((n) => Number.isFinite(n)));
    } catch (_) {}
  }
  function saveCollapsedToStorage() {
    try {
      localStorage.setItem(LS_COLLAPSED, JSON.stringify(Array.from(state.collapsed)));
    } catch (_) {}
  }
  function toggleCollapsed(groupId) {
    if (state.collapsed.has(groupId)) state.collapsed.delete(groupId);
    else state.collapsed.add(groupId);
    saveCollapsedToStorage();
  }

  // ---------- Group modal (create/edit) ----------
  function ensureGroupModal() {
    if ($("cf-group-modal")) return;

    const wrap = document.createElement("div");
    wrap.id = "cf-group-modal";
    wrap.innerHTML = `
      <div class="cf-gm-overlay" data-cf-gm-close="1"></div>
      <div class="cf-gm-dialog" role="dialog" aria-modal="true" aria-labelledby="cf-gm-title">
        <div class="cf-gm-header">
          <div id="cf-gm-title" class="cf-gm-title">グループ</div>
          <button type="button" class="cf-gm-x" data-cf-gm-close="1" aria-label="閉じる">×</button>
        </div>
        <div class="cf-gm-body">
          <label class="cf-gm-label">名前</label>
          <input id="cf-gm-name" class="cf-gm-input" type="text" maxlength="120" placeholder="例: プロジェクトA" />

          <label class="cf-gm-label">親グループ</label>
          <select id="cf-gm-parent" class="cf-gm-input"></select>

          <div id="cf-gm-error" class="cf-gm-error" style="display:none"></div>
        </div>
        <div class="cf-gm-footer">
          <button type="button" class="cf-btn" data-cf-gm-close="1">キャンセル</button>
          <button type="button" class="cf-btn-primary" id="cf-gm-save">保存</button>
        </div>
      </div>
    `;
    document.body.appendChild(wrap);

    wrap.addEventListener("click", (e) => {
      const t = e.target;
      if (t && t.getAttribute("data-cf-gm-close") === "1") {
        closeGroupModal();
      }
    });
  }

  function openGroupModal(mode, group = null) {
    ensureGroupModal();
    const modal = $("cf-group-modal");
    const title = $("cf-gm-title");
    const nameEl = $("cf-gm-name");
    const parentEl = $("cf-gm-parent");
    const errEl = $("cf-gm-error");

    modal.dataset.mode = mode;
    modal.dataset.groupId = group ? String(group.id) : "";
    title.textContent = mode === "edit" ? "グループ編集" : "新規グループ";
    nameEl.value = group ? safeText(group.name) : "";

    // Parent options
    parentEl.innerHTML = "";
    const optRoot = document.createElement("option");
    optRoot.value = "";
    optRoot.textContent = "(なし)";
    parentEl.appendChild(optRoot);

    state.groups.forEach((g) => {
      // cannot set self as parent
      if (group && g.id === group.id) return;
      const opt = document.createElement("option");
      opt.value = String(g.id);
      opt.textContent = g.name;
      parentEl.appendChild(opt);
    });

    parentEl.value = group && group.parent_id ? String(group.parent_id) : "";

    errEl.style.display = "none";
    errEl.textContent = "";

    modal.classList.add("is-open");
    setTimeout(() => nameEl.focus(), 0);

    $("cf-gm-save").onclick = async () => {
      errEl.style.display = "none";
      errEl.textContent = "";
      const payload = {
        group: {
          name: nameEl.value.trim(),
          parent_id: parentEl.value || null,
        },
      };

      if (!payload.group.name) {
        errEl.textContent = "名前を入力してください";
        errEl.style.display = "block";
        return;
      }

      try {
        if (mode === "edit" && group) {
          await apiFetch(`/api/groups/${group.id}`, { method: "PATCH", body: JSON.stringify(payload) });
        } else {
          await apiFetch(`/api/groups`, { method: "POST", body: JSON.stringify(payload) });
        }
        await loadGroups();
        closeGroupModal();
      } catch (e) {
        errEl.textContent = `保存に失敗しました (${e.message})`;
        errEl.style.display = "block";
      }
    };
  }

  function closeGroupModal() {
    const modal = $("cf-group-modal");
    if (!modal) return;
    modal.classList.remove("is-open");
  }

  // ---------- Groups ----------
  async function loadGroups() {
    const groups = await apiFetch("/api/groups");
    // API may return {groups:[...]} or plain array
    state.groups = Array.isArray(groups) ? groups : (groups.groups || []);
    renderGroupTree();
  }

  function renderGroupTree() {
    if (!el.groupTree) return;
    el.groupTree.innerHTML = "";

    const byParent = new Map();
    const groups = state.groups.slice();
    groups.forEach((g) => {
      const pid = g.parent_id ? Number(g.parent_id) : 0;
      if (!byParent.has(pid)) byParent.set(pid, []);
      byParent.get(pid).push(g);
    });
    byParent.forEach((arr) => {
      arr.sort((a, b) => {
        const pa = a.position ?? 0;
        const pb = b.position ?? 0;
        if (pa !== pb) return pa - pb;
        return (a.id ?? 0) - (b.id ?? 0);
      });
    });

    const frag = document.createDocumentFragment();

    function walk(parentId, depth) {
      const kids = byParent.get(parentId) || [];
      kids.forEach((g) => {
        const hasKids = (byParent.get(g.id) || []).length > 0;
        const collapsed = state.collapsed.has(g.id);

        const row = document.createElement("div");
        row.className = "cf-group-row";
        row.dataset.groupId = String(g.id);
        row.style.paddingLeft = `${8 + depth * 14}px`;
        if (state.mode === "group" && state.groupId === g.id) row.classList.add("is-active");

        const toggle = document.createElement("span");
        toggle.className = "cf-group-toggle";
        toggle.textContent = hasKids ? (collapsed ? "▶" : "▼") : "";
        toggle.title = hasKids ? (collapsed ? "展開" : "折り畳み") : "";
        toggle.addEventListener("click", (e) => {
          e.stopPropagation();
          if (!hasKids) return;
          toggleCollapsed(g.id);
          renderGroupTree();
        });

        const name = document.createElement("span");
        name.className = "cf-group-name";
        name.textContent = safeText(g.name);

        const edit = document.createElement("button");
        edit.type = "button";
        edit.className = "cf-group-edit";
        edit.textContent = "⋯";
        edit.title = "編集";
        edit.addEventListener("click", (e) => {
          e.stopPropagation();
          openGroupModal("edit", g);
        });

        row.appendChild(toggle);
        row.appendChild(name);
        row.appendChild(edit);

        row.addEventListener("click", () => selectGroup(g.id));

        frag.appendChild(row);

        if (hasKids && !collapsed) {
          walk(g.id, depth + 1);
        }
      });
    }

    walk(0, 0);
    el.groupTree.appendChild(frag);
  }

  function setModeHome() {
    state.mode = "home";
    state.groupId = null;
    if (el.selectedGroup) el.selectedGroup.textContent = "個人";
    renderGroupTree();
    renderFriendsSidebar();
    setChatContext({ type: "none", id: null, label: "" });
    state.calendar.refetchEvents();
  }

  function selectGroup(groupId) {
    state.mode = "group";
    state.groupId = Number(groupId);
    const g = state.groups.find((x) => Number(x.id) === state.groupId);
    if (el.selectedGroup) el.selectedGroup.textContent = g ? g.name : `グループ #${groupId}`;
    renderGroupTree();
    loadMembersSidebar();
    setChatContext({ type: "group", id: state.groupId, label: g ? g.name : "" });
    state.calendar.refetchEvents();
  }

  // ---------- Sidebar: Members / Friends ----------
  async function loadMembersSidebar() {
    if (!state.groupId || !el.members) return;
    try {
      const res = await apiFetch(`/api/groups/${state.groupId}/members`);
      const canManage = !!res.can_manage_roles;
      const ownerId = res.owner_user_id;
      const members = res.members || [];
      renderPeopleList({
        title: "メンバー",
        people: members.map((m) => ({
          id: m.id,
          name: m.name,
          role: m.role,
          isOwner: m.id === ownerId || m.is_owner,
        })),
        showRole: canManage,
        onRoleChange: async (userId, role) => {
          await apiFetch(`/api/groups/${state.groupId}/members/${userId}/role`, {
            method: "PATCH",
            body: JSON.stringify({ role }),
          });
          await loadMembersSidebar();
        },
      });
    } catch (e) {
      el.members.innerHTML = `<div class="cf-muted">メンバー取得に失敗 (${safeText(e.message)})</div>`;
    }
  }

  async function renderFriendsSidebar() {
    if (!el.members) return;
    try {
      const res = await apiFetch("/api/friends");
      const friends = res.friends || [];
      renderPeopleList({
        title: "フレンド",
        people: friends.map((f) => ({ id: f.id, name: f.name })),
        showRole: false,
      });
    } catch (e) {
      el.members.innerHTML = `<div class="cf-muted">フレンド取得に失敗 (${safeText(e.message)})</div>`;
    }
  }

  function renderPeopleList({ title, people, showRole, onRoleChange }) {
    // update sidebar header if present
    const rightTitle = q(".cf-sidebar-right h2");
    if (rightTitle) rightTitle.textContent = title;

    el.members.innerHTML = "";
    if (!people.length) {
      el.members.innerHTML = `<div class="cf-muted">未選択</div>`;
      return;
    }
    const frag = document.createDocumentFragment();

    people.forEach((p) => {
      const row = document.createElement("div");
      row.className = "cf-person-row";

      const left = document.createElement("div");
      left.className = "cf-person-left";
      const name = document.createElement("div");
      name.className = "cf-person-name";
      name.textContent = safeText(p.name);
      const sub = document.createElement("div");
      sub.className = "cf-person-sub";
      sub.textContent = p.isOwner ? "owner" : (p.role ? safeText(p.role) : "");
      left.appendChild(name);
      left.appendChild(sub);

      const right = document.createElement("div");
      right.className = "cf-person-right";

      const chatBtn = document.createElement("button");
      chatBtn.type = "button";
      chatBtn.className = "cf-person-chat";
      chatBtn.textContent = "💬";
      chatBtn.title = "チャット";
      chatBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        setChatContext({ type: "direct", id: p.id, label: p.name });
      });
      right.appendChild(chatBtn);

      if (showRole) {
        const sel = document.createElement("select");
        sel.className = "cf-role-select";
        ["owner", "admin", "member"].forEach((r) => {
          const opt = document.createElement("option");
          opt.value = r;
          opt.textContent = r;
          sel.appendChild(opt);
        });
        sel.value = p.isOwner ? "owner" : (p.role || "member");
        sel.disabled = !!p.isOwner;
        sel.addEventListener("change", async (e) => {
          if (!onRoleChange) return;
          try {
            await onRoleChange(p.id, e.target.value);
          } catch (err) {
            alert(`権限変更に失敗: ${err.message}`);
            await loadMembersSidebar();
          }
        });
        right.appendChild(sel);
      }

      row.appendChild(left);
      row.appendChild(right);
      frag.appendChild(row);
    });

    el.members.appendChild(frag);
  }

  // ---------- Chat ----------
  function chatKey(ctx) {
    if (!ctx || !ctx.type) return "none";
    return `${ctx.type}:${ctx.id || ""}`;
  }

  function setChatContext(ctx) {
    state.chatContext = ctx;
    const label = ctx.type === "group" ? `グループ: ${ctx.label || ctx.id}`
      : ctx.type === "event" ? `イベント: ${ctx.label || ctx.id}`
        : ctx.type === "direct" ? `DM: ${ctx.label || ctx.id}`
          : "(未選択)";

    if (el.chatScope) el.chatScope.textContent = label;
    loadChatMessages();
  }

  function chatEndpoint(ctx) {
    if (!ctx) return null;
    if (ctx.type === "group") return `/api/groups/${ctx.id}/chat_messages`;
    if (ctx.type === "event") return `/api/events/${ctx.id}/chat_messages`;
    if (ctx.type === "direct") return `/api/users/${ctx.id}/chat_messages`;
    return null;
  }

  async function loadChatMessages() {
    const ctx = state.chatContext;
    const key = chatKey(ctx);
    state.lastChatKey = key;

    const endpoint = chatEndpoint(ctx);
    if (!endpoint) {
      if (el.chatLog) el.chatLog.innerHTML = "";
      return;
    }
    try {
      const res = await apiFetch(`${endpoint}?limit=80`);
      // Prevent race when context changed
      if (state.lastChatKey !== key) return;

      const messages = res.messages || [];
      renderChat(messages);
    } catch (e) {
      if (el.chatLog) el.chatLog.innerHTML = `<div class="cf-muted">チャット取得に失敗 (${safeText(e.message)})</div>`;
    }
  }

  function renderChat(messages) {
    if (!el.chatLog) return;
    el.chatLog.innerHTML = "";
    const frag = document.createDocumentFragment();
    messages.forEach((m) => {
      const div = document.createElement("div");
      div.className = "cf-chat-msg";
      const ts = (m.created_at || "").replace("T", " ").replace(/:..\..+$/, "");
      div.textContent = `${m.user?.name || ""} ${ts} : ${m.body || ""}`;
      frag.appendChild(div);
    });
    el.chatLog.appendChild(frag);
    el.chatLog.scrollTop = el.chatLog.scrollHeight;
  }

  function startChatPolling() {
    if (state.chatPollTimer) clearInterval(state.chatPollTimer);
    state.chatPollTimer = setInterval(() => {
      // Only poll if context is active
      if (state.chatContext.type !== "none") loadChatMessages();
    }, 5000);
  }

  async function sendChatMessage(body) {
    const ctx = state.chatContext;
    const endpoint = chatEndpoint(ctx);
    if (!endpoint) return;
    await apiFetch(endpoint, {
      method: "POST",
      body: JSON.stringify({ body }),
    });
    await loadChatMessages();
  }

  // ---------- Calendar ----------
  function initCalendar() {
    const calendar = new FullCalendar.Calendar(el.calendar, {
      initialView: "dayGridMonth",
      headerToolbar: false,
      height: "100%",
      nowIndicator: true,
      selectable: true,
      dayMaxEvents: true,
      eventDisplay: "block",

      // Day view: vertical timeline, non-overlap
      slotEventOverlap: false,
      eventOverlap: false,
      slotMinTime: "05:00:00",
      slotMaxTime: "24:00:00",

      views: {
        dayGridMonth: { buttonText: "month" },
        dayGridWeek: { buttonText: "week" },
        timeGridDay: { buttonText: "day" },
      },

      // Two sources: home + (optional) group
      eventSources: [
        {
          id: "home",
          events: async (info, success, failure) => {
            try {
              const url = `/api/events?start=${encodeURIComponent(info.startStr)}&end=${encodeURIComponent(info.endStr)}&scope=home`;
              const data = await apiFetch(url);
              success(data);
            } catch (e) {
              failure(e);
            }
          },
        },
        {
          id: "group",
          events: async (info, success, failure) => {
            if (state.mode !== "group" || !state.groupId) {
              success([]);
              return;
            }
            try {
              const url = `/api/groups/${state.groupId}/events?start=${encodeURIComponent(info.startStr)}&end=${encodeURIComponent(info.endStr)}`;
              const data = await apiFetch(url);
              success(data);
            } catch (e) {
              failure(e);
            }
          },
        },
      ],

      dateClick: (info) => {
        const start = info.date;
        const end = new Date(start.getTime() + 60 * 60 * 1000);
        openEventModal({
          mode: "create",
          eventId: null,
          title: "",
          start,
          end,
          allDay: info.allDay,
          eventTypeId: "",
          description: "",
        });
      },

      eventClick: (info) => {
        const ev = info.event;
        // Open edit modal
        openEventModal({
          mode: "edit",
          eventId: ev.id,
          title: ev.title,
          start: ev.start,
          end: ev.end,
          allDay: ev.allDay,
          eventTypeId: ev.extendedProps?.event_type_id || "",
          description: ev.extendedProps?.description || "",
        });

        // Switch chat to this event
        state.prevChatContext = state.chatContext;
        setChatContext({ type: "event", id: ev.id, label: ev.title });
      },
    });

    calendar.render();
    state.calendar = calendar;
  }

  // ---------- Event modal ----------
  function isoLocal(dt) {
    if (!dt) return "";
    // to yyyy-MM-ddTHH:mm (local)
    const pad = (n) => String(n).padStart(2, "0");
    const y = dt.getFullYear();
    const m = pad(dt.getMonth() + 1);
    const d = pad(dt.getDate());
    const hh = pad(dt.getHours());
    const mm = pad(dt.getMinutes());
    return `${y}-${m}-${d}T${hh}:${mm}`;
  }

  function openEventModal({ mode, eventId, title, start, end, allDay, eventTypeId, description }) {
    if (!el.modal) return;
    state.modalEventId = eventId;

    el.modalTitle.textContent = mode === "edit" ? "イベント編集" : "イベント作成";
    el.evTitle.value = safeText(title);
    el.evStart.value = isoLocal(start);
    el.evEnd.value = isoLocal(end || start);
    el.evAllDay.checked = !!allDay;
    if (el.evType) el.evType.value = safeText(eventTypeId);
    if (el.evDesc) el.evDesc.value = safeText(description);

    if (el.evDelete) el.evDelete.style.display = mode === "edit" ? "inline-block" : "none";
    if (el.evShare) el.evShare.style.display = mode === "edit" ? "inline-block" : "none";
    if (el.evAddMy) el.evAddMy.style.display = mode === "edit" ? "inline-block" : "none";

    el.modal.classList.add("is-open");
  }

  function closeEventModal() {
    if (!el.modal) return;
    el.modal.classList.remove("is-open");
    state.modalEventId = null;

    // Restore previous chat context if we switched to event
    if (state.prevChatContext) {
      setChatContext(state.prevChatContext);
      state.prevChatContext = null;
    }
  }

  async function saveEventFromModal() {
    const payload = {
      event: {
        title: el.evTitle.value.trim(),
        start_at: el.evStart.value,
        end_at: el.evEnd.value,
        all_day: el.evAllDay.checked,
        event_type_id: el.evType ? el.evType.value : null,
        description: el.evDesc ? el.evDesc.value : null,
        group_ids: state.mode === "group" && state.groupId ? [state.groupId] : [],
      },
    };

    if (!payload.event.title) {
      alert("タイトルを入力してください");
      return;
    }

    try {
      if (state.modalEventId) {
        await apiFetch(`/api/events/${state.modalEventId}`, { method: "PATCH", body: JSON.stringify(payload) });
      } else {
        await apiFetch(`/api/events`, { method: "POST", body: JSON.stringify(payload) });
      }
      closeEventModal();
      state.calendar.refetchEvents();
    } catch (e) {
      alert(`保存に失敗: ${e.message}`);
    }
  }

  async function deleteEventFromModal() {
    if (!state.modalEventId) return;
    if (!confirm("削除しますか？")) return;
    try {
      await apiFetch(`/api/events/${state.modalEventId}`, { method: "DELETE" });
      closeEventModal();
      state.calendar.refetchEvents();
    } catch (e) {
      alert(`削除に失敗: ${e.message}`);
    }
  }

  async function shareEventFromModal() {
    if (!state.modalEventId) return;
    const raw = prompt("共有したいグループIDをカンマ区切りで入力 (例: 1,2)");
    if (!raw) return;
    const ids = raw.split(",").map((s) => parseInt(s.trim(), 10)).filter((n) => Number.isFinite(n));
    if (!ids.length) return;
    try {
      await apiFetch(`/api/events/${state.modalEventId}/share_to_groups`, { method: "POST", body: JSON.stringify({ group_ids: ids }) });
      alert("共有しました");
      state.calendar.refetchEvents();
    } catch (e) {
      alert(`共有に失敗: ${e.message}`);
    }
  }

  async function addToMyCalendarFromModal() {
    if (!state.modalEventId) return;
    try {
      await apiFetch(`/api/events/${state.modalEventId}/add_to_my_calendar`, { method: "POST" });
      alert("個人カレンダーに追加しました");
      state.calendar.refetchEvents();
    } catch (e) {
      alert(`追加に失敗: ${e.message}`);
    }
  }

  // ---------- Wire events ----------
  function wire() {
    loadCollapsedFromStorage();

    if (el.addGroupBtn) {
      el.addGroupBtn.addEventListener("click", () => openGroupModal("create"));
    }
    if (el.homeBtn) {
      el.homeBtn.addEventListener("click", () => setModeHome());
    }
    if (el.prevBtn) el.prevBtn.addEventListener("click", () => state.calendar.prev());
    if (el.nextBtn) el.nextBtn.addEventListener("click", () => state.calendar.next());
    if (el.todayBtn) el.todayBtn.addEventListener("click", () => state.calendar.today());

    if (el.chatForm) {
      el.chatForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const body = el.chatInput.value.trim();
        if (!body) return;
        el.chatInput.value = "";
        try {
          await sendChatMessage(body);
        } catch (err) {
          alert(`送信に失敗: ${err.message}`);
        }
      });
    }

    // Event modal buttons
    if (el.evClose) el.evClose.addEventListener("click", closeEventModal);
    if (el.evSave) el.evSave.addEventListener("click", saveEventFromModal);
    if (el.evDelete) el.evDelete.addEventListener("click", deleteEventFromModal);
    if (el.evShare) el.evShare.addEventListener("click", shareEventFromModal);
    if (el.evAddMy) el.evAddMy.addEventListener("click", addToMyCalendarFromModal);

    // Close modal on overlay click (if markup supports)
    if (el.modal) {
      el.modal.addEventListener("click", (e) => {
        const t = e.target;
        if (t && t.classList && t.classList.contains("cf-modal-overlay")) {
          closeEventModal();
        }
      });
    }
  }

  // ---------- Boot ----------
  document.addEventListener("DOMContentLoaded", async () => {
    try {
      wire();
      initCalendar();
      await loadGroups();
      // default: home mode -> friends sidebar
      if (el.selectedGroup) el.selectedGroup.textContent = "個人";
      await renderFriendsSidebar();
      startChatPolling();
    } catch (e) {
      console.error(e);
      alert(`初期化に失敗: ${e.message}`);
    }
  });
})();
