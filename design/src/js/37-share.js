/* ══════════════════════ SHARE: clipboard, links, QR ══════════════════════
   Copy URL / Copy share link / Show QR code in the Nodes ⋮ menus. A server's link comes
   from the core (share.dart) through backend.shareLink; the QR is drawn here (36-qr.js).
   (Flutter: Clipboard.setData, a QrImageView in a ShareSheet.) */

// The async clipboard where the page may use it; else the old execCommand way (a page
// opened as a file, the Artifact viewer).
function copyText(text, what) {
  const done = () => toast((what || 'Text') + ' copied');
  const fallback = () => {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (e) {}
    ta.remove();
    toast(ok ? (what || 'Text') + ' copied' : 'Copy is blocked here — select the text and copy it');
  };
  if (navigator.clipboard && navigator.clipboard.writeText) return navigator.clipboard.writeText(text).then(done, fallback);
  fallback();
  return Promise.resolve();
}

/* ── Share links read in the page ──
   Only what the manual server form shows before saving (protocol, address, port, name,
   secret) and what the mock adds; the real server is built by the core's parser. Covers
   the forms the core reads: vmess as base64 JSON, ss legacy base64 and SIP002, IPv6 in
   brackets, hy2 with a port range. */

const SHARE_PROTOS = { vless: 'vless', vmess: 'vmess', trojan: 'trojan', ss: 'ss', hy2: 'hy2', hysteria2: 'hy2',
  tuic: 'tuic', anytls: 'anytls', socks: 'socks', socks5: 'socks' };

function b64Text(s) {
  try {
    s = s.trim().replace(/-/g, '+').replace(/_/g, '/');
    s += '='.repeat((4 - s.length % 4) % 4);
    return decodeURIComponent(escape(atob(s)));
  } catch (e) { return null; }
}
const uriPart = s => { try { return decodeURIComponent(s); } catch (e) { return s; } };

function parseShareLinkLite(link) {
  const m = (link || '').trim().match(/^([a-z0-9]+):\/\/(\S+)$/i);
  const protocol = m && SHARE_PROTOS[m[1].toLowerCase()];
  if (!protocol) return null;
  let rest = m[2], name = '';
  const hash = rest.indexOf('#');
  if (hash >= 0) { name = uriPart(rest.slice(hash + 1)).trim(); rest = rest.slice(0, hash); }

  if (protocol === 'vmess' && !rest.includes('@')) {          // v2rayN: base64 of a JSON
    let j = null;
    try { j = JSON.parse(b64Text(rest.split('?')[0])); } catch (e) {}
    if (!j || !j.add) return null;
    return { protocol, address: String(j.add).replace(/^\[|\]$/g, ''), port: String(j.port || 443), name: String(j.ps || name).trim(), secret: String(j.id || '') };
  }
  let plainUser = false;
  if (protocol === 'ss' && !rest.includes('@')) {             // legacy: base64(method:password@host:port)
    const d = b64Text(rest.split(/[/?]/)[0]);
    if (!d || !d.includes('@')) return null;
    rest = d;
    plainUser = true;
  }
  const at = rest.lastIndexOf('@');
  let user = at >= 0 ? rest.slice(0, at) : '';
  const hostPart = (at >= 0 ? rest.slice(at + 1) : rest).split(/[/?]/)[0];
  const hm = hostPart.match(/^\[([0-9a-f:.%]+)\](?::(\d+))?/i) || hostPart.match(/^([^:\[\]]+)(?::(\d+))?/);
  if (!hm || !hm[1]) return null;
  if (!plainUser) user = uriPart(user);
  if (protocol === 'ss' && user && !user.includes(':')) user = b64Text(user) || user;   // SIP002 userinfo
  return { protocol, address: hm[1], port: hm[2] || '443', name, secret: user };
}

// The flag is the first pair of regional indicators in the name (as the core does).
function splitFlagLite(name) {
  name = (name || '').trim();
  const m = name.match(/[\u{1F1E6}-\u{1F1FF}]{2}/u);
  if (!m) return { flag: '🌐', name };
  return { flag: m[0], name: name.replace(m[0], '').trim() || name };
}

const LINK_FORMS = 'No server link recognised (vless://, vmess://, trojan://, ss://, hy2://, tuic://, anytls://, socks://)';

// The manual form's name, when typed by hand (or with no link to name the server): a flag in
// it goes to n.flag like the core does; without one the server keeps its flag.
function typedName(n, f) {
  if (!f.name || (f.link && !f.nameTouched)) return n;
  const s = splitFlagLite(f.name);
  n.name = s.name;
  if (s.flag !== '🌐') n.flag = s.flag;
  return n;
}

/* ── Menu actions ── */

const findNode = (sid, nid) => (sourcesData[sid] && sourcesData[sid].nodes || []).find(x => x.id === nid);

function copySourceUrl(sid) {
  const s = sourcesData[sid];
  if (s && s.url) copyText(s.url, 'Subscription URL');
}

function copyShareLink(sid, nid) {
  const n = findNode(sid, nid);
  if (!n) return;
  backend.shareLink(n).then(link => link ? copyText(link, 'Share link') : toast(noLinkWhy(n)),
    e => toast('No share link: ' + e.message));
}

const noLinkWhy = n => n.unsupported ? 'This server has no share link (' + n.unsupported + ')' : 'This server has no share link (' + n.protocol + ')';

// ShareSheet: the code, the text under it and Copy. Opens in the actions sheet.
function showQr(title, text, what, copyLabel) {
  let svg;
  try { svg = QR.svg(text, 'M'); } catch (e) { toast('Too long for a QR code'); return; }
  window._qrText = text;
  openActions(title,
    `<div class="qr-card"><div class="qr-box">${svg}</div>
       <div class="qr-text" onclick="selectText(this)">${esc(text)}</div></div>` +
    menuRow(ICON.copy, copyLabel || 'Copy', `copyText(window._qrText, '${what || 'Link'}')`));
}

function showSourceQr(sid) {
  const s = sourcesData[sid];
  if (s && s.url) showQr(s.name, s.url, 'Subscription URL', 'Copy URL');
}

function showNodeQr(sid, nid) {
  const n = findNode(sid, nid);
  if (!n) return;
  backend.shareLink(n).then(link => link ? showQr(n.flag + '  ' + n.name, link, 'Share link', 'Copy share link') : toast(noLinkWhy(n)),
    e => toast('No share link: ' + e.message));
}

function selectText(el) {
  const r = document.createRange();
  r.selectNodeContents(el);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(r);
}
