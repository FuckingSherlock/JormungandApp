// design/src/assets/TwemojiCountryFlags.woff2  ->  app/assets/fonts/TwemojiCountryFlags.ttf
//
// Flutter bundles TTF / OTF / TTC only (not WOFF2), so the mockup's font is converted once.
// The conversion needs the npm package `wawoff2` (WOFF2 decoder). The result is committed and
// only redone when the source changes (its sha1 is kept in TwemojiCountryFlags.ttf.src-sha1).
//
//   node app/tool/gen_assets.mjs
//   WAWOFF2_DIR=<dir with node_modules/wawoff2> node app/tool/gen_assets.mjs   (when the source changed)
//     one-time setup of such a dir:  mkdir %TEMP%\woff2conv && cd %TEMP%\woff2conv && npm init -y && npm i wawoff2
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { root } from './_util.mjs';

const src = join(root, 'design/src/assets/TwemojiCountryFlags.woff2');
const outDir = join(root, 'app/assets/fonts');
const ttf = join(outDir, 'TwemojiCountryFlags.ttf');
const stamp = ttf + '.src-sha1';

const bytes = readFileSync(src);
const sha = createHash('sha1').update(bytes).digest('hex');
if (existsSync(ttf) && existsSync(stamp) && readFileSync(stamp, 'utf8').trim() === sha) {
  console.log('gen_assets: flags font up to date');
  process.exit(0);
}

const dirs = [process.env.WAWOFF2_DIR, join(tmpdir(), 'woff2conv'), root].filter(Boolean);
let wawoff2;
for (const d of dirs) {
  try { wawoff2 = createRequire(join(d, 'noop.js'))('wawoff2'); break; } catch { /* next dir */ }
}
if (!wawoff2) {
  console.error('gen_assets: the flags font changed, but `wawoff2` is not installed (see the header of this file).');
  process.exit(1);
}
mkdirSync(outDir, { recursive: true });
const out = await wawoff2.decompress(bytes);
writeFileSync(ttf, Buffer.from(out));
writeFileSync(stamp, sha + '\n');
console.log(`gen_assets: flags font converted -> app/assets/fonts/TwemojiCountryFlags.ttf (${out.length} bytes)`);
