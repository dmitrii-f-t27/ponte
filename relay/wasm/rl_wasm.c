// ponte-relay: the C that Specs/relay_rules.t27 compiles to (Sources/PonteSpecs/relay_rules.h), built to WebAssembly
// by relay/build-wasm.sh for relay/server.js. Only a buffer is added here: JavaScript passes a path or a method
// through it, the decisions are the spec's.
#include "relay_rules.h"

static uint8_t rl_wasm_u8[256];

// The scratch buffer server.js writes a request path or method into (the text of rl_room_path, rl_health_path,
// rl_http_method).
uint8_t *rl_wasm_bytes(void) { return rl_wasm_u8; }
