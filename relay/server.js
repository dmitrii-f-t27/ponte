'use strict';

// ponte-relay: a blind WebSocket relay for Ponte's "Russians hear each other" link.
// Members of /r/<room> exchange binary frames. Every binary frame from one member
// goes, unchanged, to every other open member of the same room. Clients encrypt
// end to end, so the relay never parses, stores or logs a payload or a room id.

const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');

const ROOM_PATH = /^\/r\/([0-9a-f]{64})$/;
const MAX_PAYLOAD = 65536; // bytes per message
const MAX_MEMBERS = 6; // per room; the next one gets ROOM_FULL
const ROOM_FULL = 4001; // close code
const RATE_LIMIT = 200; // messages per second per connection; excess is dropped
const RATE_WINDOW_MS = 1000;
const PING_INTERVAL_MS = 20000;
const STATS_INTERVAL_MS = 60000;
const MAX_BUFFERED = 64 * 1024; // a receiver this far behind (about 2 s of voice) skips frames: late audio is useless
const MAX_CONNECTIONS = 1000; // across all rooms
const MAX_ROOMS = 300;
const MAX_PER_ADDRESS = 12; // connections from one client address
const SERVER_FULL = 4002; // close code: the relay itself is full

function noop() {}

function rejectUpgrade(socket, status, text) {
  socket.on('error', noop);
  if (!socket.writable) {
    socket.destroy();
    return;
  }
  socket.once('finish', () => socket.destroy());
  socket.end(
    `HTTP/1.1 ${status} ${text}\r\n` +
      'Connection: close\r\n' +
      'Content-Type: text/plain\r\n' +
      `Content-Length: ${Buffer.byteLength(text)}\r\n` +
      '\r\n' +
      text
  );
}

/**
 * Starts the relay. Resolves with { port, server, stats, close } once it listens.
 * port 0 picks a free port. options.pingIntervalMs, maxPerAddress, maxConnections and log exist for tests.
 */
function start(port = 0, options = {}) {
  const pingIntervalMs = options.pingIntervalMs ?? PING_INTERVAL_MS;
  const maxPerAddress = options.maxPerAddress ?? MAX_PER_ADDRESS;
  const maxConnections = options.maxConnections ?? MAX_CONNECTIONS;
  const log = options.log ?? ((line) => console.log(line));
  const rooms = new Map(); // room id -> Set of peers
  const perAddress = new Map(); // client address -> open connections

  // The client address as Railway's proxy reports it (the last hop it added), else the socket's.
  function clientAddress(req) {
    const forwarded = String(req.headers['x-forwarded-for'] || '').split(',').map((s) => s.trim()).filter(Boolean);
    return forwarded.length ? forwarded[forwarded.length - 1] : req.socket.remoteAddress || '?';
  }

  // Tells every member how many connections the room has (the only plain text the relay sends): a client that
  // sees more connections than Pontes that announced themselves knows someone listens silently.
  function announce(members) {
    const note = JSON.stringify({ members: members.size });
    for (const other of members) {
      if (other.ws.readyState === WebSocket.OPEN) other.ws.send(note);
    }
  }

  function stats() {
    let connections = 0;
    for (const members of rooms.values()) connections += members.size;
    return { connections, rooms: rooms.size };
  }

  const server = http.createServer((req, res) => {
    if ((req.method === 'GET' || req.method === 'HEAD') && req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
      res.end('ok');
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
  });

  const wss = new WebSocketServer({
    noServer: true,
    clientTracking: false,
    maxPayload: MAX_PAYLOAD,
    perMessageDeflate: false,
  });

  server.on('upgrade', (req, socket, head) => {
    const match = ROOM_PATH.exec(req.url || '');
    if (!match) {
      rejectUpgrade(socket, 400, 'Bad Request');
      return;
    }
    const address = clientAddress(req);
    wss.handleUpgrade(req, socket, head, (ws) => join(ws, match[1], address));
  });

  function join(ws, roomId, address) {
    ws.on('error', noop);
    let members = rooms.get(roomId);
    if (members && members.size >= MAX_MEMBERS) {
      ws.close(ROOM_FULL, 'room full');
      return;
    }
    const total = stats();
    if (total.connections >= maxConnections || (!members && total.rooms >= MAX_ROOMS) ||
        (perAddress.get(address) || 0) >= maxPerAddress) {
      ws.close(SERVER_FULL, 'relay full');
      return;
    }
    if (!members) {
      members = new Set();
      rooms.set(roomId, members);
    }
    perAddress.set(address, (perAddress.get(address) || 0) + 1);
    const peer = { ws, alive: true, windowStart: 0, count: 0 };
    members.add(peer);
    announce(members);

    ws.on('pong', () => {
      peer.alive = true;
    });

    ws.on('message', (data, isBinary) => {
      const now = Date.now();
      if (now - peer.windowStart >= RATE_WINDOW_MS) {
        peer.windowStart = now;
        peer.count = 0;
      }
      if (++peer.count > RATE_LIMIT) return;
      if (!isBinary) return;
      for (const other of members) {
        if (other === peer) continue;
        if (other.ws.readyState !== WebSocket.OPEN) continue;
        if (other.ws.bufferedAmount > MAX_BUFFERED) continue;
        other.ws.send(data, { binary: true });
      }
    });

    ws.on('close', () => {
      members.delete(peer);
      const left = (perAddress.get(address) || 1) - 1;
      if (left > 0) perAddress.set(address, left);
      else perAddress.delete(address);
      if (members.size === 0 && rooms.get(roomId) === members) rooms.delete(roomId);
      else announce(members);
    });
  }

  const pingTimer = setInterval(() => {
    for (const members of rooms.values()) {
      for (const peer of members) {
        if (!peer.alive) {
          peer.ws.terminate();
          continue;
        }
        peer.alive = false;
        if (peer.ws.readyState === WebSocket.OPEN) peer.ws.ping();
      }
    }
  }, pingIntervalMs);
  pingTimer.unref();

  let lastLine = 'connections=0 rooms=0';
  const statsTimer = setInterval(() => {
    const { connections, rooms: roomCount } = stats();
    const line = `connections=${connections} rooms=${roomCount}`;
    if (line !== lastLine) {
      lastLine = line;
      log(line);
    }
  }, STATS_INTERVAL_MS);
  statsTimer.unref();

  function close() {
    clearInterval(pingTimer);
    clearInterval(statsTimer);
    for (const members of rooms.values()) {
      for (const peer of members) peer.ws.terminate();
    }
    rooms.clear();
    perAddress.clear();
    return new Promise((resolve) => {
      server.close(() => resolve());
      server.closeAllConnections();
    });
  }

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, () => {
      server.off('error', reject);
      resolve({ port: server.address().port, server, stats, close });
    });
  });
}

module.exports = { start };

if (require.main === module) {
  const port = Number(process.env.PORT) || 8080;
  start(port).then(
    (relay) => {
      console.log(`ponte-relay listening on port ${relay.port}`);
      const stop = () => relay.close().then(() => process.exit(0));
      process.once('SIGTERM', stop);
      process.once('SIGINT', stop);
    },
    (err) => {
      console.error(`ponte-relay failed to start: ${err.code || err.message}`);
      process.exit(1);
    }
  );
}
