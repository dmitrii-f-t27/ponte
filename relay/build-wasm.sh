#!/bin/zsh
# Builds relay/rl.wasm from the C the relay spec generates (Sources/PonteSpecs/relay_rules.h), so relay/server.js
# runs the decisions of Specs/relay_rules.t27. Needs zig (ZIG, default ~/local/zig/zig). rl.wasm is committed:
# Railway runs `npm start` from this folder and never needs t27c, zig or the rest of the repository.
#   relay/build-wasm.sh
# -DNDEBUG drops the spec tests' asserts (they run in Specs/generate.sh); only the functions below are exported.
set -euo pipefail
ROOT="${0:A:h:h}"
ZIG="${ZIG:-$HOME/local/zig/zig}"
EXPORTS=(rl_limit rl_hex_digit rl_room_path rl_health_path rl_http_method rl_http_status rl_admit rl_forwarded_hop
         rl_window_restarts rl_rate_allows rl_forwards rl_forward_to rl_ping_action rl_left_action
         rl_address_after_leave rl_wasm_bytes)
FLAGS=()
for E in $EXPORTS; do FLAGS+=("-Wl,--export=$E"); done
"$ZIG" cc --target=wasm32-wasi -mexec-model=reactor -O2 -DNDEBUG -ffp-contract=off -std=c11 -Wno-parentheses-equality \
  -I "$ROOT/Sources/PonteSpecs" -Wl,--no-entry -Wl,--gc-sections $FLAGS \
  "$ROOT/relay/wasm/rl_wasm.c" -o "$ROOT/relay/rl.wasm"
print "relay/rl.wasm: $(/usr/bin/stat -f %z "$ROOT/relay/rl.wasm") bytes"
