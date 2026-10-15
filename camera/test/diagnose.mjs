// Ponte Camera on a real browser, GPU and camera (BrowserOS or Chrome on the owner's Mac), not the headless fake:
//   node camera/test/diagnose.mjs [--port N] [--timeout-s 600]
// Serves camera/test/diagnose.html on http://127.0.0.1:<port>/ (a secure context, so the camera may be asked for) with
// the extension's own page.js, policy.js and cm.wasm. Open that address in the browser and press «Start»; the browser
// asks for the camera. The page runs the production page.js (the same file the extension injects into Meet):
//  1. synthetic frames with known colours through the wrapper, on the real GPU: the colours must equal cm_apply_pixel
//     within a few levels, zoom and mirror must show the expected blocks;
//  2. one real camera frame through each of page.js's two WebGL2 output paths on its own (VideoFrame from the canvas,
//     VideoFrame from an ImageBitmap): which step fails, if any, with the DOMException's name and message;
//  3. the real camera through the wrapper with effects: it must be reported "processed" (never "trouble") and frames
//     must be drawn; any failure is recorded with its stage, the DOMException's name and message.
// The page sends this server one JSON result (numbers, the browser's version, the GPU's and the camera's names; no
// frames, no pictures), which is printed; nothing leaves 127.0.0.1. The verdict says which run passed: "hardware PASS"
// needs a camera whose label is not Chrome's fake device; a fake device gives "fake device PASS" at most.
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const extension = join(here, '..', 'extension');
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? Number(process.argv[i + 1]) : fallback;
};
const files = {
  '/': [join(here, 'diagnose.html'), 'text/html; charset=utf-8'],
  '/extension/page.js': [join(extension, 'page.js'), 'text/javascript'],
  '/extension/policy.js': [join(extension, 'policy.js'), 'text/javascript'],
  '/extension/cm.wasm': [join(extension, 'cm.wasm'), 'application/wasm'],
};

let done = null;
const result = new Promise((resolve) => { done = resolve; });
const server = createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/result') {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 65536) req.destroy();
    });
    req.on('end', () => {
      res.writeHead(204);
      res.end();
      try { done(JSON.parse(body)); } catch { done({ verdict: 'FAIL', error: 'unreadable result' }); }
    });
    return;
  }
  const file = req.method === 'GET' ? files[req.url] : null;
  if (!file) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { 'content-type': file[1], 'cache-control': 'no-store' });
  res.end(readFileSync(file[0]));
});
await new Promise((r) => server.listen(arg('--port', 0), '127.0.0.1', r));
console.log(`Open http://127.0.0.1:${server.address().port}/ in the browser to check and press «Start».`);
const timeout = setTimeout(() => done({ verdict: 'FAIL', error: 'no result in time' }), arg('--timeout-s', 600) * 1000);
const r = await result;
clearTimeout(timeout);
server.close();
console.log(JSON.stringify(r, null, 2));
console.log(r.verdict);
process.exit(r.verdict === 'hardware PASS' ? 0 : 1);
