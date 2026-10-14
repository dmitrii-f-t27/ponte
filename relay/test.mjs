// Self-test for ponte-relay. Starts the server in-process on a random port,
// drives it with real WebSocket clients, prints PASS or FAIL and sets the exit code.
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import relayModule from './server.js';

const { start } = relayModule;

const results = [];
function check(name, ok, detail = '') {
  results.push(ok);
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(predicate, timeoutMs = 2000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    if (predicate()) return true;
    await sleep(10);
  }
  return predicate();
}

const room = () => randomBytes(32).toString('hex');

// Opens a client. Resolves once it is open, or with { status } if the upgrade is refused.
function connect(port, path, options = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`, options);
    const client = { ws, msgs: [], closeCode: null };
    client.closed = new Promise((done) => {
      ws.on('close', (code) => {
        client.closeCode = code;
        done(code);
      });
    });
    ws.on('message', (data, isBinary) => client.msgs.push({ data: Buffer.from(data), isBinary }));
    ws.on('error', () => {});
    ws.on('unexpected-response', (req, res) => {
      req.destroy();
      resolve({ status: res.statusCode });
    });
    ws.on('open', () => resolve(client));
    setTimeout(() => reject(new Error(`connect ${path} timed out`)), 3000).unref();
  });
}

const tagged = (clientObj, tag) => clientObj.msgs.filter((m) => m.data[0] === tag);

async function main() {
  const relay = await start(0, { log: () => {} });
  const { port } = relay;

  // HTTP
  const health = await fetch(`http://127.0.0.1:${port}/healthz`);
  check('GET /healthz -> 200 "ok"', health.status === 200 && (await health.text()) === 'ok');
  const other = await fetch(`http://127.0.0.1:${port}/`);
  await other.text();
  check('GET / -> 404', other.status === 404);

  // Bad upgrade paths
  const hex = room();
  const badPaths = [
    ['root', '/'],
    ['other path', '/x'],
    ['no room', '/r/'],
    ['short room', '/r/abc'],
    ['63 hex chars', `/r/${hex.slice(1)}`],
    ['65 hex chars', `/r/${hex}0`],
    ['uppercase hex', `/r/${hex.toUpperCase()}`],
    ['extra segment', `/r/${hex}/extra`],
    ['query string', `/r/${hex}?q=1`],
    ['wrong prefix', `/room/${hex}`],
  ];
  for (const [label, path] of badPaths) {
    const res = await connect(port, path);
    check(`upgrade with ${label} -> 400`, res.status === 400, res.status === 400 ? '' : `got ${res.status ?? 'open'}`);
    if (res.ws) res.ws.terminate();
  }

  // Three clients in room A, one in room B
  const roomA = room();
  const roomB = room();
  const a1 = await connect(port, `/r/${roomA}`);
  const a2 = await connect(port, `/r/${roomA}`);
  const a3 = await connect(port, `/r/${roomA}`);
  const b1 = await connect(port, `/r/${roomB}`);
  check('3 clients join room A, 1 joins room B', [a1, a2, a3, b1].every((c) => c.ws?.readyState === WebSocket.OPEN));
  await waitFor(() => relay.stats().connections === 4);
  check('server counts 4 connections in 2 rooms', relay.stats().connections === 4 && relay.stats().rooms === 2, JSON.stringify(relay.stats()));

  // Binary from a1 reaches a2 and a3 unchanged, never a1 or b1
  const p1 = Buffer.concat([Buffer.from([0x01]), randomBytes(1000)]);
  a1.ws.send(p1, { binary: true });
  await waitFor(() => tagged(a2, 0x01).length === 1 && tagged(a3, 0x01).length === 1);
  await sleep(150);
  check('a1 -> a2 forwarded unchanged', tagged(a2, 0x01).length === 1 && tagged(a2, 0x01)[0].data.equals(p1) && tagged(a2, 0x01)[0].isBinary);
  check('a1 -> a3 forwarded unchanged', tagged(a3, 0x01).length === 1 && tagged(a3, 0x01)[0].data.equals(p1) && tagged(a3, 0x01)[0].isBinary);
  check('no echo to the sender a1', tagged(a1, 0x01).length === 0);
  check('room B does not hear room A', tagged(b1, 0x01).length === 0);

  // Another direction
  const p2 = Buffer.from([0x02, 9, 8, 7]);
  a2.ws.send(p2, { binary: true });
  await waitFor(() => tagged(a1, 0x02).length === 1 && tagged(a3, 0x02).length === 1);
  await sleep(100);
  check('a2 -> a1 and a3, not back to a2', tagged(a1, 0x02).length === 1 && tagged(a3, 0x02).length === 1 && tagged(a2, 0x02).length === 0);

  // Room B alone: nobody hears it, no echo
  b1.ws.send(Buffer.from([0x03, 1]), { binary: true });
  await sleep(150);
  check('room A does not hear room B, no echo to b1', [a1, a2, a3, b1].every((c) => tagged(c, 0x03).length === 0));

  // Text frames are ignored
  const before = [a1, a2, a3, b1].map((c) => c.msgs.length);
  a2.ws.send('hello');
  await sleep(150);
  check('text frames are not forwarded', [a1, a2, a3, b1].every((c, i) => c.msgs.length === before[i]));

  // Rate limit: a3 sends 300 frames at once, others get 200
  for (let i = 0; i < 300; i++) a3.ws.send(Buffer.from([0x04, i & 0xff]), { binary: true });
  await waitFor(() => tagged(a1, 0x04).length >= 200 && tagged(a2, 0x04).length >= 200);
  await sleep(200);
  check('rate limit: 300 frames in a burst -> 200 forwarded', tagged(a1, 0x04).length === 200 && tagged(a2, 0x04).length === 200, `a1=${tagged(a1, 0x04).length} a2=${tagged(a2, 0x04).length}`);
  await sleep(1000);
  a3.ws.send(Buffer.from([0x05]), { binary: true });
  await waitFor(() => tagged(a1, 0x05).length === 1);
  check('rate limit window resets after 1 s', tagged(a1, 0x05).length === 1);

  // Payload limit: 65536 bytes pass, 65537 bytes close the sender with 1009
  const roomC = room();
  const c1 = await connect(port, `/r/${roomC}`);
  const c2 = await connect(port, `/r/${roomC}`);
  const big = Buffer.alloc(65536, 0x06);
  c1.ws.send(big, { binary: true });
  await waitFor(() => tagged(c2, 0x06).length === 1);
  check('65536-byte frame is forwarded', tagged(c2, 0x06).length === 1 && tagged(c2, 0x06)[0].data.length === 65536);
  c1.ws.send(Buffer.alloc(65537, 0x07), { binary: true });
  const tooBig = await Promise.race([c1.closed, sleep(2000).then(() => 'timeout')]);
  check('65537-byte frame closes the sender with 1009', tooBig === 1009, `got ${tooBig}`);
  await sleep(100);
  check('oversized frame is not forwarded', tagged(c2, 0x07).length === 0);
  c2.ws.close();

  // Capacity: room A has 3, add 3 more, the 7th gets 4001
  const extra = [];
  for (let i = 0; i < 3; i++) extra.push(await connect(port, `/r/${roomA}`));
  await sleep(100);
  check('members 4..6 join room A', extra.every((c) => c.ws?.readyState === WebSocket.OPEN));
  const a7 = await connect(port, `/r/${roomA}`);
  const fullCode = a7.status ? `http ${a7.status}` : await Promise.race([a7.closed, sleep(2000).then(() => 'timeout')]);
  check('7th member is closed with 4001', fullCode === 4001, `got ${fullCode}`);
  check('the 6 members stay open', [a1, a2, a3, ...extra].every((c) => c.ws.readyState === WebSocket.OPEN));
  const last = extra.pop();
  last.ws.close();
  await last.closed;
  await waitFor(() => relay.stats().connections === 6);
  const a8 = await connect(port, `/r/${roomA}`);
  await sleep(100);
  check('a freed seat can be taken again', a8.ws?.readyState === WebSocket.OPEN);

  // Empty rooms are deleted
  for (const c of [a1, a2, a3, b1, a8, ...extra]) c.ws.close();
  const emptied = await waitFor(() => relay.stats().connections === 0 && relay.stats().rooms === 0);
  check('rooms are deleted when empty', emptied, JSON.stringify(relay.stats()));
  await relay.close();

  // Heartbeat: a client that never answers pings is terminated
  const fast = await start(0, { log: () => {}, pingIntervalMs: 100 });
  const roomD = room();
  const silent = await connect(fast.port, `/r/${roomD}`, { autoPong: false });
  const lively = await connect(fast.port, `/r/${roomD}`);
  const silentCode = await Promise.race([silent.closed, sleep(2000).then(() => 'timeout')]);
  check('client that misses a pong is terminated', silentCode === 1006, `got ${silentCode}`);
  check('client that answers pings stays', lively.ws.readyState === WebSocket.OPEN);
  lively.ws.close();
  await fast.close();
}

const watchdog = setTimeout(() => {
  console.log('FAIL: test timed out');
  process.exit(1);
}, 30000);

main().then(
  () => {
    clearTimeout(watchdog);
    const failed = results.filter((ok) => !ok).length;
    if (failed === 0 && results.length > 0) {
      console.log(`PASS (${results.length} checks)`);
      process.exit(0);
    }
    console.log(`FAIL (${failed} of ${results.length} checks failed)`);
    process.exit(1);
  },
  (err) => {
    clearTimeout(watchdog);
    console.log(`FAIL: ${err.stack || err}`);
    process.exit(1);
  }
);
