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
writeFileSync(join(work, 'in.txt'), input.join('\n') + '\n');
const native = execFileSync(join(work, 'vectors'), { input: readFileSync(join(work, 'in.txt')), maxBuffer: 1 << 28 })
  .toString().trim().split('\n');
let bad = 0;
for (let i = 0; i < wasm.length; i++) {
  if (native[i] !== wasm[i]) { if (bad++ < 5) console.log(`MISMATCH ${input[i]}\n  native ${native[i]}\n  wasm   ${wasm[i]}`); }
}
console.log(`${wasm.length} cases, ${bad} mismatches`);
process.exit(bad === 0 && native.length === wasm.length ? 0 : 1);
