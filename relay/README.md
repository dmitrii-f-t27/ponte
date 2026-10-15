# ponte-relay

A blind WebSocket relay for Ponte's "Russians hear each other" link: Russian speakers on the same call hear each other's own voices, with no translation. The relay only moves bytes. Clients encrypt end to end, and the server never parses, stores or logs payloads or room ids.

**Protocol.** Connect to `wss://<host>/r/<room>`, where `<room>` is a SHA-256 digest as exactly 64 lowercase hex characters. Every binary frame a member sends goes, unchanged, to every other open member of that room, never back to the sender. Text frames from clients are ignored. The relay itself sends one text frame `{"members":n}` to every member when someone joins or leaves, so the clients can see a connection that never announced itself. Any other upgrade path gets HTTP 400. `GET /healthz` and `HEAD /healthz` return `ok` (200); any other method or path gets 404. Derive the room id and the encryption key separately from the shared secret: the relay and the host's request logs see the room id.

**Limits.**
- 65536 bytes per frame. A larger frame closes the sender with code 1009.
- 6 members per room. The 7th is closed with code 4001. Ponte tries again 15 s later: the seat of a Mac that slept frees within two pings.
- 1000 connections and 300 rooms in all, 12 connections from one address. Past these, a new connection is closed with code 4002.
- 200 frames per second per connection. Excess frames are dropped silently.
- A ping every 10 s. A connection that misses a pong is terminated. A receiver more than 64 KiB behind (about 2 s of voice) skips frames.
- Empty rooms are deleted. The log has one `connections=N rooms=M` line at most once a minute, only when the counts change.

**Rules.** Every decision and limit above is written in t27 (`Specs/relay_rules.t27` in the Ponte repository), compiled to C and built to `rl.wasm` by `build-wasm.sh` (needs the repository and zig). `rules.js` runs `rl.wasm`; `server.js` only carries the answers out with `node:http` and `ws`. `rl.wasm` is committed, so `npm start` and Railway need neither t27c nor zig. `npm test` also compares the spec with the rules the JavaScript held before 2026-10-15.

**Run.** Node.js 20 or later: `npm install`, then `npm start` (port from `PORT`, default 8080). `npm test` runs the self-test.

**Deploy on Railway.** From this folder, after `railway login`: `railway init` creates the project, `railway up` builds and deploys it (Railway sets `PORT`), `railway domain` gives the public `*.up.railway.app` address. Point Ponte at `wss://<domain>/r/<room>`. Set the health check path to `/healthz`.

Dmitrii Fedorov ([@dmitrii-f-t27](https://github.com/dmitrii-f-t27))
