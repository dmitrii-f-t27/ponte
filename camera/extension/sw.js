// Ponte Camera, service worker: the link to Ponte and the decisions.
// Ponte (ws://127.0.0.1:47839, which accepts only this extension's origin) sends the settings; the C of
// Specs/camera_rules.t27, built to cm.wasm, turns them into the shader's numbers; chrome.storage carries those to
// every Meet page (bridge.js -> page.js). The pages report how many cameras they process, and that goes back to
// Ponte's panel. Without Ponte the last settings stay in storage and keep working.
const PORT = 47839;          // CM_LINK_PORT
const VERSION = 1;           // CM_LINK_VERSION
const SETTINGS = 9;          // CM_SET_COUNT
const STORE = 'ponteCamera';
const CAMERAS_MAX = 16;      // CM_LINK_CAMERAS_MAX

let cm = null;
async function rules() {
  if (cm) return cm;
  const bytes = await (await fetch(chrome.runtime.getURL('cm.wasm'))).arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {});
  instance.exports._initialize?.();
  cm = instance.exports;
  return cm;
}

// Settings as the spec holds them, and the numbers the shader needs.
async function decide(on, values) {
  const x = await rules();
  const s = [];
  for (let k = 0; k < SETTINGS; k++) {
    const v = Number.isFinite(values?.[k]) ? Math.trunc(values[k]) : Number(x.cm_setting_default(BigInt(k)));
    s.push(Number(x.cm_clamp_setting(BigInt(k), BigInt(Math.max(-1e9, Math.min(1e9, v))))));
  }
  const b = s.map(BigInt);
  const floats = () => new Float32Array(x.memory.buffer, x.cm_wasm_floats(), 16);
  const n = Number(x.cm_color_params(b[0], b[1], b[2], b[3], b[4], x.cm_wasm_floats()));
  const params = Array.from(floats().slice(0, n));
  x.cm_crop(b[5], b[6], b[7], b[8], x.cm_wasm_floats());
  const crop = Array.from(floats().slice(0, 4));
  const colorIdentity = x.cm_color_identity(b[0], b[1], b[2], b[3], b[4]) !== 0;
  const frameIdentity = x.cm_frame_identity(b[5], b[6], b[7], b[8]) !== 0;
  const needs = x.cm_needs_processing(on ? 1 : 0, colorIdentity ? 1 : 0, frameIdentity ? 1 : 0) !== 0;
  return { on: !!on, s, params, crop, needs };
}

// --- The link to Ponte -------------------------------------------------------------------------------------------
let socket = null;
let lastSent = '';
const cameras = new Map();   // tab id -> processed cameras on that page

function send(message) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}
function sendStatus(force) {
  let total = 0;
  for (const n of cameras.values()) total += n;
  const text = JSON.stringify({ type: 'status', v: VERSION, cameras: total });
  if (force || text !== lastSent) { lastSent = text; send(JSON.parse(text)); }
}

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  try {
    socket = new WebSocket(`ws://127.0.0.1:${PORT}/camera`);
  } catch {
    return;
  }
  socket.onopen = () => {
    send({ type: 'hello', v: VERSION, version: chrome.runtime.getManifest().version });
    sendStatus(true);
  };
  socket.onmessage = async (event) => {
    let m;
    try { m = JSON.parse(event.data); } catch { return; }
    if (m?.type !== 'settings' || m.v !== VERSION || !Array.isArray(m.s)) return;
    const state = await decide(m.on !== false, m.s);
    const old = (await chrome.storage.local.get(STORE))[STORE];
    if (JSON.stringify(old) !== JSON.stringify(state)) await chrome.storage.local.set({ [STORE]: state });
  };
  socket.onclose = () => { socket = null; };
  socket.onerror = () => {};
}

// Ponte may start later than the browser: try again on every wake-up and every 30 s.
chrome.alarms.create('ponte-camera-link', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());
chrome.runtime.onStartup.addListener(() => connect());
chrome.runtime.onInstalled.addListener(async () => {
  const stored = (await chrome.storage.local.get(STORE))[STORE];
  if (!stored) await chrome.storage.local.set({ [STORE]: await decide(true, []) });
  connect();
});

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== 'status' || !sender.tab?.id) return;
  const n = Math.max(0, Math.min(CAMERAS_MAX, message.cameras | 0));
  if (n === 0) cameras.delete(sender.tab.id); else cameras.set(sender.tab.id, n);
  connect();
  sendStatus(false);
});
chrome.tabs.onRemoved.addListener((tabId) => {
  if (cameras.delete(tabId)) sendStatus(false);
});

connect();
