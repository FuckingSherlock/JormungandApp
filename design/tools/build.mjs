// Builds design/main_screen.html from design/src/.
//   node design/tools/build.mjs          build once
//   node design/tools/build.mjs --check  fail if main_screen.html is out of date
//
// src/index.html is the page skeleton. A line that is only
//   /* @include css/ */   or   <!-- @include markup/10-home.html -->
// is replaced by that file, or by every file in that folder in name order
// (the numeric prefixes set the order). {{geo.name}} is replaced with an SVG
// path from tools/geometry.mjs.
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { geometry } from './geometry.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'src');
const out = join(root, 'main_screen.html');

function include(rel) {
  const p = join(src, rel);
  if (statSync(p).isDirectory()) {
    return readdirSync(p).filter(f => !f.startsWith('.')).sort().map(f => readFileSync(join(p, f), 'utf8')).join('');
  }
  return readFileSync(p, 'utf8');
}

const INCLUDE = /^[ \t]*(?:\/\*|<!--)[ \t]*@include[ \t]+(\S+)[ \t]*(?:\*\/|-->)[ \t]*\r?\n/gm;
let html = readFileSync(join(src, 'index.html'), 'utf8').replace(INCLUDE, (_, rel) => include(rel));

const geo = geometry();
html = html.replace(/\{\{geo\.(\w+)\}\}/g, (_, k) => {
  if (!(k in geo)) throw new Error('unknown geometry key: ' + k);
  return geo[k];
});

if (process.argv.includes('--check')) {
  const cur = existsSync(out) ? readFileSync(out, 'utf8') : '';
  if (cur !== html) { console.error('main_screen.html is out of date — run: node design/tools/build.mjs'); process.exit(1); }
  console.log('main_screen.html is up to date');
} else {
  writeFileSync(out, html);
  console.log('built design/main_screen.html (' + html.split('\n').length + ' lines)');
}
