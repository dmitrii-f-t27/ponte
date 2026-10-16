// The extension's WebAssembly (camera/extension/cm.wasm) against the same C compiled natively (camera/test/vectors.c),
// bit for bit, over seeded random settings, pixels and frames.   node camera/test/wasm-vectors.mjs
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const work = mkdtempSync(join(tmpdir(), 'cmvec-'));
execFileSync('xcrun', ['clang', '-std=c11', '-O2', '-ffp-contract=off', '-Wno-parentheses-equality', '-DNDEBUG',
  '-I', join(root, 'Sources/PonteSpecs'), join(root, 'camera/test/vectors.c'), '-o', join(work, 'vectors')]);

const { instance } = await WebAssembly.instantiate(readFileSync(join(root, 'camera/extension/cm.wasm')), {});
const x = instance.exports;
x._initialize?.();
const f32 = () => new Float32Array(x.memory.buffer, x.cm_wasm_floats(), 16);
const u32 = () => new Uint32Array(x.memory.buffer, x.cm_wasm_floats(), 16);
const hex = (n) => Array.from(u32().slice(0, n), (u) => u.toString(16).padStart(8, '0')).join(' ');

let state = 0x5eedn;
const next = () => { state = (state + 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn; let z = state;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & 0xffffffffffffffffn; z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & 0xffffffffffffffffn;
  return z ^ (z >> 31n); };
const int = (lo, hi) => lo + Number(next() % BigInt(hi - lo + 1));
const edges = [-1000, -101, -100, -1, 0, 1, 99, 100, 101, 299, 300, 301, 1000];
const setting = () => (int(0, 3) === 0 ? edges[int(0, edges.length - 1)] : int(-110, 110));
const bits = new Uint32Array(1), asFloat = new Float32Array(bits.buffer);
const channel = () => { switch (int(0, 3)) { case 0: bits[0] = Number(next() & 0xffffffffn); break;
  case 1: asFloat[0] = int(0, 255) / 255; break; default: asFloat[0] = int(-200, 1200) / 1000; } return bits[0]; };

const input = [], wasm = [];
const big = (v) => BigInt(v);
for (let i = 0; i < 40000; i++) {
  const s = [setting(), setting(), setting(), setting(), setting()];
  input.push(`c ${s.join(' ')}`);
  const n = Number(x.cm_color_params(...s.map(big), x.cm_wasm_floats()));
  wasm.push(hex(n));
  const rgb = [channel(), channel(), channel()];
  input.push(`p ${s.join(' ')} ${rgb.map((u) => u.toString(16)).join(' ')}`);
  const fl = rgb.map((u) => { bits[0] = u; return asFloat[0]; });
  x.cm_apply_pixel(...s.map(big), ...fl, x.cm_wasm_floats());
  wasm.push(hex(3));
  const fr = [int(-50, 450), setting(), setting(), int(-1, 2)];
  input.push(`f ${fr.join(' ')}`);
  const m = Number(x.cm_crop(...fr.map(big), x.cm_wasm_floats()));
  wasm.push(hex(m));
}
// The pipeline, the link and the report (version 2): every value of their small domains, with values just outside.
const B = BigInt, n = Number;
const around = (count) => Array.from({ length: count + 4 }, (_, i) => i - 2);
for (const s of around(6)) for (let needs = 0; needs < 2; needs++) for (let due = 0; due < 2; due++) for (let z = 0; z < 2; z++) {
  input.push(`r ${s} ${needs} ${due} ${z}`);
  wasm.push(`${n(x.cm_trk_route(B(s), needs, due, z))}`);
}
for (const s of around(6)) for (const e of around(6)) for (let u = 0; u < 2; u++) {
  input.push(`s ${s} ${e} ${u}`);
  wasm.push(`${n(x.cm_trk_step_state(B(s), B(e), u))} ${n(x.cm_trk_step_action(B(s), B(e), u))}`);
}
for (const s of around(6)) {
  input.push(`b ${s}`);
  wasm.push(`${n(x.cm_trk_bucket(B(s)))}`);
}
for (const v of around(3)) for (let ci = 0; ci < 2; ci++) {
  input.push(`u ${v} ${ci}`);
  wasm.push(`${x.cm_render_usable(B(v), ci)} ${n(x.cm_render_variant_held(B(v)))} ${n(x.cm_render_first(B(v), ci))}`);
}
for (const v of around(3)) for (const f of around(3)) for (const st of around(8)) for (let pr = 0; pr < 2; pr++)
  for (let ci = 0; ci < 2; ci++) {
  input.push(`x ${v} ${f} ${st} ${pr} ${ci}`);
  const a = [B(v), B(f), B(st), pr, ci];
  wasm.push(`${n(x.cm_render_next_variant(...a))} ${n(x.cm_render_next_fails(...a))} ${n(x.cm_render_retry_ms(...a))} ${n(x.cm_render_next_state(...a))}`);
}
const sinces = [-5, -1, 0, 1, 499, 500, 999, 1000, 1001, 29999, 30000, 299999, 300000, 300001, 9007199254740991];
for (const r of around(5)) for (const since of sinces) for (const f of [-3, -1, ...around(36), 1000, 9007199254740991]) for (const pages of [-1, 0, 1, 7]) {
  input.push(`d ${r} ${since} ${f} ${pages}`);
  wasm.push(`${n(x.cm_dial_wait_ms(B(r), B(since), B(f), B(pages)))} ${n(x.cm_dial_delay_ms(B(f), B(pages)))} ${n(x.cm_dial_failures_after(B(f), 0))} ${n(x.cm_dial_failures_after(B(f), 1))}`);
}
const counts = [-2, -1, 0, 1, 2, 16, 17, 99];
for (let lis = 0; lis < 2; lis++) for (let fail = 0; fail < 2; fail++) for (const cl of [-1, 0, 1, 4])
  for (const pr of counts) for (const pa of counts) for (const tr of counts) {
    input.push(`l ${lis} ${fail} ${cl} ${pr} ${pa} ${tr}`);
    wasm.push(`${n(x.cm_link_panel(lis, fail, B(cl), B(pr), B(pa), B(tr)))} ${n(x.cm_link_cameras(B(pr)))}`);
  }
const bytesBuffer = () => new Uint8Array(x.memory.buffer, x.cm_wasm_bytes(), 256);
for (let i = 0; i < 3000; i++) {
  const kind = int(-1, 2);
  const len = i < 257 ? i : int(0, 256);
  const text = Array.from({ length: len }, () => (int(0, 2) === 0 ? int(0, 255) : int(32, 126)));
  input.push(`k ${kind} ${len}${text.map((v) => ` ${v.toString(16)}`).join('')}`);
  bytesBuffer().fill(0);
  bytesBuffer().set(text);
  const m = n(x.cm_report_clean(x.cm_wasm_bytes(), B(len), B(kind)));
  const kept = Array.from(bytesBuffer().slice(0, m), (v) => ` ${v.toString(16).padStart(2, '0')}`).join('');
  wasm.push(`${m}${kept} ${n(x.cm_report_stage(B(len)))}`);
}
// The pages' lease: around 0, the lease and the ends of the range (wall-clock ages, so JavaScript's safe integers).
for (const since of [-9007199254740991, -90001, -90000, -89999, -1, 0, 1, 19999, 20000, 89999, 90000, 90001,
  9007199254740991, ...Array.from({ length: 200 }, () => int(-100000, 100000))]) {
  input.push(`g ${since}`);
  wasm.push(`${n(x.cm_page_lease_left_ms(B(since)))}`);
}
for (const v of [-1, 0, 1, 2, 3, 9007199254740991]) for (let has = 0; has < 2; has++) for (let tr = 0; tr < 2; tr++) {
  input.push(`v ${v} ${has} ${tr}`);
  wasm.push(`${x.cm_link_version_taken(B(v))} ${n(x.cm_report_error_rank(has, tr))}`);
}
// The choice among reports and the pagehide rule (0.1.15): every rank pair with values just outside, every flag.
for (const rank of around(3)) for (const best of around(3)) for (let newer = 0; newer < 2; newer++) {
  input.push(`t ${rank} ${best} ${newer}`);
  wasm.push(`${x.cm_report_error_takes(B(rank), B(best), newer)}`);
}
for (let has = 0; has < 2; has++) for (let same = 0; same < 2; same++) for (let named = 0; named < 2; named++) {
  input.push(`o ${has} ${same} ${named}`);
  wasm.push(`${x.cm_page_gone_forgets(has, same, named)}`);
}

writeFileSync(join(work, 'in.txt'), input.join('\n') + '\n');
const native = execFileSync(join(work, 'vectors'), { input: readFileSync(join(work, 'in.txt')), maxBuffer: 1 << 28 })
  .toString().trim().split('\n');
let bad = 0;
for (let i = 0; i < wasm.length; i++) {
  if (native[i] !== wasm[i]) { if (bad++ < 5) console.log(`MISMATCH ${input[i]}\n  native ${native[i]}\n  wasm   ${wasm[i]}`); }
}
console.log(`${wasm.length} cases, ${bad} mismatches`);

// The JavaScript the 0.1.15 rules replaced (sw.js totals and pagehide, page.js report), as it was written, against
// cm.wasm over their whole domains: the move changed no answer.
let legacyCases = 0, legacyBad = 0;
const legacy = (got, want, what) => { legacyCases += 1; if (got !== want && legacyBad++ < 5) console.log(`LEGACY ${what}: wasm ${got}, before ${want}`); };
for (let rank = 0; rank < 3; rank++) for (let best = 0; best < 3; best++) for (const [at, bestAt] of [[5, 4], [4, 4], [4, 5], [undefined, -1]]) {
  // sw.js: rank > t.rank || (rank > 0 && rank === t.rank && p.errorAt > t.at)
  const sw = rank > best || (rank > 0 && rank === best && at > bestAt);
  legacy(x.cm_report_error_takes(B(rank), B(best), at > bestAt ? 1 : 0) !== 0, sw, `sw ${rank} ${best} ${at} ${bestAt}`);
  // page.js and CameraLink: r > best (no times)
  legacy(x.cm_report_error_takes(B(rank), B(best), 0) !== 0, rank > best, `page ${rank} ${best}`);
}
for (const old of [undefined, { doc: 'a' }, { doc: 'b' }, { doc: null }, {}]) for (const doc of ['a', null]) {
  // sw.js: old && (old.doc === doc || old.doc == null)
  const before = !!(old && (old.doc === doc || old.doc == null));
  legacy(x.cm_page_gone_forgets(old ? 1 : 0, old && old.doc === doc ? 1 : 0, old?.doc != null ? 1 : 0) !== 0, before,
    `gone ${JSON.stringify(old)} ${doc}`);
}
console.log(`${legacyCases} cases against the replaced JavaScript, ${legacyBad} mismatches`);
process.exit(bad === 0 && legacyBad === 0 && native.length === wasm.length ? 0 : 1);
