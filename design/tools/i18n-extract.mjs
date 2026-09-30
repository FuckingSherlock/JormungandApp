// Lists the English UI strings of design/src (markup text + attributes, JS string literals) as
// candidates for the dictionary js/04-i18n-ru.js. `${expr}` becomes {0}, {1}…
//   node design/tools/i18n-extract.mjs            all candidates, one per line (sorted)
//   node design/tools/i18n-extract.mjs --missing  only those the dictionary does not have yet
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const src = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');
const out = new Map();   // text -> first file
const add = (s, f) => {
  s = s.replace(/\s+/g, ' ').trim();
  if (!s || !/[A-Za-z]{2}/.test(s)) return;
  if (!out.has(s)) out.set(s, f);
};

// ── HTML pieces (markup files, or a JS literal that carries tags) ──
function htmlPieces(html, f) {
  html = html.replace(/<!--[\s\S]*?-->/g, '');
  html = html.replace(/<(script|style)[\s\S]*?<\/\1>/g, '');
  for (const m of html.matchAll(/\b(?:title|placeholder|aria-label|alt)=(?:"([^"]*)"|'([^']*)')/g)) add(m[1] ?? m[2], f);
  const text = html.replace(/<[^>]*>/g, '\u0000');
  for (const seg of text.split('\u0000')) add(seg.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&middot;/g, '·'), f);
}

// ── JS lexer: string / template literals (recursive for ${}) ──
function lex(code, f) {
  let i = 0;
  const n = code.length;
  const lits = [];
  function template(start) {       // at the char after the opening backtick; returns [text with {k}, end index]
    let s = '', k = 0;
    while (i < n && code[i] !== '`') {
      if (code[i] === '\\') { s += code[i + 1] === 'n' ? ' ' : code[i + 1]; i += 2; continue; }
      if (code[i] === '$' && code[i + 1] === '{') { i += 2; s += `{${k++}}`; scanCode('}'); continue; }
      s += code[i++];
    }
    i++;
    return s;
  }
  function scanCode(close) {
    let depth = 0;
    while (i < n) {
      const c = code[i];
      if (c === '/' && code[i + 1] === '/') { while (i < n && code[i] !== '\n') i++; continue; }
      if (c === '/' && code[i + 1] === '*') { i = code.indexOf('*/', i + 2) + 2 || n; continue; }
      if (c === "'" || c === '"') {
        let s = ''; i++;
        while (i < n && code[i] !== c && code[i] !== '\n') { if (code[i] === '\\') { s += code[i + 1] === 'n' ? ' ' : code[i + 1]; i += 2; } else s += code[i++]; }
        i++; lits.push(s); continue;
      }
      if (c === '`') { i++; lits.push(template()); continue; }
      if (c === '/' && /[=(,:!&|?{};\n]\s*$/.test(code.slice(Math.max(0, i - 12), i))) {   // regex literal
        i++; while (i < n && code[i] !== '/' && code[i] !== '\n') { if (code[i] === '\\') i++; i++; } i++; while (/[a-z]/.test(code[i] || '')) i++; continue;
      }
      if (c === '{') depth++;
      if (c === '}') { if (close && depth === 0) { i++; return; } depth--; }
      i++;
    }
  }
  scanCode(null);
  for (const l of lits) {
    if (/[<]\w|<\/|<!/.test(l) && />/.test(l)) htmlPieces(l.replace(/\{\d+\}/g, m => m), f);   // has tags
    else add(l, f);
  }
}

for (const f of readdirSync(join(src, 'markup'))) htmlPieces(readFileSync(join(src, 'markup', f), 'utf8'), 'markup/' + f);
for (const f of readdirSync(join(src, 'js'))) if (!/^(0[34]-i18n|36-qr)/.test(f)) lex(readFileSync(join(src, 'js', f), 'utf8'), 'js/' + f);

// ── filter ──
const skip = s => {
  if (/^[\w.\-:#\/\[\]=>+~*,%@!$()'"\s]*$/.test(s) && !/\s/.test(s) && /^[a-z]/.test(s)) return true;   // identifier / class / selector
  if (/^(https?:|\/|\.|#|data:|M\d|<)/.test(s)) return true;
  if (/^[a-z0-9_\-]+(\s[a-z0-9_\-]+)*$/.test(s) && /[-_]/.test(s)) return true;                            // class lists
  if (/^[A-Za-z]+$/.test(s) && !/^[A-Z]/.test(s)) return true;                                               // lone lowercase word
  if (/^[\w.-]+\(.*\)$/.test(s)) return true;                                                                // call
  if (/[{}]|=>|===|\bfunction\b|\breturn\b/.test(s.replace(/\{\d+\}/g, ''))) return true;
  if (/^[\W\d_]*$/.test(s)) return true;
  if (/^\{\d+\}$/.test(s)) return true;
  return false;
};
let list = [...out.entries()].filter(([s]) => !skip(s)).sort((a, b) => a[0].localeCompare(b[0]));
if (process.argv.includes('--missing')) {
  const dict = readFileSync(join(src, 'js', '04-i18n-ru.js'), 'utf8');
  const ru = new Function('const I18N = {};\n' + dict + '\n;return I18N.ru')();
  list = list.filter(([s]) => !(s in ru));
}
if (process.argv.includes('--json')) console.log(JSON.stringify(list.map(x => x[0]), null, 0));
else for (const [s, f] of list) console.log(s + '\t' + f);
