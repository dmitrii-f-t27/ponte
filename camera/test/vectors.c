// Native side of camera/test/wasm-vectors.mjs: reads cases from stdin and prints the spec's results as float bit
// patterns, so the WebAssembly build of the same C can be compared bit for bit.
//   c b c sh w sat            -> cm_color_params (13 floats)
//   p b c sh w sat r g b      -> cm_apply_pixel, r g b given as float bits in hex (3 floats)
//   f zoom px py mirror       -> cm_crop (4 floats)
#include <stdio.h>
#include <string.h>
#include "camera_rules.h"

static void put(const float *v, int n) {
    for (int i = 0; i < n; i++) { uint32_t u; memcpy(&u, &v[i], 4); printf(i ? " %08x" : "%08x", u); }
    printf("\n");
}

int main(void) {
    char kind;
    while (scanf(" %c", &kind) == 1) {
        float out[16] = {0};
        if (kind == 'c') {
            long long b, c, sh, w, sat;
            if (scanf("%lld %lld %lld %lld %lld", &b, &c, &sh, &w, &sat) != 5) return 1;
            put(out, (int)cm_color_params(b, c, sh, w, sat, out));
        } else if (kind == 'p') {
            long long b, c, sh, w, sat; unsigned r, g, bl; float fr, fg, fb;
            if (scanf("%lld %lld %lld %lld %lld %x %x %x", &b, &c, &sh, &w, &sat, &r, &g, &bl) != 8) return 1;
            memcpy(&fr, &r, 4); memcpy(&fg, &g, 4); memcpy(&fb, &bl, 4);
            cm_apply_pixel(b, c, sh, w, sat, fr, fg, fb, out);
            put(out, 3);
        } else if (kind == 'f') {
            long long z, px, py, m;
            if (scanf("%lld %lld %lld %lld", &z, &px, &py, &m) != 4) return 1;
            put(out, (int)cm_crop(z, px, py, m, out));
        } else return 1;
    }
    return 0;
}
