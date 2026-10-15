'use strict';

// ponte-relay: a blind WebSocket relay for Ponte's "Russians hear each other" link.
// Members of /r/<room> exchange binary frames. Every binary frame from one member
// goes, unchanged, to every other open member of the same room. Clients encrypt
// end to end, so the relay never parses, stores or logs a payload or a room id.
// Every decision and limit is Specs/relay_rules.t27 (rules.js runs it as rl.wasm);
// this file carries the decisions out with node:http and ws.

const http = require('node:http');
const { WebSocketServer, WebSocket } = require('ws');
const rules = require('./rules.js');

const { limits } = rules;

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
  const pingIntervalMs = options.pingIntervalMs ?? limits.PING_MS;
  const maxPerAddress = options.maxPerAddress ?? limits.PER_ADDRESS;
  const maxConnections = options.maxConnections ?? limits.CONNECTIONS;
  const log = options.log ?? ((line) => console.log(line));
  const rooms = new Map(); // room id -> Set of peers
  const perAddress = new Map(); // client address -> open connections

  // The client address as Railway's proxy reports it (the hop rl_forwarded_hop picks), else the socket's.
  function clientAddress(req) {
    const forwarded = String(req.headers['x-forwarded-for'] || '').split(',').map((s) => s.trim()).filter(Boolean);
    const hop = rules.forwardedHop(forwarded.length);
    return hop >= 0 ? forwarded[hop] : req.socket.remoteAddress || '?';
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
    const status = rules.httpStatus(req.method || '', req.url || '');
    if (status === 200) {
      res.writeHead(status, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
      res.end('ok');
      return;
    }
    res.writeHead(status, { 'Content-Type': 'text/plain' });
    res.end('not found');
  });

  const wss = new WebSocketServer({
    noServer: true,
    clientTracking: false,
    maxPayload: limits.MAX_PAYLOAD,
    perMessageDeflate: false,
  });

  server.on('upgrade', (req, socket, head) => {
    const url = req.url || '';
    if (!rules.roomPath(url)) {
      rejectUpgrade(socket, 400, 'Bad Request');
      return;
    }
    const address = clientAddress(req);
    wss.handleUpgrade(req, socket, head, (ws) => join(ws, url.slice(3), address));
  });

  function join(ws, roomId, address) {
    ws.on('error', noop);
    let members = rooms.get(roomId);
    const total = stats();
    const verdict = rules.admit(members ? members.size : 0, !!members, total.connections, total.rooms,
      perAddress.get(address) || 0, maxPerAddress, maxConnections);
    if (verdict !== rules.JOIN) {
      ws.close(verdict, verdict === limits.CLOSE_ROOM_FULL ? 'room full' : 'relay full');
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
      if (rules.windowRestarts(now, peer.windowStart)) {
        peer.windowStart = now;
        peer.count = 0;
      }
      peer.count += 1;
      if (!rules.rateAllows(peer.count)) return;
      if (!rules.forwards(isBinary)) return;
      for (const other of members) {
        if (!rules.forwardTo(other === peer, other.ws.readyState === WebSocket.OPEN, other.ws.bufferedAmount)) continue;
        other.ws.send(data, { binary: true });
      }
    });

    ws.on('close', () => {
      members.delete(peer);
      const left = rules.addressAfterLeave(perAddress.get(address) || 1);
      if (left > 0) perAddress.set(address, left);
      else perAddress.delete(address);
      if (rules.leftAction(members.size) === rules.LEFT_DELETE) {
        if (rooms.get(roomId) === members) rooms.delete(roomId);
      } else {
        announce(members);
      }
    });
  }

  const pingTimer = setInterval(() => {
    for (const members of rooms.values()) {
      for (const peer of members) {
        const action = rules.pingAction(peer.alive, peer.ws.readyState === WebSocket.OPEN);
        if (action === rules.PING_TERMINATE) {
          peer.ws.terminate();
          continue;
        }
        peer.alive = false;
        if (action === rules.PING_SEND) peer.ws.ping();
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
  }, limits.STATS_MS);
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

module.exports = { start, limits };

if (require.main === module) {
  const port = Number(process.env.PORT) || limits.PORT;
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
