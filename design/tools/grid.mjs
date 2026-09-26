// Glue a folder of shots into labelled grids, N per sheet (4 per row), at the shots' own
// resolution: node design/tools/grid.mjs <dir> [perSheet=8] [--scale 2]
// -> <dir>/grids/grid-01.png … (name order; files already named after their presets)
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(join(execSync('npm root -g').toString().trim(), 'playwright')); }

const args = process.argv.slice(2);
const scaleAt = args.indexOf('--scale');
const scale = scaleAt >= 0 ? +args[scaleAt + 1] : 2;
const [dirArg, perArg] = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));
const dir = resolve(dirArg || '.');
const per = +perArg || 8;
const files = readdirSync(dir).filter(f => f.endsWith('.png') && !f.includes('grid')).sort();
const out = join(dir, 'grids');
mkdirSync(out, { recursive: true });

const browser = await playwright.chromium.launch();
for (let i = 0; i < files.length; i += per) {
  const batch = files.slice(i, i + per);
  const page = await browser.newPage({ viewport: { width: 400 * Math.min(4, batch.length) + 8, height: 100 }, deviceScaleFactor: scale });
  await page.setContent(`<body style="margin:0;background:#000;display:flex;flex-wrap:wrap;gap:4px;padding:4px;width:${400 * 4 + 12}px;font:600 13px sans-serif;color:#fff">${
    batch.map(f => `<div style="width:400px"><div style="padding:2px 4px">${f.replace(/\.png$/, '')}</div><img style="display:block;width:400px" src="data:image/png;base64,${readFileSync(join(dir, f)).toString('base64')}"></div>`).join('')}</body>`);
  const file = join(out, `grid-${String(i / per + 1).padStart(2, '0')}.png`);
  await page.screenshot({ path: file, fullPage: true });
  await page.close();
  console.log(file);
}
await browser.close();
