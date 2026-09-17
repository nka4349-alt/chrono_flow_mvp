import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

process.env.TZ = 'Asia/Tokyo';
const source = readFileSync(new URL('../../app/javascript/application.js', import.meta.url), 'utf8');

function element() {
  return { innerHTML: '', dataset: {}, children: [], appendChild(child) { this.children.push(child); } };
}

function html(node) {
  return node.innerHTML + node.children.map(html).join('');
}

function chatView() {
  const output = element();
  const context = vm.createContext({
    document: { addEventListener() {}, createElement: element },
    chatMessagesEl: output,
    scrollChatToLatest() {},
    chatInputEl: { value: '' },
    chatSubmitBtnEl: {},
    chatSendInProgress: false,
    activeChatTab: 'ai',
    aiTabAvailable: () => true
  });
  // Load the real view functions without booting the unrelated calendar UI.
  vm.runInContext(source.replace(/^import .*\n/gm, ''), context);
  vm.runInContext(source.slice(source.indexOf('  function formatAiDate('), source.indexOf('  async function fetchAiConversation(')), context);
  vm.runInContext(source.slice(source.indexOf('  function updateChatSubmitState('), source.indexOf('  function updateChatUi(')), context);
  return { context, output };
}

function recurringEvents() {
  const dates = ['09-15', '09-17', '09-22', '09-24', '09-29', '10-01', '10-06', '10-08', '10-13', '10-15', '10-20', '10-22', '10-27', '10-29', '11-03', '11-05'];
  return dates.map((date) => ({
    title: 'CF-06 テストストレッチ',
    start_at: `2026-${date}T07:00:00+09:00`,
    end_at: `2026-${date}T07:10:00+09:00`,
    all_day: false
  }));
}

function renderRecommendation(events, kind = 'draft_event') {
  const { context, output } = chatView();
  context.renderAiConversation({ messages: [], recommendations: [{ id: 1, kind, ...events[0], payload: { events } }] });
  return html(output);
}

test('CF-06: a representative card exposes all 16 dates, period and batch size', () => {
  const events = recurringEvents();
  const output = renderRecommendation(events);
  assert.match(output, /全16件/);
  assert.match(output, /2026\/09\/15〜2026\/11\/05/);
  assert.match(output, /Asia\/Tokyo/);
  assert.match(output, /16件を予定に追加/);
  assert.equal((output.match(/<li>/g) || []).length, 16);
  for (const event of events) assert.ok(output.includes(event.start_at.slice(0, 10).replaceAll('-', '/')));
  assert.equal((output.match(/07:00 - 07:10/g) || []).length, 16);
});

test('independent recommendations keep their own single-event actions', () => {
  const output = renderRecommendation([recurringEvents()[0]]);
  assert.doesNotMatch(output, /<details|全1件|1件を予定に追加/);
  assert.match(output, /9\/15 07:00 - 07:10/);
  assert.match(output, />予定に追加<\/button>/);
});

test('bundle rows escape user titles and show cross-day and inclusive all-day ranges', () => {
  const output = renderRecommendation([
    { title: '<img src=x onerror=alert(1)>', start_at: '2026-09-15T23:30:00+09:00', end_at: '2026-09-16T01:00:00+09:00' },
    { title: '終日予定', start_at: '2026-09-17T00:00:00+09:00', end_at: '2026-09-19T00:00:00+09:00', all_day: true }
  ]);
  assert.doesNotMatch(output, /<img /);
  assert.match(output, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(output, /2026\/09\/15 23:30 - 2026\/09\/16 01:00/);
  assert.match(output, /2026\/09\/17〜2026\/09\/18 終日/);
  assert.match(output, /対象期間: 2026\/09\/15〜2026\/09\/18/);
});

test('CF-07a and CF-08: blanks and pending requests disable sending, then restore the label', () => {
  const { context } = chatView();
  for (const value of ['', '   ']) {
    context.chatInputEl.value = value;
    context.updateChatSubmitState();
    assert.equal(context.chatSubmitBtnEl.disabled, true);
  }
  context.chatInputEl.value = 'CF-08 テスト集中作業';
  context.updateChatSubmitState();
  assert.equal(context.chatSubmitBtnEl.disabled, false);
  context.setChatSubmitting(true);
  assert.equal(context.chatSubmitBtnEl.disabled, true);
  assert.equal(context.chatSubmitBtnEl.textContent, '相談中...');
  context.setChatSubmitting(false);
  assert.equal(context.chatSubmitBtnEl.disabled, false);
  assert.equal(context.chatSubmitBtnEl.textContent, '相談');
});

test('CF-08: submitting again before the response does not create a second request', async () => {
  const { context, output } = chatView();
  let submit;
  let completeRequest;
  const requests = [];
  Object.assign(context, {
    chatFormEl: { addEventListener(name, handler) { if (name === 'submit') submit = handler; } },
    setChatInlineError() {},
    resizeChatInput() {},
    keepChatComposerOpenAfterSend() {},
    aiScopeForCurrentState: () => ({ scope: 'home', groupId: null }),
    apiFetch(path, options) {
      requests.push({ path, options });
      return new Promise((resolve) => { completeRequest = resolve; });
    }
  });
  vm.runInContext(source.slice(source.indexOf('  if (chatFormEl) {\n    chatFormEl.addEventListener(\'submit\''), source.indexOf('  // ---- calendar ----')), context);
  const event = { preventDefault() {} };
  context.chatInputEl.value = '2026年9月18日の16:00から30分、架空の「CF-08 テスト集中作業」の候補を一件提案してください。候補だけを表示し、保存や通知はしないでください。';
  const first = submit(event);
  await submit(event);
  assert.equal(requests.length, 1);
  assert.equal(context.chatSubmitBtnEl.disabled, true);
  assert.equal(context.chatSubmitBtnEl.textContent, '相談中...');
  completeRequest({
    messages: [{ role: 'user', body: requests[0].options.body.body }, { role: 'assistant', body: '候補を1件表示しました。' }],
    recommendations: [{ id: 2, kind: 'draft_event', title: 'CF-08 テスト集中作業', start_at: '2026-09-18T16:00:00+09:00', end_at: '2026-09-18T16:30:00+09:00' }]
  });
  await first;
  assert.equal(context.chatInputEl.value, '');
  assert.equal(context.chatSubmitBtnEl.disabled, true);
  assert.equal(context.chatSubmitBtnEl.textContent, '相談');
  assert.equal((html(output).match(/cf-ai-body/g) || []).length, 2);
  assert.equal((html(output).match(/data-ai-rec-action="accept"/g) || []).length, 1);
});
