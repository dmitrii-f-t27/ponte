// End-to-end test of the Ponte Camera extension in a headless Chrome of its own (never the owner's browser):
//   node camera/test/e2e.mjs                 (a stand-in for Ponte's link, written in Node)
//   PONTE_LINK=1 node camera/test/e2e.mjs    (Ponte's own CameraLink, run by .build/debug/CameraProbe)
// - a fake camera plays four solid colour blocks (a Y4M file made with ffmpeg);
// - a test copy of camera/extension (same key, so the same ID; its pages are http://127.0.0.1 instead of Meet, and
//   its link port is a free one) is loaded over the DevTools pipe;
// - a stand-in for Ponte's camera link checks the handshake's Origin, sends settings and reads the status;
// - the test page asks getUserMedia for the camera, as Meet does, and reads the colours of the frames it gets.
// The colours after the shader must equal cm_apply_pixel of the colours before it (cm.wasm, the spec's C) within
// a few levels of 255 (YUV and GPU rounding); zoom and mirror must show the expected block.
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
const work = mkdtempSync(join(tmpdir(), 'ponte-camera-e2e-'));
const fail = (message) => { console.error(`FAIL ${message}`); cleanup(); process.exit(1); };
let chrome = null;
const cleanup = () => {
  try { chrome?.kill('SIGKILL'); } catch {}
  try { probe?.stdin.end(); probe?.kill(); } catch {}
  try { rmSync(work, { recursive: true, force: true }); } catch {}
};

// --- The fake camera: TL, TR, BL, BR blocks, 640x480 ---------------------------------------------------------------
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

// --- Ponte's camera link: the real one (CameraProbe) or a stand-in -------------------------------------------------
const PONTE = process.env.PONTE_LINK === '1';
let linkPort, link = null, origin = null, wss = null, probe = null;
const statuses = [];
let sendSettings;
if (PONTE) {
  const free = createServer();
  await new Promise((r) => free.listen(0, '127.0.0.1', r));
  linkPort = free.address().port;
  await new Promise((r) => free.close(r));
  probe = spawn(join(root, '.build', 'debug', 'CameraProbe'), ['--port', String(linkPort)], { stdio: ['pipe', 'pipe', 'inherit'] });
  let out = '';
  probe.stdout.on('data', (d) => {
    out += d;
    let i;
    while ((i = out.indexOf('\n')) >= 0) {
      const [word, listening, failed, clients, cameras] = out.slice(0, i).split(' ');
      out = out.slice(i + 1);
      if (word !== 'status') continue;
      if (failed === '1') { console.error('FAIL the link failed to listen'); process.exit(1); }
      // A connected extension passed the link's own origin check (camera_rules.t27, cm_origin_allowed).
      if (clients !== '0') { link = true; origin = 'chrome-extension://jinldckdcbeojhpahpkagmacfdapfnln (checked by Ponte)'; }
      if (link) statuses.push(Number(cameras));
    }
  });
  sendSettings = (s, on = true) => probe.stdin.write(`publish ${JSON.stringify({ type: 'settings', v: 1, on, s })}\n`);
  sendSettings([0, 0, 0, 0, 0, 100, 0, 0, 0]);
} else {
  wss = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  await new Promise((r) => wss.once('listening', r));
  linkPort = wss.address().port;
  wss.on('connection', (socket, request) => {
    origin = request.headers.origin;
    link = socket;
    socket.on('message', (data) => {
      const m = JSON.parse(String(data));
      if (m.type === 'status') statuses.push(m.cameras);
    });
  });
  sendSettings = (s, on = true) => link.send(JSON.stringify({ type: 'settings', v: 1, on, s }));
}
console.log(`ok   link: ${PONTE ? `Ponte's CameraLink on ${linkPort}` : `a stand-in on ${linkPort}`}`);

// --- The test page -------------------------------------------------------------------------------------------------
const PAGE = `<!doctype html><meta charset="utf-8"><title>camera test</title><script>
let track = null, reader = null;
window.openCamera = async () => {
  const stream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480 }, audio: false });
  track = stream.getVideoTracks()[0];
  reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
  return { label: track.label, settings: track.getSettings() };
};
// The colour at (x, y) in 0...1 of a frame read now (a few frames are skipped so new settings take effect).
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
window.closeCamera = () => { track.stop(); return true; };
</script>`;
const http = createServer((req, res) => { res.setHeader('content-type', 'text/html'); res.end(PAGE); });
await new Promise((r) => http.listen(0, '127.0.0.1', r));
const pageURL = `http://127.0.0.1:${http.address().port}/test.html`;

// --- The test copy of the extension ---------------------------------------------------------------------------------
const ext = join(work, 'extension');
cpSync(join(root, 'camera', 'extension'), ext, { recursive: true });
const manifest = JSON.parse(readFileSync(join(ext, 'manifest.json'), 'utf8'));
manifest.host_permissions = ['http://127.0.0.1/*'];
for (const script of manifest.content_scripts) script.matches = ['http://127.0.0.1/*'];
writeFileSync(join(ext, 'manifest.json'), JSON.stringify(manifest, null, 2));
const sw = readFileSync(join(ext, 'sw.js'), 'utf8').replace(/const PORT = \d+;/, `const PORT = ${linkPort};`);
if (!sw.includes(`const PORT = ${linkPort};`)) fail('could not set the test port in sw.js');
writeFileSync(join(ext, 'sw.js'), sw);

// --- Chrome over the DevTools pipe ----------------------------------------------------------------------------------
chrome = spawn(CHROME, ['--headless=new', '--remote-debugging-pipe', '--enable-unsafe-extension-debugging',
  `--user-data-dir=${join(work, 'profile')}`, '--no-first-run', '--no-default-browser-check',
  '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-video-capture=${video}`,
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
let chromeErr = '';
chrome.stdio[2].on('data', (d) => { chromeErr += d; });
const pending = new Map();
let nextId = 0, buffer = '';
chrome.stdio[4].on('data', (data) => {
  buffer += data.toString();
  let i;
  while ((i = buffer.indexOf('\0')) >= 0) {
    const message = JSON.parse(buffer.slice(0, i));
    buffer = buffer.slice(i + 1);
    const p = pending.get(message.id);
    if (p) { pending.delete(message.id); message.error ? p.reject(new Error(JSON.stringify(message.error))) : p.resolve(message.result); }
  }
});
const cdp = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++nextId;
  pending.set(id, { resolve, reject });
  chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (what, test, ms = 15000) => {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(100)) if (test()) return;
  fail(`timed out: ${what}`);
};

try {
  await cdp('Browser.getVersion');
  const { id } = await cdp('Extensions.loadUnpacked', { path: ext });
  if (id !== EXTENSION_ID) fail(`extension ID ${id}, expected ${EXTENSION_ID}`);
  console.log(`ok   extension loaded with ID ${id}`);
  await until('the extension connects to the link', () => link !== null);
  if (!PONTE && origin !== `chrome-extension://${EXTENSION_ID}`) fail(`origin ${origin}`);
  console.log(`ok   handshake origin ${origin}`);

  const { targetId } = await cdp('Target.createTarget', { url: pageURL });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  const evaluate = async (expression) => {
    const r = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (r.exceptionDetails) fail(`page: ${JSON.stringify(r.exceptionDetails)}`);
    return r.result.value;
  };
  await until('page loaded', () => true);
  await sleep(500);
  const opened = await evaluate('openCamera()');
  console.log(`ok   camera opened through the wrapper: ${opened.settings.width}x${opened.settings.height}`);
  await until('status 1 camera', () => statuses.at(-1) === 1);
  console.log('ok   the link reports 1 processed camera');

  const centres = [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75]];
  sendSettings([0, 0, 0, 0, 0, 100, 0, 0, 0]);
  await sleep(700);
  const before = await evaluate(`sample(${JSON.stringify(centres)}, 6)`);
  console.log(`ok   colours as they come: ${JSON.stringify(before)}`);

  // The spec's own transform of those colours.
  const { instance } = await WebAssembly.instantiate(readFileSync(join(root, 'camera', 'extension', 'cm.wasm')), {});
  const x = instance.exports;
  x._initialize?.();
  const expect = (s, rgb) => {
    x.cm_apply_pixel(...s.slice(0, 5).map(BigInt), rgb[0] / 255, rgb[1] / 255, rgb[2] / 255, x.cm_wasm_floats());
    return Array.from(new Float32Array(x.memory.buffer, x.cm_wasm_floats(), 3), (v) => Math.round(v * 255));
  };
  let worst = 0;
  for (const s of [[40, 30, 0, 0, 0], [0, 0, 80, 0, 0], [0, 0, 0, 100, 0], [0, 0, 0, 0, -100], [-30, -40, 30, -60, 60],
                   [100, 100, 100, 100, 100]]) {
    sendSettings([...s, 100, 0, 0, 0]);
    await sleep(700);
    const after = await evaluate(`sample(${JSON.stringify(centres)}, 6)`);
    for (let i = 0; i < 4; i++) {
      const want = expect(s, before[i]);
      const diff = Math.max(...want.map((v, c) => Math.abs(v - after[i][c])));
      worst = Math.max(worst, diff);
      if (diff > TOLERANCE) fail(`settings ${s} block ${i}: shader ${after[i]}, spec ${want} (from ${before[i]})`);
    }
    console.log(`ok   colour ${JSON.stringify(s)}: ${JSON.stringify(after)}`);
  }
  console.log(`ok   shader = cm_apply_pixel within ${worst} of 255 (limit ${TOLERANCE})`);

  // Zoom 200 and mirror: (0.1, 0.1) shows u = 0.75 - 0.05 = 0.70, v = 0.30: the top right block; (0.9, 0.9) the
  // bottom left one.
  sendSettings([0, 0, 0, 0, 0, 200, 0, 0, 1]);
  await sleep(700);
  const framed = await evaluate(`sample([[0.1, 0.1], [0.9, 0.9]], 6)`);
  const near = (a, b) => Math.max(...a.map((v, c) => Math.abs(v - b[c]))) <= TOLERANCE;
  if (!near(framed[0], before[1]) || !near(framed[1], before[2])) fail(`zoom+mirror ${JSON.stringify(framed)}`);
  console.log(`ok   zoom 200 + mirror: ${JSON.stringify(framed)} = top right, bottom left`);

  // Off: frames pass as they came.
  sendSettings([60, 60, 60, 60, 60, 200, 0, 0, 1], false);
  await sleep(700);
  const off = await evaluate(`sample(${JSON.stringify(centres)}, 6)`);
  for (let i = 0; i < 4; i++) if (!near(off[i], before[i])) fail(`off: ${off[i]} vs ${before[i]}`);
  console.log('ok   off: frames pass unchanged');

  await evaluate('closeCamera()');
  await until('status 0 cameras', () => statuses.at(-1) === 0);
  console.log('ok   stopping the track reports 0 cameras');
  console.log('PASS');
} catch (error) {
  console.error(chromeErr.split('\n').slice(-20).join('\n'));
  fail(error.stack ?? String(error));
} finally {
  cleanup();
  wss?.close();
  http.close();
}
process.exit(0);
