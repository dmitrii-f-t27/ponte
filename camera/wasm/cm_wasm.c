// Ponte Camera: the C that Specs/camera_rules.t27 compiles to (Sources/PonteSpecs/camera_rules.h), built to
// WebAssembly by camera/build-wasm.sh for the extension. Only buffers are added here: JavaScript passes arrays
// through these, the decisions are the spec's.
#include "camera_rules.h"

static float cm_wasm_f32[16];
static uint8_t cm_wasm_u8[256];

// The scratch buffers the extension reads and writes (out arrays of cm_color_params, cm_crop, cm_apply_pixel; the
// text cm_report_clean cleans in place).
float *cm_wasm_floats(void) { return cm_wasm_f32; }
uint8_t *cm_wasm_bytes(void) { return cm_wasm_u8; }
