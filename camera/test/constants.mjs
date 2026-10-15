// The numbers the JavaScript writes by hand are the spec's: every `<number>; // CM_NAME` or `<number>, // RL_NAME` in
// the extension and the relay must equal that #define in the C t27c generated (Sources/PonteSpecs/*.h).
//   node camera/test/constants.mjs
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const defines = new Map();
for (const header of ['camera_rules.h', 'relay_rules.h']) {
  const text = readFileSync(join(root, 'Sources', 'PonteSpecs', header), 'utf8');
  for (const [, name, value] of text.matchAll(/^#define ((?:CM|RL)_[A-Z0-9_]+) (-?[0-9.]+)$/gm)) defines.set(name, Number(value));
}
// The files and how many spec numbers each must name at least (so a reformatted file cannot pass by matching none).
const files = [['camera/extension/page.js', 31], ['camera/extension/sw.js', 7], ['camera/extension/policy.js', 11],
  ['camera/extension/bridge.js', 1], ['relay/rules.js', 17]];
let bad = 0, checked = 0;
for (const [file, least] of files) {
  const text = readFileSync(join(root, file), 'utf8');
  let found = 0;
  for (const [, value, name] of text.matchAll(/(-?\d+)\s*[;,]\s*\/\/\s*((?:CM|RL)_[A-Z0-9_]+)/g)) {
    found += 1;
    if (!defines.has(name)) { bad += 1; console.log(`FAIL ${file}: ${name} is not in the generated C`); continue; }
    if (defines.get(name) !== Number(value)) { bad += 1; console.log(`FAIL ${file}: ${name} = ${value}, the spec says ${defines.get(name)}`); }
  }
  checked += found;
  if (found < least) { bad += 1; console.log(`FAIL ${file}: ${found} spec numbers found, at least ${least} expected`); }
}
console.log(`${checked} constants checked against ${defines.size} defines, ${bad} problems`);
process.exit(bad === 0 ? 0 : 1);
