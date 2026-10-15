'use strict';

// The relay's decisions: Specs/relay_rules.t27, compiled to C and built to rl.wasm by build-wasm.sh. This file only
// passes values to the WebAssembly and back (numbers as BigInt for the spec's i64, a path through its byte buffer).

const fs = require('node:fs');
const path = require('node:path');

const wasm = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(path.join(__dirname, 'rl.wasm'))), {});
const x = wasm.exports;
if (typeof x._initialize === 'function') x._initialize();

const PATH_MAX = 256; // RL_PATH_MAX
const encoder = new TextEncoder();

// The limits by key (RL_K_*).
const K = {
  PORT: 0, // RL_K_PORT
  MAX_PAYLOAD: 1, // RL_K_MAX_PAYLOAD
  ROOM_MEMBERS: 2, // RL_K_ROOM_MEMBERS
  CLOSE_ROOM_FULL: 3, // RL_K_CLOSE_ROOM_FULL
  CLOSE_SERVER_FULL: 4, // RL_K_CLOSE_SERVER_FULL
  CONNECTIONS: 5, // RL_K_CONNECTIONS
  ROOMS: 6, // RL_K_ROOMS
  PER_ADDRESS: 7, // RL_K_PER_ADDRESS
  RATE_LIMIT: 8, // RL_K_RATE_LIMIT
  RATE_WINDOW_MS: 9, // RL_K_RATE_WINDOW_MS
  PING_MS: 10, // RL_K_PING_MS
  STATS_MS: 11, // RL_K_STATS_MS
  MAX_BUFFERED: 12, // RL_K_MAX_BUFFERED
};

const limit = (key) => Number(x.rl_limit(BigInt(key)));
const limits = Object.fromEntries(Object.entries(K).map(([name, key]) => [name, limit(key)]));

const JOIN = 0; // RL_JOIN
const PING_TERMINATE = 0; // RL_PING_TERMINATE
const PING_SEND = 1; // RL_PING_SEND
const LEFT_DELETE = 0; // RL_LEFT_DELETE

// A text's UTF-8 bytes in the spec's buffer; the real length is passed, so a longer text matches nothing. Returns
// the rule's answer as a number.
function withBytes(text, rule) {
  const bytes = encoder.encode(String(text));
  const n = Math.min(bytes.length, PATH_MAX);
  new Uint8Array(x.memory.buffer, x.rl_wasm_bytes(), PATH_MAX).set(bytes.subarray(0, n));
  return Number(rule(x.rl_wasm_bytes(), BigInt(bytes.length)));
}
const withPath = (text, rule) => withBytes(text, rule) !== 0;
const healthPath = (url) => withPath(url, x.rl_health_path);
const httpMethod = (method) => withBytes(method, x.rl_http_method);

// An integer for the spec: a count or a time in milliseconds (never fractional, never beyond 2^53 here).
const int = (n) => BigInt(Math.trunc(Number(n) || 0));

module.exports = {
  limits,
  JOIN,
  PING_TERMINATE,
  PING_SEND,
  LEFT_DELETE,
  roomPath: (url) => withPath(url, x.rl_room_path),
  healthPath,
  httpMethod,
  // The answer to a plain HTTP request, from its method and path as node:http gives them.
  httpStatus: (method, url) => {
    const code = httpMethod(method);
    return Number(x.rl_http_status(BigInt(code), healthPath(url) ? 1 : 0));
  },
  admit: (roomMembers, roomExists, connections, rooms, fromAddress, perAddressMax, connectionsMax) =>
    Number(x.rl_admit(int(roomMembers), roomExists ? 1 : 0, int(connections), int(rooms), int(fromAddress),
      int(perAddressMax), int(connectionsMax))),
  forwardedHop: (count) => Number(x.rl_forwarded_hop(int(count))),
  windowRestarts: (nowMs, windowStartMs) => x.rl_window_restarts(int(nowMs), int(windowStartMs)) !== 0,
  rateAllows: (count) => x.rl_rate_allows(int(count)) !== 0,
  forwards: (isBinary) => x.rl_forwards(isBinary ? 1 : 0) !== 0,
  forwardTo: (isSender, open, buffered) => x.rl_forward_to(isSender ? 1 : 0, open ? 1 : 0, int(buffered)) !== 0,
  pingAction: (alive, open) => Number(x.rl_ping_action(alive ? 1 : 0, open ? 1 : 0)),
  leftAction: (membersAfter) => Number(x.rl_left_action(int(membersAfter))),
  addressAfterLeave: (open) => Number(x.rl_address_after_leave(int(open))),
};
