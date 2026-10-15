#!/bin/zsh
# Builds camera/extension/cm.wasm from the C the camera spec generates (Sources/PonteSpecs/camera_rules.h), so the
# extension runs the same decisions as Ponte and the tests. Needs zig (ZIG, default ~/local/zig/zig).
#   camera/build-wasm.sh
# -ffp-contract=off as everywhere the specs are compiled (no fused multiply-add: the same floats bit for bit);
# -DNDEBUG drops the spec tests' asserts (they run in Specs/generate.sh); only the functions below are exported.
set -euo pipefail
ROOT="${0:A:h:h}"
ZIG="${ZIG:-$HOME/local/zig/zig}"
EXPORTS=(cm_setting_min cm_setting_max cm_setting_default cm_clamp_setting cm_preset_sets cm_preset_value
         cm_color_identity cm_color_params cm_apply_pixel cm_frame_identity cm_crop cm_needs_processing
         cm_wasm_floats cm_wasm_bytes)
FLAGS=()
for E in $EXPORTS; do FLAGS+=("-Wl,--export=$E"); done
"$ZIG" cc --target=wasm32-wasi -mexec-model=reactor -O2 -DNDEBUG -ffp-contract=off -std=c11 -Wno-parentheses-equality \
  -I "$ROOT/Sources/PonteSpecs" -Wl,--no-entry -Wl,--gc-sections $FLAGS \
  "$ROOT/camera/wasm/cm_wasm.c" -o "$ROOT/camera/extension/cm.wasm"
print "camera/extension/cm.wasm: $(/usr/bin/stat -f %z "$ROOT/camera/extension/cm.wasm") bytes"
