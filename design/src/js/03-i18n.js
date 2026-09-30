/* ══════════════════════ I18N ══════════════════════
   The English source string is the key (docs/i18n.md). The dictionary of a language is
   `I18N.<lang>` (04-i18n-ru.js): plain keys, and keys with {0} {1}… placeholders that match
   the rendered text (`"{0} nodes"`); a value that is an ARRAY is the plural forms
   [one, few, many] chosen by the first numeric placeholder (Russian 1 / 2–4 / 5+).
   A string with no entry stays English.

   Two ways in, one lookup (I18N.tr):
   - t('Backup failed: {0}', msg) / tn(3, '{0} nodes') — for text made outside the DOM
     (exported files, prompts, anything that is not put into the page);
   - the page itself: every text node and every title / placeholder / aria-label is translated
     in place by a MutationObserver, whatever wrote it (markup, a template in JS, a toast).
     The English original is kept per node, so switching back restores it and text that JS
     rewrites arrives in English and is translated again. Raw log lines, the JSON textarea and
     `[data-notr]` are never touched.
   (Flutter: the same keys become ARB entries — tools/i18n-extract.mjs lists them.) */

const I18N = (() => {
  const S = { lang: 'en', compiled: {}, cache: new Map() };
  const SKIP = 'script,style,textarea,[data-notr],.log-line,.log-time,.log-tag';
  const ATTRS = ['title', 'placeholder', 'aria-label', 'alt'];
  const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const norm = s => s.replace(/\s+/g, ' ').trim();

  // Russian: 1 / 2–4 / 5+ (11–14 are “many”).
  function plural(n, forms) {
    n = Math.abs(n) | 0;
    const a = n % 10, b = n % 100;
    return forms[a === 1 && b !== 11 ? 0 : a >= 2 && a <= 4 && (b < 12 || b > 14) ? 1 : 2];
  }

  function compile(lang) {
    const d = S.compiled[lang];
    if (d) return d;
    const src = I18N[lang] || {}, exact = new Map(), pats = [];
    for (const k of Object.keys(src)) {
      if (!/\{#?\d+\}/.test(k)) { exact.set(norm(k), src[k]); continue; }
      const idx = [];
      // {0} = any text, {#0} = a number (digits, one decimal point)
      const rx = esc(norm(k)).replace(/\\?\{(#?)(\d+)\\?\}/g, (m, num, i) => { idx.push(+i); return num ? '(\\d+(?:[.,]\\d+)?)' : '(.+?)'; });
      pats.push({ rx: new RegExp('^' + rx + '$'), idx, val: src[k], len: norm(k).replace(/\{#?\d+\}/g, '').length });
    }
    pats.sort((a, b) => b.len - a.len);
    return (S.compiled[lang] = { exact, pats });
  }

  function fill(val, caps, lang) {
    if (Array.isArray(val)) {
      const n = caps.map(c => /^\d+$/.test(String(c).trim()) ? +c : NaN).find(x => !isNaN(x));
      val = plural(n === undefined ? 0 : n, val);
    }
    return val.replace(/\{(\d+)\}/g, (m, i) => caps[i] === undefined ? m : (lookup(caps[i], lang, 1) ?? caps[i]));
  }

  function lookup(en, lang, depth) {
    const d = compile(lang);
    const key = norm(en);
    if (!key || !/[A-Za-z]/.test(key)) return null;
    let v = d.exact.get(key);
    if (v !== undefined) return Array.isArray(v) ? plural(1, v) : v;
    if (depth > 2) return null;
    for (const p of d.pats) {
      const m = p.rx.exec(key);
      if (!m) continue;
      const caps = [];
      p.idx.forEach((i, j) => { caps[i] = m[j + 1]; });
      return fill(p.val, caps, lang);
    }
    // “a · b”, “a — b”: the parts one by one when the whole is not there
    for (const sep of [' · ', ' — ']) {
      if (!key.includes(sep) || depth > 1) continue;
      let any = false;
      const parts = key.split(sep).map(x => { const r = lookup(x, lang, depth + 1); if (r != null) any = true; return r ?? x; });
      if (any) return parts.join(sep);
    }
    return null;
  }

  // English text → the current language (null: nothing to do). Whitespace around is kept.
  function tr(en, lang = S.lang) {
    if (lang === 'en' || !en) return null;
    const hit = S.cache.get(lang + '\u0000' + en);
    if (hit !== undefined) return hit;
    let r = lookup(en, lang, 0);
    if (r != null) { const m = /^(\s*)[\s\S]*?(\s*)$/.exec(en); r = m[1] + r + m[2]; }
    if (S.cache.size > 4000) S.cache.clear();
    S.cache.set(lang + '\u0000' + en, r);
    return r;
  }

  const format = (en, vars) => en.replace(/\{(\d+)\}/g, (m, i) => vars[i] === undefined ? m : vars[i]);

  /* ── the page ── */
  const texts = new WeakMap();   // Text node → { en, cur }
  const attrs = new WeakMap();   // Element → { attr: { en, cur } }
  let obs = null, busy = false;

  function doText(n) {
    if (n.parentElement && n.parentElement.closest(SKIP)) return;
    const v = n.nodeValue;
    let r = texts.get(n);
    if (!r) { if (S.lang === 'en') return; r = { en: v, cur: v }; texts.set(n, r); }
    else if (v !== r.cur) { r.en = v; r.cur = v; }        // JS wrote new English text
    const out = tr(r.en);
    const want = out == null ? r.en : out;
    if (want !== v) { n.nodeValue = want; }
    r.cur = want;
  }
  function doAttr(el, a) {
    if (el.closest && el.closest(SKIP)) return;
    const v = el.getAttribute(a);
    if (v == null) return;
    let m = attrs.get(el);
    if (!m) { if (S.lang === 'en') return; m = {}; attrs.set(el, m); }
    let r = m[a];
    if (!r) { if (S.lang === 'en') return; r = m[a] = { en: v, cur: v }; }
    else if (v !== r.cur) { r.en = v; r.cur = v; }
    const out = tr(r.en);
    const want = out == null ? r.en : out;
    if (want !== v) el.setAttribute(a, want);
    r.cur = want;
  }
  function walk(root) {
    if (root.nodeType === 3) { doText(root); return; }
    if (root.nodeType !== 1) return;
    if (root.matches && root.matches(SKIP)) return;
    for (const a of ATTRS) if (root.hasAttribute(a)) doAttr(root, a);
    for (let c = root.firstChild; c; c = c.nextSibling) walk(c);
  }
  function run(fn) {
    if (busy) return;
    busy = true;
    try { fn(); } finally { busy = false; if (obs) obs.takeRecords(); }
  }
  function onMutations(list) {
    run(() => {
      for (const m of list) {
        if (m.type === 'characterData') doText(m.target);
        else if (m.type === 'attributes') doAttr(m.target, m.attributeName);
        else m.addedNodes.forEach(walk);
      }
    });
  }
  function start() {
    if (obs || typeof MutationObserver === 'undefined') return;
    obs = new MutationObserver(onMutations);
    obs.observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }
  function apply() {
    document.documentElement.lang = S.lang;
    if (S.lang === 'en' && !obs) return;
    start();
    run(() => walk(document.body));
    const title = tr('Jormungand');
    document.title = title || 'Jormungand';
  }
  function setLang(lang) {
    if (lang !== 'en' && !I18N[lang]) lang = 'en';
    S.lang = lang;
    S.cache.clear();
    apply();
  }

  return {
    get lang() { return S.lang; },
    plural, tr, format, apply, setLang,
    locale: () => (S.lang === 'ru' ? 'ru-RU' : 'en-GB'),   // for toLocaleDateString / toLocaleString
    // English text of a node's current (maybe translated) text: for code that reads the page back.
    en: n => { const r = texts.get(n.firstChild); return r ? r.en : n.textContent; },
  };
})();

// t('Backup failed: {0}', msg)   ·   tn(3, '{0} nodes')   (the count is {0}; the entry is the plural array)
function t(en, ...vars) {
  const s = I18N.format(en, vars);
  return I18N.tr(s) ?? s;
}
const tn = (n, en, ...vars) => t(en, n, ...vars);
