// Native side of camera/test/wasm-vectors.mjs: reads cases from stdin and prints the spec's results (floats as bit
// patterns), so the WebAssembly build of the same C can be compared bit for bit.
//   c b c sh w sat            -> cm_color_params (13 floats)
//   p b c sh w sat r g b      -> cm_apply_pixel, r g b given as float bits in hex (3 floats)
//   f zoom px py mirror       -> cm_crop (4 floats)
//   r state needs due sized   -> cm_trk_route
//   s state event usable      -> cm_trk_step_state, cm_trk_step_action
//   b state                   -> cm_trk_bucket
//   u variant ci              -> cm_render_usable, cm_render_variant_held, cm_render_first (variant as the last good)
//   x variant fails stage proven ci -> cm_render_next_variant, _next_fails, _retry_ms, _next_state
//   d reason since fail pages -> cm_dial_wait_ms, cm_dial_delay_ms (fail, pages), cm_dial_failures_after (fail, 0 / 1)
//   l lis fail cl pr pa tr    -> cm_link_panel, cm_link_cameras (pr)
//   k kind n b0 .. b(n-1)     -> cm_report_clean (hex bytes in and out), cm_report_stage (n)
//   g since                   -> cm_page_lease_left_ms
//   v version has troubled    -> cm_link_version_taken (version), cm_report_error_rank (has, troubled)
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
        } else if (kind == 'r') {
            long long s; int n, d, z;
            if (scanf("%lld %d %d %d", &s, &n, &d, &z) != 4) return 1;
            printf("%lld\n", (long long)cm_trk_route(s, n, d, z));
        } else if (kind == 's') {
            long long s, e; int u;
            if (scanf("%lld %lld %d", &s, &e, &u) != 3) return 1;
            printf("%lld %lld\n", (long long)cm_trk_step_state(s, e, u), (long long)cm_trk_step_action(s, e, u));
        } else if (kind == 'b') {
            long long s;
            if (scanf("%lld", &s) != 1) return 1;
            printf("%lld\n", (long long)cm_trk_bucket(s));
        } else if (kind == 'u') {
            long long v; int ci;
            if (scanf("%lld %d", &v, &ci) != 2) return 1;
            printf("%d %lld %lld\n", cm_render_usable(v, ci) ? 1 : 0, (long long)cm_render_variant_held(v),
                   (long long)cm_render_first(v, ci));
        } else if (kind == 'x') {
            long long v, f, st; int pr, ci;
            if (scanf("%lld %lld %lld %d %d", &v, &f, &st, &pr, &ci) != 5) return 1;
            printf("%lld %lld %lld %lld\n", (long long)cm_render_next_variant(v, f, st, pr, ci),
                   (long long)cm_render_next_fails(v, f, st, pr, ci), (long long)cm_render_retry_ms(v, f, st, pr, ci),
                   (long long)cm_render_next_state(v, f, st, pr, ci));
        } else if (kind == 'd') {
            long long r, since, f, pages;
            if (scanf("%lld %lld %lld %lld", &r, &since, &f, &pages) != 4) return 1;
            printf("%lld %lld %lld %lld\n", (long long)cm_dial_wait_ms(r, since, f, pages),
                   (long long)cm_dial_delay_ms(f, pages), (long long)cm_dial_failures_after(f, false),
                   (long long)cm_dial_failures_after(f, true));
        } else if (kind == 'l') {
            int lis, fail; long long cl, pr, pa, tr;
            if (scanf("%d %d %lld %lld %lld %lld", &lis, &fail, &cl, &pr, &pa, &tr) != 6) return 1;
            printf("%lld %lld\n", (long long)cm_link_panel(lis, fail, cl, pr, pa, tr), (long long)cm_link_cameras(pr));
        } else if (kind == 'k') {
            long long k, n; uint8_t text[256] = {0};
            if (scanf("%lld %lld", &k, &n) != 2 || n < 0 || n > 256) return 1;
            for (long long i = 0; i < n; i++) { unsigned v; if (scanf("%x", &v) != 1) return 1; text[i] = (uint8_t)v; }
            long long m = (long long)cm_report_clean(text, n, k);
            printf("%lld", m);
            for (long long i = 0; i < m; i++) printf(" %02x", text[i]);
            printf(" %lld\n", (long long)cm_report_stage(n));
        } else if (kind == 'g') {
            long long since;
            if (scanf("%lld", &since) != 1) return 1;
            printf("%lld\n", (long long)cm_page_lease_left_ms(since));
        } else if (kind == 'v') {
            long long v; int has, troubled;
            if (scanf("%lld %d %d", &v, &has, &troubled) != 3) return 1;
            printf("%d %lld\n", cm_link_version_taken(v) ? 1 : 0, (long long)cm_report_error_rank(has, troubled));
        } else return 1;
    }
    return 0;
}
