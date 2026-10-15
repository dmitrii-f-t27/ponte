// Faults and recovery of the Ponte Camera extension, in a headless Chrome of its own (never the owner's browser),
// with a fake camera and SwiftShader: a PASS here is NOT a PASS on the owner's Mac with its real camera and GPU
// (camera/test/diagnose.mjs is that check).   node camera/test/faults.mjs
// The test copy of the extension (same key and ID, pages on http://127.0.0.1, its own link port) has a fault script
// put in front of page.js; it can make texImage2D throw, the VideoFrame constructor throw, WebGL2 contexts unavailable,
// every WebGL context lost, and Meet's writer refuse a frame; it counts the frames handed to the writer that were
// already closed. The production page.js is not changed. Checked:
//  - Ponte is not running when the browser starts, starts late: the extension connects by itself;
//  - before any fault, the first renderer (WebGL2 from the canvas) draws with no failure line and no trouble report
//    (any line there is kept apart as the baseline and fails that check);
//  - a renderer failure: the first console line after the fault names the stage, the DOMException's name and message (never "[object ...]"),
//    the link reports the camera in trouble with that error, the frames meanwhile are the live camera (not black);
//  - every renderer failing: the track gives up (FAILED) and starts again on new settings, processing again;
//  - one failure while making the new frame: it recovers by itself;
//  - a lost WebGL context: a new one is made, and at most one context stays alive;
//  - no WebGL2 at all: frame-only settings are drawn by the 2D canvas (zoom and mirror right); settings with colour
//    change cannot be, and the link says so instead of "processed";
//  - Ponte quits: the camera keeps the last settings; Ponte returns: the extension connects again;
//  - Meet's writer refuses a drawn frame: no closed frame is ever handed to it, the error is reported with its stage,
//    the camera is released and its track ends;
//  - a page reloads or navigates away: the link stops counting its camera at once (pagehide); a page crashes: it is
//    counted until its report's lease runs out, also when the service worker slept meanwhile (the report is aged in
//    session storage, the worker stopped over CDP and woken by a new page).
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { cpSync, mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const require = createRequire(join(root, 'relay', 'package.json'));
const { WebSocketServer } = require('ws');
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const EXTENSION_ID = 'jinldckdcbeojhpahpkagmacfdapfnln';
const TOLERANCE = 6; // levels of 255
// CM_* codes this test reads in the page's report.
const STAGE = { create: 1, upload: 2, output: 4, lost: 5, write: 6 };
const TRK_FAILED = 4;
const RV_WEBGL_CANVAS = 1;
const RV_CANVAS2D = 2;
// page.js's names of the renderers (CM_RV_*), as its console lines say them.
const RENDERER_NAMES = ['WebGL2 (bitmap)', 'WebGL2 (canvas)', '2D canvas'];

const work = mkdtempSync(join(tmpdir(), 'ponte-camera-faults-'));
let chrome = null;
let server = null;
const results = [];
const check = (name, ok, detail = '') => {
  results.push(ok);
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
};
const cleanup = () => {
  try { chrome?.kill('SIGKILL'); } catch {}
  try { for (const c of server?.clients ?? []) c.terminate(); server?.close(); } catch {}
  try { rmSync(work, { recursive: true, force: true }); } catch {}
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
class Timeout extends Error {}
const until = async (what, test, ms = 15000) => {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (await test()) return;
  throw new Timeout(`timed out: ${what}`);
};

// --- The fake camera: TL, TR, BL, BR blocks, 640x480 -------------------------------------------------------------
const BLOCKS = { tl: [200, 60, 40], tr: [40, 160, 90], bl: [90, 90, 200], br: [128, 128, 128] };
const video = join(work, 'blocks.y4m');
const hex = ([r, g, b]) => `0x${[r, g, b].map((v) => v.toString(16).padStart(2, '0')).join('')}`;
execFileSync('ffmpeg', ['-v', 'error', '-y',
  '-f', 'lavfi', '-i', `color=c=${hex(BLOCKS.tl)}:s=320x240:r=15:d=2`,
  '-f', 'lavfi', '-i', `color=c=${hex(BLOCKS.tr)}:s=320x240:r=15:d=2`,
  '-f', 'lavfi', '-i', `color=c=${hex(BLOCKS.bl)}:s=320x240:r=15:d=2`,
  '-f', 'lavfi', '-i', `color=c=${hex(BLOCKS.br)}:s=320x240:r=15:d=2`,
  '-filter_complex', '[0][1]hstack[top];[2][3]hstack[bottom];[top][bottom]vstack,format=yuv420p',
  '-pix_fmt', 'yuv420p', video]);

// --- A stand-in for Ponte's link on a port where nothing listens yet ------------------------------------------------
const free = createServer();
await new Promise((r) => free.listen(0, '127.0.0.1', r));
const linkPort = free.address().port;
await new Promise((r) => free.close(r));
const link = { socket: null, connections: 0, origins: new Set(), statuses: [] };
let settings = { type: 'settings', v: 1, on: true, s: [0, 0, 0, 0, 0, 100, 0, 0, 0] };
function startLink() {
  return new Promise((resolve, reject) => {
    const wss = new WebSocketServer({ host: '127.0.0.1', port: linkPort });
    wss.once('error', reject);
    wss.once('listening', () => resolve(wss));
    wss.on('connection', (socket, request) => {
      link.connections += 1;
      link.origins.add(request.headers.origin);
      link.socket = socket;
      socket.send(JSON.stringify(settings));
      socket.on('message', (data) => {
        const m = JSON.parse(String(data));
        if (m.type === 'status') link.statuses.push(m);
      });
      socket.on('close', () => { if (link.socket === socket) link.socket = null; });
    });
  });
}
async function stopLink() {
  for (const c of server.clients) c.terminate();
  await new Promise((r) => server.close(r));
  server = null;
  link.socket = null;
}
const sendSettings = (s, on = true) => {
  settings = { type: 'settings', v: 1, on, s };
  link.socket?.send(JSON.stringify(settings));
};

// --- The test page and the test copy of the extension -------------------------------------------------------------
const PAGE = `<!doctype html><meta charset="utf-8"><title>camera faults</title><script>
let track = null, reader = null;
window.statuses = [];
window.addEventListener('message', (e) => {
  if (e.source === window && e.data && e.data.__ponteCamera === 'status') window.statuses.push(e.data);
});
window.openCamera = async () => {
  const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 }, audio: false });
  track = stream.getVideoTracks()[0];
  reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
  return true;
};
window.sample = async (points, skip) => {
  let frame = null;
  for (let i = 0; i <= skip; i++) { frame?.close(); frame = (await reader.read()).value; }
  const canvas = new OffscreenCanvas(frame.displayWidth, frame.displayHeight);
  const ctx = canvas.getContext('2d');
  ctx.drawImage(frame, 0, 0);
  const w = frame.displayWidth, h = frame.displayHeight;
  frame.close();
  return points.map(([x, y]) => Array.from(ctx.getImageData(Math.floor(x * w), Math.floor(y * h), 1, 1).data.slice(0, 3)));
};
window.last = () => window.statuses.at(-1) ?? null;
window.trackState = () => track ? track.readyState : 'none';
</script>`;
const FAULTS = `// Test only (camera/test/faults.mjs): faults on demand, put in front of page.js in the test copy.
(() => {
  const f = window.__ponteFault = { texImage: 0, videoFrame: 0, noWebgl: 0, writeReject: 0, writes: 0, closedWrites: 0,
                                    contexts: [] };
  const tex = WebGL2RenderingContext.prototype.texImage2D;
  WebGL2RenderingContext.prototype.texImage2D = function (...args) {
    if (f.texImage > 0) { f.texImage -= 1; throw new DOMException('injected upload failure', 'InvalidStateError'); }
    return tex.apply(this, args);
  };
  const VF = window.VideoFrame;
  window.VideoFrame = new Proxy(VF, { construct(target, args) {
    if (f.videoFrame > 0 && (args[0] instanceof OffscreenCanvas || args[0] instanceof ImageBitmap)) {
      f.videoFrame -= 1;
      throw new DOMException('injected output failure', 'InvalidStateError');
    }
    return Reflect.construct(target, args);
  } });
  const getContext = OffscreenCanvas.prototype.getContext;
  OffscreenCanvas.prototype.getContext = function (type, options) {
    if (type === 'webgl2' && f.noWebgl > 0) { f.noWebgl -= 1; return null; }
    const ctx = getContext.call(this, type, options);
    if (type === 'webgl2' && ctx) f.contexts.push(ctx);
    return ctx;
  };
  f.loseAll = () => { for (const c of f.contexts) { try { if (!c.isContextLost()) c.getExtension('WEBGL_lose_context').loseContext(); } catch {} } };
  f.live = () => f.contexts.filter((c) => !c.isContextLost()).length;
  const write = WritableStreamDefaultWriter.prototype.write;
  WritableStreamDefaultWriter.prototype.write = function (chunk) {
    if (chunk instanceof VF) {
      f.writes += 1;
      // A closed VideoFrame has no coded size (WebCodecs: close() resets it to 0).
      if (chunk.codedWidth === 0 && chunk.codedHeight === 0) f.closedWrites += 1;
      if (f.writeReject > 0) { f.writeReject -= 1; return Promise.reject(new DOMException('injected write failure', 'OperationError')); }
    }
    return write.call(this, chunk);
  };
})();
`;
const http = createServer((req, res) => { res.setHeader('content-type', 'text/html'); res.end(PAGE); });
await new Promise((r) => http.listen(0, '127.0.0.1', r));
const pageURL = `http://127.0.0.1:${http.address().port}/faults.html`;

const ext = join(work, 'extension');
cpSync(join(root, 'camera', 'extension'), ext, { recursive: true });
const manifest = JSON.parse(readFileSync(join(ext, 'manifest.json'), 'utf8'));
manifest.host_permissions = ['http://127.0.0.1/*'];
for (const script of manifest.content_scripts) script.matches = ['http://127.0.0.1/*'];
writeFileSync(join(ext, 'manifest.json'), JSON.stringify(manifest, null, 2));
const sw = readFileSync(join(ext, 'sw.js'), 'utf8').replace(/const PORT = \d+;/, `const PORT = ${linkPort};`);
if (!sw.includes(`const PORT = ${linkPort};`)) { console.error('FAIL could not set the test port in sw.js'); process.exit(1); }
writeFileSync(join(ext, 'sw.js'), sw);
writeFileSync(join(ext, 'page.js'), FAULTS + readFileSync(join(ext, 'page.js'), 'utf8'));

// --- Chrome over the DevTools pipe ----------------------------------------------------------------------------------
chrome = spawn(CHROME, ['--headless=new', '--remote-debugging-pipe', '--enable-unsafe-extension-debugging',
  `--user-data-dir=${join(work, 'profile')}`, '--no-first-run', '--no-default-browser-check',
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-video-capture=${video}`,
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
let chromeErr = '';
chrome.stdio[2].on('data', (d) => { chromeErr += d; });
const pending = new Map();
const consoleLines = [];
let nextId = 0, buffer = '';
chrome.stdio[4].on('data', (data) => {
  buffer += data.toString();
  let i;
  while ((i = buffer.indexOf('\0')) >= 0) {
    const message = JSON.parse(buffer.slice(0, i));
    buffer = buffer.slice(i + 1);
    if (message.method === 'Runtime.consoleAPICalled') {
      consoleLines.push(message.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
      continue;
    }
    const p = pending.get(message.id);
    if (p) { pending.delete(message.id); message.error ? p.reject(new Error(JSON.stringify(message.error))) : p.resolve(message.result); }
  }
});
const cdp = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++nextId;
  pending.set(id, { resolve, reject });
  chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
});

const near = (a, b) => Math.max(...a.map((v, c) => Math.abs(v - b[c]))) <= TOLERANCE;
const centres = [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]];

try {
  await cdp('Browser.getVersion');
  const { id } = await cdp('Extensions.loadUnpacked', { path: ext });
  check('extension loaded with its own ID', id === EXTENSION_ID, id);

  // Ponte is not running when the browser starts, and starts later.
  await sleep(4000);
  check('nothing connects while Ponte is off', link.connections === 0);
  server = await startLink();
  let t0 = Date.now();
  await until('the extension connects after Ponte starts late', () => link.socket !== null, 45000);
  check('Ponte started late: the extension connected by itself', true, `${Date.now() - t0} ms`);
  check('only the extension origin connected', link.origins.size === 1 && link.origins.has(`chrome-extension://${EXTENSION_ID}`));

  const { targetId } = await cdp('Target.createTarget', { url: pageURL });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  await cdp('Runtime.enable', {}, sessionId);
  const evaluate = async (expression) => {
    const r = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error(`page: ${JSON.stringify(r.exceptionDetails)}`);
    return r.result.value;
  };
  const last = () => evaluate('last()');
  const seen = (test) => evaluate(`statuses.some((s) => ${test})`);
  await sleep(500);
  await evaluate('openCamera()');
  await until('camera passing', async () => (await last())?.passing === 1);
  const before = await evaluate(`sample(${JSON.stringify(centres)}, 6)`);

  // The spec's own transform of those colours (cm.wasm).
  const { instance } = await WebAssembly.instantiate(readFileSync(join(root, 'camera', 'extension', 'cm.wasm')), {});
  const x = instance.exports;
  x._initialize?.();
  const expect = (s, rgb) => {
    x.cm_apply_pixel(...s.slice(0, 5).map(BigInt), rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, x.cm_wasm_floats());
    return Array.from(new Float32Array(x.memory.buffer, x.cm_wasm_floats(), 3), (v) => Math.round(v * 255));
  };
  const processedAs = async (s) => {
    const after = await evaluate(`sample(${JSON.stringify(centres)}, 6)`);
    return after.every((rgb, i) => near(rgb, expect(s, before[i])));
  };
  const unprocessed = async () => {
    const after = await evaluate(`sample(${JSON.stringify(centres)}, 6)`);
    return after.every((rgb, i) => near(rgb, before[i]));
  };

  const A = [40, 30, 20, 10, 10, 100, 0, 0, 0];
  sendSettings(A);
  await until('processed with effects', async () => (await last())?.processed === 1);
  check('effects: the camera is processed as cm_apply_pixel', await processedAs(A));
  // Before any fault: the first renderer (WebGL2 from the canvas, which works here and on the owner's M4) drew from
  // the start: no failure line and no trouble report. Any line here is kept apart as the baseline and fails this
  // check; the fault checks below look only at lines after their fault.
  const ponteLines = (from) => consoleLines.slice(from).filter((l) => l.startsWith('Ponte Camera:'));
  const baseline = ponteLines(0);
  check('before any fault: the first renderer drew, no failure and no trouble report',
    baseline.length === 0 && (await last())?.detail?.[0]?.renderer === RV_WEBGL_CANVAS &&
    !(await seen('s.troubled > 0')), baseline.length ? baseline.join(' | ') : 'no failure');

  // A renderer that cannot take the camera frame in, every time.
  const rendererAtFault = (await last())?.detail?.[0]?.renderer;
  const injectedAt = consoleLines.length;
  await evaluate('__ponteFault.texImage = 1e9');
  await until('the camera is in trouble', async () => (await last())?.troubled === 1);
  const trouble = await last();
  check('trouble: the page reports the stage, name and message', trouble.error?.stage === STAGE.upload &&
    trouble.error?.name === 'InvalidStateError' && trouble.error?.message === 'injected upload failure', JSON.stringify(trouble.error));
  check('trouble: the frames are the live camera, unprocessed (not black)', await unprocessed());
  await until('the track gives up after every renderer', async () => (await last())?.detail?.[0]?.state === TRK_FAILED, 10000);
  check('every renderer failed: FAILED, still reported as trouble, never as processed',
    (await last()).troubled === 1 && (await last()).processed === 0);
  await until('the link reports the trouble with the error', () => link.statuses.some((m) => m.troubled === 1 &&
    m.error?.stage === STAGE.upload && m.error?.name === 'InvalidStateError'), 10000);
  check('the link (Ponte) got the trouble and the cleaned error', true);
  // The first Ponte line after the fault was put in is that fault, said in full (the renderer that was drawing, the
  // stage, the name, the message).
  const warning = ponteLines(injectedAt)[0];
  check('the console names the stage and the DOMException readably',
    warning === `Ponte Camera: failed at ${RENDERER_NAMES[rendererAtFault]}, taking the frame in: InvalidStateError: injected upload failure` &&
    !consoleLines.some((l) => l.includes('[object')), warning);
  check('at most one WebGL context alive while failing', (await evaluate('__ponteFault.live()')) <= 1);
  await evaluate('__ponteFault.texImage = 0');
  const A2 = [41, 30, 20, 10, 10, 100, 0, 0, 0];
  sendSettings(A2);
  await until('processed again after new settings', async () => (await last())?.processed === 1, 10000);
  check('new settings start a failed track again: processed', await processedAs(A2));

  // One failure while making the new frame: recovers by itself.
  const mark = await evaluate('statuses.length');
  await evaluate('__ponteFault.videoFrame = 1');
  await until('the output failure is seen', () => seen(`s.error && s.error.stage === ${STAGE.output}`), 10000);
  await until('processed again by itself', async () => (await last())?.processed === 1 &&
    (await evaluate(`statuses.length`)) > mark, 10000);
  check('a failure making the new frame recovers without new settings', await processedAs(A2));

  // A lost context: a new one, and no context left behind.
  await evaluate('__ponteFault.loseAll()');
  await until('the lost context is seen', () => seen(`s.error && s.error.stage === ${STAGE.lost}`), 10000);
  await until('processed after a lost context', async () => (await last())?.processed === 1, 10000);
  check('a lost WebGL context is replaced', await processedAs(A2));
  check('at most one WebGL context alive after recovering', (await evaluate('__ponteFault.live()')) <= 1,
    `${await evaluate('__ponteFault.live()')}`);

  // No WebGL2 at all: the 2D canvas draws frame-only settings; colour cannot be drawn and is reported as trouble.
  // (The working context is lost too, so the track has to make a new one and finds none.)
  await evaluate('__ponteFault.noWebgl = 1e9');
  const F = [0, 0, 0, 0, 0, 200, 0, 0, 1];
  sendSettings(F);
  await sleep(300);
  await evaluate('__ponteFault.loseAll()');
  await until('the 2D canvas draws the frame', async () => {
    const s = await last();
    return s?.processed === 1 && s.detail?.[0]?.renderer === RV_CANVAS2D;
  }, 10000);
  const framed = await evaluate('sample([[0.1, 0.1], [0.9, 0.9]], 6)');
  check('2D canvas: zoom 200 + mirror show the top right and bottom left blocks',
    near(framed[0], before[1]) && near(framed[1], before[2]), JSON.stringify(framed));
  const C = [40, 0, 0, 0, 0, 200, 0, 0, 1];
  sendSettings(C);
  await until('colour without WebGL2 is trouble', async () => (await last())?.troubled === 1, 10000);
  const noGl = await last();
  check('colour without WebGL2: trouble at "create", not processed', noGl.processed === 0 &&
    noGl.error?.stage === STAGE.create, JSON.stringify(noGl.error));
  await evaluate('__ponteFault.noWebgl = 0');
  sendSettings(A2);
  await until('WebGL2 back: processed', async () => (await last())?.processed === 1, 10000);
  check('WebGL2 back: processed with colour again', await processedAs(A2));

  // Ponte quits: the last settings keep working; Ponte returns: the extension connects again.
  await stopLink();
  await sleep(3000);
  check('Ponte closed: the camera keeps the last settings', await processedAs(A2) && (await last()).processed === 1);
  const before2 = link.connections;
  server = await startLink();
  t0 = Date.now();
  await until('the extension connects again', () => link.connections > before2 && link.socket !== null, 45000);
  check('Ponte back: the extension connected again by itself', true, `${Date.now() - t0} ms`);

  // Meet's writer refuses a drawn frame: nothing closed is handed over, the error is reported, the camera released.
  await evaluate('__ponteFault.writeReject = 1');
  await until('the write failure is seen', () => seen(`s.error && s.error.stage === ${STAGE.write}`), 10000);
  const refused = await evaluate(`statuses.find((s) => s.error && s.error.stage === ${STAGE.write})`);
  check('a refused frame is reported with its stage and name', refused.error.name === 'OperationError', JSON.stringify(refused.error));
  await until('the camera is released', async () => {
    const s = await last();
    return s && s.processed === 0 && s.passing === 0 && s.troubled === 0;
  }, 10000);
  check("the wrapped track ended (Meet may ask again)", (await evaluate('trackState()')) === 'ended');
  const writes = await evaluate('[__ponteFault.writes, __ponteFault.closedWrites]');
  check('no closed frame was ever handed to the writer', writes[0] > 0 && writes[1] === 0, `${writes[0]} writes, ${writes[1]} closed`);

  // --- What the link counts when a page goes: a reload, a navigation away, a crash while the worker slept ---------
  const linkCounts = (cameras, passing, troubled) => {
    const s = link.statuses.at(-1);
    return !!s && s.cameras === cameras && s.passing === passing && s.troubled === troubled;
  };
  const pageReady = () => until('the test page is ready', async () => {
    try { return (await evaluate('typeof openCamera')) === 'function'; } catch { return false; }
  }, 10000);
  sendSettings(A2);
  await evaluate('openCamera()');
  await until('the link counts the camera again', () => linkCounts(1, 0, 0), 10000);
  await cdp('Page.reload', {}, sessionId);
  await until('after a reload the link counts no camera', () => linkCounts(0, 0, 0), 10000);
  check('a reloaded page: its old camera is no longer counted', true);
  await pageReady();
  await evaluate('openCamera()');
  await until('the link counts the camera of the reloaded page', () => linkCounts(1, 0, 0), 10000);
  // Away to a site the extension does not run on: no new report replaces the old one, only pagehide says it.
  const awayURL = pageURL.replace('127.0.0.1', 'localhost').replace('/faults.html', '/away.html');
  t0 = Date.now();
  await cdp('Page.navigate', { url: awayURL }, sessionId);
  await until('after navigating away the link counts no camera', () => linkCounts(0, 0, 0), 10000);
  check('a page that navigated away: its camera is no longer counted', true, `${Date.now() - t0} ms`);

  // A crashed page says nothing; its report must not outlive its lease, also across the worker's sleep. The report
  // is aged past the lease in session storage (as if the worker slept that long), the worker is stopped, and a new
  // page wakes it.
  await cdp('Page.navigate', { url: pageURL }, sessionId);
  await pageReady();
  await evaluate('openCamera()');
  await until('the link counts the camera before the crash', () => linkCounts(1, 0, 0), 10000);
  cdp('Page.crash', {}, sessionId).catch(() => {});
  await sleep(1000);
  check('a crashed page: still counted within its lease (no report says otherwise)', linkCounts(1, 0, 0),
    JSON.stringify(link.statuses.at(-1)));
  const { targetInfos } = await cdp('Target.getTargets');
  const worker = targetInfos.find((t) => t.type === 'service_worker' && t.url === `chrome-extension://${EXTENSION_ID}/sw.js`);
  if (!worker) throw new Error('the extension service worker is not running');
  const { sessionId: workerSession } = await cdp('Target.attachToTarget', { targetId: worker.targetId, flatten: true });
  const aged = await cdp('Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `(async () => {
    const k = 'ponteCameraPages';
    const m = (await chrome.storage.session.get(k))[k] ?? {};
    for (const p of Object.values(m)) p.seen = Date.now() - 10 * 60 * 1000;
    await chrome.storage.session.set({ [k]: m });
    return Object.keys(m).length;
  })()` }, workerSession);
  const before3 = link.connections;
  await cdp('Target.closeTarget', { targetId: worker.targetId });
  await until('the worker stopped (its link closed)', () => link.socket === null, 10000);
  await cdp('Target.createTarget', { url: pageURL });
  await until('the woken worker connects again', () => link.connections > before3 && link.socket !== null, 45000);
  await until('the woken worker does not count the crashed page', () => linkCounts(0, 0, 0), 10000);
  check('worker woke with an expired report: the crashed page is no longer counted', true,
    `${aged.result?.value} page(s) aged`);
} catch (error) {
  check(error instanceof Timeout ? error.message : (error.stack ?? String(error)), false);
  console.error(chromeErr.split('\n').slice(-20).join('\n'));
} finally {
  cleanup();
  http.close();
}
const failed = results.filter((ok) => !ok).length;
console.log(failed === 0 && results.length > 0 ? `PASS (${results.length} checks, fake camera + SwiftShader)`
  : `FAIL (${failed} of ${results.length} checks failed)`);
process.exit(failed === 0 && results.length > 0 ? 0 : 1);
