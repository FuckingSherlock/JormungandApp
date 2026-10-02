// design/src/js/04-i18n-ru.js (English text -> Russian)  ->  app/lib/l10n/app_en.arb + app_ru.arb
//
//   node app/tool/gen_i18n.mjs
//
// Source of truth stays the mockup dictionary (docs/i18n.md). Re-run after it changes.
// - ARB key = stable camelCase id made from the English text. The English text -> key mapping is
//   kept in app/tool/i18n_keys.json and only ever grows (a changed English text gets a new key,
//   an old key is never reused), so regenerating keeps every key used by Dart code stable.
// - {0} {1}…  -> String placeholders  s0 s1…;   {#0} {#1}… (numbers) -> num placeholders  n0 n1…
// - A value that is an array [1, 2-4, 5+] -> ICU plural over the first numeric placeholder
//   (Russian: one / few / many; `other` = many). English: one / other, with the singular found
//   among the dictionary's own keys ("{#0} node" for "{#0} nodes"); otherwise `other` only.
// - Strings only the app has (not in the mockup) go to app/tool/i18n_extra.json
//   ({ "English": "Русский" } or { "English": ["one", "few", "many"] }); mockup entries win.
// - Only whole strings are exported. The mockup's DOM layer also translates pieces split by
//   " · " / " — "; Flutter code composes those from the separate keys.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { root } from './_util.mjs';

const dictSrc = readFileSync(join(root, 'design/src/js/04-i18n-ru.js'), 'utf8');
const ru = new Function('const I18N = {};\n' + dictSrc + '\n;return I18N.ru')();
const extraFile = join(root, 'app/tool/i18n_extra.json');
const keysFile = join(root, 'app/tool/i18n_keys.json');
const outDir = join(root, 'app/lib/l10n');

const norm = s => s.replace(/\s+/g, ' ').trim();

// ── entries: English (normalised) -> Russian value (string | array) ──
const entries = new Map();
for (const [k, v] of Object.entries(ru)) {
  const en = norm(k);
  if (!en) continue;
  if (entries.has(en)) { console.warn(`duplicate after normalising: "${en}"`); continue; }
  entries.set(en, v);
}
const mockupCount = entries.size;
if (existsSync(extraFile)) {
  for (const [k, v] of Object.entries(JSON.parse(readFileSync(extraFile, 'utf8')))) {
    const en = norm(k);
    if (!entries.has(en)) entries.set(en, v);
  }
}

// ── keys (stable) ──
const keyMap = existsSync(keysFile) ? JSON.parse(readFileSync(keysFile, 'utf8')) : {};
const taken = new Set(Object.values(keyMap));
const RESERVED = new Set(`abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for function get hide if implements import in interface is late library mixin new null of on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void when while with yield
  localeName delegate localizationsDelegates supportedLocales lookupAppLocalizations hashCode runtimeType toString noSuchMethod`.split(/\s+/));

const PH = /\{(#?)(\d+)\}/g;
function baseKey(en, isPlural) {
  const words = en.replace(PH, ' ').replace(/[^A-Za-z0-9]+/g, ' ').trim().split(' ').filter(Boolean).slice(0, 6);
  let k = words.map((w, i) => { w = w.toLowerCase(); return i ? w[0].toUpperCase() + w.slice(1) : w; }).join('');
  if (k.length > 40) k = k.slice(0, 40);
  if (!k) k = 'str';
  if (/^\d/.test(k)) k = 'n' + k;
  if (isPlural) k += 'Plural';
  if (RESERVED.has(k)) k += 'Text';
  return k;
}
function allocate(en) {
  const base = baseKey(en, Array.isArray(entries.get(en)));
  let k = base, i = 2;
  while (taken.has(k)) k = base + i++;
  taken.add(k);
  keyMap[en] = k;
  return k;
}
const hasPh = en => /\{#?\d+\}/.test(en);
let added = 0;
for (const pass of [false, true]) {          // plain texts claim the short names first
  for (const en of entries.keys()) {
    if (hasPh(en) !== pass || keyMap[en]) continue;
    allocate(en); added++;
  }
}

// ── message building ──
function info(en) {          // placeholders of the key, in order of first appearance
  const ph = [];             // { idx, num }
  for (const m of en.matchAll(PH)) {
    let p = ph.find(x => x.idx === m[2]);
    if (!p) ph.push(p = { idx: m[2], num: false });
    if (m[1]) p.num = true;
  }
  return ph;
}
const name = p => (p.num ? 'n' : 's') + p.idx;
function sub(text, ph, where) {
  return text.replace(PH, (m, h, i) => {
    const p = ph.find(x => x.idx === i);
    if (!p) throw new Error(`placeholder {${i}} is not in the key (${where})`);
    return `{${name(p)}}`;
  });
}
function check(text, where) {
  const bare = text.replace(/\{[ns]\d+\}/g, '').replace(PH, '');
  if (/[{}]/.test(bare)) throw new Error(`literal brace in "${where}" — ICU would need escaping (use-escaping)`);
}

// singular English form of a plural key, found among the dictionary keys
function singularOf(en) {
  // same words, each plural word = the singular word + a short ending (servers/server, entries/entry, are/is)
  const split = w => /^(.*?)([,.:;)!?]*)$/.exec(w).slice(1);
  const same = (pw0, sw0) => {
    if (pw0 === sw0) return true;
    const [p, pp] = split(pw0), [s, sp] = split(sw0);
    return pp === sp && ((s.length >= 3 && p.startsWith(s) && p.length - s.length <= 2) ||
      (p === 'entries' && s === 'entry') || (p === 'are' && s === 'is'));
  };
  const pw = en.split(' '), phs = info(en).map(name).join();
  let best = null;
  for (const k of entries.keys()) {
    if (k === en || !hasPh(k) || info(k).map(name).join() !== phs) continue;
    const sw = k.split(' ');
    if (sw.length !== pw.length || !pw.every((w, i) => same(w, sw[i]))) continue;
    if (!best || k.length > best.length) best = k;
  }
  return best;
}

const plain = (v, ph, where) => { const s = sub(v, ph, where); check(s, where); return s; };
const en = { '@@locale': 'en' }, ruArb = { '@@locale': 'ru' };
let nPlural = 0, nPluralNoSingular = [];
// a singular key ("{#0} node") is folded into the plural message of its pair ("{#0} nodes")
const singulars = new Map();
for (const [text, val] of entries) if (Array.isArray(val)) { const s = singularOf(text); if (s) singulars.set(text, s); }
const folded = new Set(singulars.values());
for (const [text, val] of entries) {
  if (folded.has(text)) continue;
  const key = keyMap[text];
  const ph = info(text);
  if (Array.isArray(val)) {
    const cnt = ph.find(p => p.num) || ph[0];
    if (!cnt) throw new Error(`plural entry without placeholder: ${text}`);
    cnt.num = true;       // the count is always a num
    const c = name(cnt);
    const f = val.map(v => plain(v, ph, text));
    const [one, few, many] = f;
    ruArb[key] = `{${c}, plural, one{${one}} few{${few}} many{${many}} other{${many}}}`;
    const sing = singulars.get(text);
    const other = plain(text, ph, text);
    if (sing) en[key] = `{${c}, plural, one{${plain(sing, ph, text)}} other{${other}}}`;
    else { en[key] = `{${c}, plural, other{${other}}}`; nPluralNoSingular.push(text); }
    nPlural++;
  } else {
    en[key] = plain(text, ph, text);
    ruArb[key] = plain(val, ph, text);
  }
  // declared order = Dart parameter order; for a plural the count comes first, as in the message
  const decl = Array.isArray(val) ? [ph.find(p => p.num) || ph[0], ...ph.filter(p => p !== (ph.find(p => p.num) || ph[0]))] : ph;
  if (ph.length) en['@' + key] = { placeholders: Object.fromEntries(decl.map(p => [name(p), { type: p.num ? 'num' : 'String' }])) };
}

// ── write ──
mkdirSync(outDir, { recursive: true });
const dump = o => JSON.stringify(o, null, 2) + '\n';
// the English ARB carries the metadata: put @key right after key
const ordered = o => {
  const r = { '@@locale': o['@@locale'] };
  for (const k of Object.keys(o)) { if (k.startsWith('@')) continue; r[k] = o[k]; if (o['@' + k]) r['@' + k] = o['@' + k]; }
  return r;
};
writeFileSync(join(outDir, 'app_en.arb'), dump(ordered(en)));
writeFileSync(join(outDir, 'app_ru.arb'), dump(ruArb));
writeFileSync(keysFile, dump(keyMap));

console.log(`gen_i18n: ${entries.size - folded.size} messages (${mockupCount} mockup entries, ${entries.size - mockupCount} app-only, ${folded.size} singulars folded into plurals), ${nPlural} plurals, ${added} new keys -> app/lib/l10n/app_{en,ru}.arb`);
if (nPluralNoSingular.length) console.log(`  plurals with no English singular found (shown as "other" for 1): ${nPluralNoSingular.join(' | ')}`);
