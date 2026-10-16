// Ponte Camera, service worker: the link to Ponte and the decisions.
// Ponte (ws://127.0.0.1:47839, which accepts only this extension's origin) sends the settings; the C of
// Specs/camera_rules.t27, built to cm.wasm, turns them into the shader's numbers and the pipeline's tables
// (policy.js); chrome.storage carries those to every Meet page (bridge.js -> page.js). The pages report their cameras
// (processed, passing as they came, in trouble) and their last error, and that goes back to Ponte's panel. Without
// Ponte the last settings stay in storage and keep working; the link is dialled again as cm_dial_wait_ms says.
// A page counts while its report's lease lasts (cm_page_lease_left_ms): it repeats its report, and says when it goes.
import { loadRules, decide, dialWaitMs, dialFailuresAfter, linkCameras, linkVersionTaken, errorRank, errorTakes,
  cleanError, pageLeaseLeftMs, pageGoneForgets } from './policy.js';

const PORT = 47839;          // CM_LINK_PORT
const VERSION = 1;           // CM_LINK_VERSION
const STORE = 'ponteCamera';
const DIAL_START = 0;        // CM_DIAL_START
const DIAL_INSTALL = 1;      // CM_DIAL_INSTALL
const DIAL_TIMER = 2;        // CM_DIAL_TIMER
const DIAL_PAGE = 3;         // CM_DIAL_PAGE
const DIAL_CLOSED = 4;       // CM_DIAL_CLOSED

let cm = null;
async function rules() {
  if (cm) return cm;
  cm = await loadRules(await (await fetch(chrome.runtime.getURL('cm.wasm'))).arrayBuffer());
  return cm;
}

// Writes the decided state when it differs from the stored one (pages see only real changes).
async function store(state) {
  const old = (await chrome.storage.local.get(STORE))[STORE];
  if (JSON.stringify(old) !== JSON.stringify(state)) await chrome.storage.local.set({ [STORE]: state });
}

// The stored settings decided again by this version's rules (an update brings new tables; nothing stored: defaults).
async function refresh() {
  const x = await rules();
  const stored = (await chrome.storage.local.get(STORE))[STORE];
  await store(decide(x, typeof stored?.on === 'boolean' ? stored.on : x.cm_default_on() !== 0, stored?.s ?? []));
}

// --- What the Meet pages report (kept in session storage: the worker sleeps between events) -------------------------
const PAGES = 'ponteCameraPages';
const DIAL = 'ponteCameraDial';
// tab id -> { doc, processed, passing, troubled, error, errorAt, seen }: `doc` the reporting document (a reload or
// a navigation makes a new one), `seen` when its last report came, `errorAt` when its error was first reported.
let pages = null;
let pagesLoad = null;        // the one read of the stored map after a wake-up (calls that overlap share it)
let pruneTimer = null;
const savePages = () => chrome.storage.session.set({ [PAGES]: pages }).catch(() => {});

// Forgets the pages whose lease ran out (on every use, so also right after the worker woke with an old map), and
// looks again when the next lease runs out while the worker is awake (else the alarm does).
async function pageMap() {
  const x = await rules();
  if (!pages) {
    pagesLoad ??= chrome.storage.session.get(PAGES).then((r) => { pages ??= r[PAGES] ?? {}; });
    await pagesLoad;
  }
  const now = Date.now();
  let next = 0, dropped = false;
  for (const [tab, p] of Object.entries(pages)) {
    const left = pageLeaseLeftMs(x, now - (Number(p.seen) || 0));
    if (left <= 0) { delete pages[tab]; dropped = true; } else if (next === 0 || left < next) next = left;
  }
  if (dropped) savePages();
  clearTimeout(pruneTimer);
  if (next > 0) pruneTimer = setTimeout(() => sendStatus(false), next);
  return pages;
}

// The pages' cameras added up, and the error of the highest rank (cm_report_error_rank), the newest among equals
// (cm_report_error_takes: a page's error is newer when it was first reported later).
function totals(x) {
  const t = { processed: 0, passing: 0, troubled: 0, error: null, rank: 0, at: -1 };
  for (const p of Object.values(pages ?? {})) {
    t.processed += p.processed;
    t.passing += p.passing;
    t.troubled += p.troubled;
    const rank = errorRank(x, !!p.error, p.troubled > 0);
    if (errorTakes(x, rank, t.rank, p.errorAt > t.at)) {
      t.error = p.error;
      t.rank = rank;
      t.at = p.errorAt;
    }
  }
  return t;
}

// --- The link to Ponte -----------------------------------------------------------------------------------------------
let socket = null;
let lastSent = '';
let timer = null;
let dial = null;             // { failures, last } of the attempts, kept across wake-ups

async function dialState() {
  if (!dial) dial = (await chrome.storage.session.get(DIAL))[DIAL] ?? { failures: 0, last: -1 };
  return dial;
}
const saveDial = () => chrome.storage.session.set({ [DIAL]: dial }).catch(() => {});

function send(message) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}
async function sendStatus(force) {
  const x = await rules();
  await pageMap();
  const t = totals(x);
  const text = JSON.stringify({ type: 'status', v: VERSION, cameras: linkCameras(x, t.processed),
    passing: linkCameras(x, t.passing), troubled: linkCameras(x, t.troubled), error: cleanError(x, t.error) });
  if (force || text !== lastSent) { lastSent = text; send(JSON.parse(text)); }
}

async function connect(reason) {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  const x = await rules();
  const d = await dialState();
  const open = Object.keys(await pageMap()).length;
  const wait = dialWaitMs(x, reason, d.last < 0 ? -1 : Date.now() - d.last, d.failures, open);
  clearTimeout(timer);
  if (wait > 0) {
    // While the worker stays awake; the alarm looks again after it slept.
    timer = setTimeout(() => connect(DIAL_TIMER), wait);
    return;
  }
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  d.last = Date.now();
  saveDial();
  let s;
  try {
    s = new WebSocket(`ws://127.0.0.1:${PORT}/camera`);
  } catch {
    d.failures = dialFailuresAfter(x, d.failures, false);
    saveDial();
    return;
  }
  socket = s;
  let opened = false;
  s.onopen = () => {
    opened = true;
    d.failures = dialFailuresAfter(x, d.failures, true);
    saveDial();
    send({ type: 'hello', v: VERSION, version: chrome.runtime.getManifest().version });
    sendStatus(true);
  };
  s.onmessage = async (event) => {
    let m;
    try { m = JSON.parse(event.data); } catch { return; }
    if (m?.type !== 'settings' || !linkVersionTaken(x, m.v) || !Array.isArray(m.s)) return;
    await store(decide(x, typeof m.on === 'boolean' ? m.on : x.cm_default_on() !== 0, m.s));
  };
  s.onclose = () => {
    if (socket === s) socket = null;
    // Refused (Ponte not running) or dropped before it opened: one more failure. A link that was open and closed
    // (Ponte quit) is dialled again at once, then as the failures grow.
    if (!opened) d.failures = dialFailuresAfter(x, d.failures, false);
    saveDial();
    connect(DIAL_CLOSED);
  };
  s.onerror = () => {};
}

// Ponte may start later than the browser: the alarm wakes the worker every 30 s to look again.
chrome.alarms.create('ponte-camera-link', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => {
  connect(DIAL_TIMER);
  sendStatus(false);
});
chrome.runtime.onStartup.addListener(() => connect(DIAL_START));
chrome.runtime.onInstalled.addListener(async () => {
  await refresh();
  connect(DIAL_INSTALL);
});

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== 'status' || !sender.tab?.id) return;
  (async () => {
    const x = await rules();
    const map = await pageMap();
    const tab = sender.tab.id, doc = sender.documentId ?? null, old = map[tab];
    if (message.gone) {
      // The page left (pagehide): forgotten, unless the tab already reports from its next document
      // (cm_page_gone_forgets).
      if (pageGoneForgets(x, !!old, !!old && old.doc === doc, old?.doc != null)) {
        delete map[tab];
        savePages();
        sendStatus(false);
      }
      return;
    }
    const error = message.error ?? null;
    const sameError = old && old.doc === doc && JSON.stringify(old.error) === JSON.stringify(error);
    map[tab] = {
      doc, processed: linkCameras(x, message.processed), passing: linkCameras(x, message.passing),
      troubled: linkCameras(x, message.troubled), error, errorAt: sameError ? old.errorAt : Date.now(), seen: Date.now(),
    };
    savePages();
    connect(DIAL_PAGE);
    sendStatus(false);
  })();
});
chrome.tabs.onRemoved.addListener(async (tabId) => {
  const map = await pageMap();
  if (!(tabId in map)) return;
  delete map[tabId];
  savePages();
  sendStatus(false);
});

refresh().catch(() => {}).finally(() => connect(DIAL_START));
