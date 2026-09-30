/* ══════════════════════ LIVE CONNECTIONS (Home → Connections card) ══════════════════════
   The list is backend.traffic().conns (50-home.js polls it once a second). Tools row: search, Filter
   (badge = selected values), Sort, ⋮ (Pause / Copy / Filter by exit… / Close shown). The menus are the
   compact `actions` sheet, the filter is a nested sheet (sh-connfilter): sections Protocol, App, Rule,
   Exit, Host; values are built from the current connections with a count, OR inside a section, AND
   across sections; a selected value with no connection left stays listed (0). Nothing is applied until ✓.
   Pause freezes the list (a snapshot); the Home cards keep updating. A row unfolds its details and
   actions (Close, Copy, Rule for this host / app → the rule form, prefilled). */

const CONN_SORTS = [   // key, menu name, short label on the button, order
  ['new', 'Newest', 'Newest', (a, b) => Date.parse(b.start) - Date.parse(a.start)],
  ['down', 'Download speed', '↓ speed', (a, b) => b.downRate - a.downRate],
  ['up', 'Upload speed', '↑ speed', (a, b) => b.upRate - a.upRate],
  ['downed', 'Downloaded', '↓ total', (a, b) => b.down - a.down],
  ['upped', 'Uploaded', '↑ total', (a, b) => b.up - a.up],
  ['age', 'Duration', 'Longest', (a, b) => Date.parse(a.start) - Date.parse(b.start)],
];
let connSort = 'new', connPaused = false, connSnap = null, connOpen = null;
const connFNew = () => ({ net: new Set(), app: new Set(), rule: new Set(), exit: new Set(), host: new Set() });
let connF = connFNew(), connFD = connFNew(), connFExp = new Set(), connFOnly = null;

const connApp = c => c.process ? c.process.split(/[\\/]/).pop() : '';
const connRule = c => c.rule && c.rule !== 'final' ? c.rule : '';   // '' = the default / final route
const connTag = t => { if (t === 'direct') return 'Direct'; const n = trafficNode(t); return n ? n.flag + ' ' + n.name : t; };
const connViaText = out => out.slice().reverse().map(connTag).join(' → ') || '—';
const CONN_SECS = [   // key, title, values of a connection, label of a value
  ['net', 'Protocol', c => [c.net], v => v.toUpperCase()],
  ['app', 'App', c => [connApp(c)], v => v || 'Unknown'],
  ['rule', 'Rule', c => [connRule(c)], v => v || 'Default / final'],
  ['exit', 'Exit', c => [c.out[0] || 'direct'], connTag],
  ['host', 'Host', c => [c.host], v => v],
];
const connMatchF = (c, F) => CONN_SECS.every(([k, , get]) => !F[k].size || get(c).some(v => F[k].has(v)));
const connFCount = F => CONN_SECS.reduce((n, [k]) => n + F[k].size, 0);
// The filter matches host, app, rule and the servers a connection goes through.
const connMatches = (c, q) => !q || [c.host, c.process, c.rule, connViaText(c.out)].some(v => (v || '').toLowerCase().includes(q));
const connLive = () => connected && traffic ? traffic.conns : [];
const connSource = () => connPaused ? connSnap || [] : connLive();
const connQuery = () => document.getElementById('connFilter').value.trim().toLowerCase();
function connShown() {
  const q = connQuery(), cmp = CONN_SORTS.find(s => s[0] === connSort)[3];
  return connSource().filter(c => connMatches(c, q) && connMatchF(c, connF)).sort(cmp);
}
const connById = id => connSource().concat(connLive()).find(c => c.id === id);

// LiveConnRow: host:port + TCP/UDP; the route (entry → exit) and rule; app, speed, bytes, age.
// × closes one (sing-box drops it, the app usually opens a new one); a tap unfolds it.
function connDetailHtml(c) {
  const line = (k, v) => `<div class="lcd-line"><span class="lcd-k">${k}</span><span class="lcd-v">${v}</span></div>`;
  const isIp = /^[\d.]+$/.test(c.host) || c.host.includes(':');
  return `<div class="live-conn-detail" onclick="event.stopPropagation()">
    ${line('Host', esc(c.host) + (c.port ? ':' + esc(c.port) : ''))}${line('Network', esc(c.net.toUpperCase()))}
    ${line('Rule', esc(connRule(c) || 'Default / final'))}${line('Route', trafficVia(c.out))}
    ${line('App', c.process ? esc(c.process) : 'Unknown')}${line('Started', esc(new Date(c.start).toLocaleTimeString()) + ' · ' + trafficAge(c.start))}
    ${line('↓ Down', fmtBytes(c.down) + ' · ' + fmtRate(c.downRate).join(' '))}${line('↑ Up', fmtBytes(c.up) + ' · ' + fmtRate(c.upRate).join(' '))}
    <div class="lcd-acts" data-id="${esc(c.id)}">
      <div class="chip" onclick="closeLiveConn(this.parentNode.dataset.id)">Close</div>
      <div class="chip" onclick="connCopyOne(this.parentNode.dataset.id)">Copy</div>
      <div class="chip" onclick="connRuleFor('host',this.parentNode.dataset.id)">Rule for this ${isIp ? 'address' : 'host'}…</div>
      ${c.process ? `<div class="chip" onclick="connRuleFor('app',this.parentNode.dataset.id)">Rule for this app…</div>` : ''}
    </div></div>`;
}
function renderLiveConns() {
  if (!connected && connPaused) { connPaused = false; connSnap = null; }
  const all = connSource(), list = connShown(), live = connLive();
  const nF = connFCount(connF), cur = CONN_SORTS.find(s => s[0] === connSort);
  const badge = document.getElementById('connFilterBadge');
  badge.style.display = nF ? '' : 'none'; badge.textContent = nF;
  document.getElementById('connFilterBtn').classList.toggle('on', nF > 0);
  document.getElementById('connSortLabel').textContent = cur[2];
  document.getElementById('connSortBtn').classList.toggle('on', connSort !== 'new');
  const bar = document.getElementById('connPaused');
  if (connPaused) {
    const known = new Set((connSnap || []).map(c => c.id)), fresh = live.filter(c => !known.has(c.id)).length;
    bar.innerHTML = `<span>Paused · ${fresh} new connection${fresh === 1 ? '' : 's'}</span><button onclick="connSetPaused(false)">Resume</button>`;
  }
  bar.style.display = connPaused ? '' : 'none';
  document.getElementById('liveConnList').innerHTML = list.length ? list.map(c => `
    <div class="live-conn-row ${connOpen === c.id ? 'open' : ''}" data-id="${esc(c.id)}" onclick="connToggle(this.dataset.id)">
      <div class="live-conn-top"><span class="live-conn-host">${esc(c.host)}${c.port ? ':' + esc(c.port) : ''}</span><span class="live-conn-proto ${c.net === 'udp' ? 'udp' : 'tcp'}">${esc(c.net.toUpperCase())}</span><button class="live-conn-close" title="Close connection" data-id="${esc(c.id)}" onclick="event.stopPropagation();closeLiveConn(this.dataset.id)">×</button></div>
      <div class="live-conn-meta">${trafficVia(c.out)}${connRule(c) ? ' · ' + esc(connRule(c)) : ''}</div>
      <div class="live-conn-meta dim">${c.process ? esc(connApp(c)) + ' · ' : ''}↓ ${fmtRate(c.downRate).join(' ')} ↑ ${fmtRate(c.upRate).join(' ')} · ${fmtBytes(c.down + c.up)} · ${trafficAge(c.start)}</div>
      ${connOpen === c.id ? connDetailHtml(c) : ''}
    </div>`).join('') : `<div class="live-conn-empty">${!connected ? 'Not connected' : all.length ? 'Nothing matches' : 'No open connections'}</div>`;
}
function connToggle(id) { connOpen = connOpen === id ? null : id; renderLiveConns(); }
sheetCloseHooks.connections = () => { connPaused = false; connSnap = null; connOpen = null; };

function closeLiveConn(id) {
  backend.closeConn(id).then(() => {
    connGone(id ? new Set([id]) : null);
    if (!id) toast('All connections closed');
  }, e => toast('Not closed: ' + e.message));
}
function connGone(ids) {   // the ids just closed (null = all)
  if (traffic) traffic.conns = ids ? traffic.conns.filter(c => !ids.has(c.id)) : [];
  if (connSnap) connSnap = ids ? connSnap.filter(c => !ids.has(c.id)) : [];
  renderLiveConns();
}
// Close shown: only the rows in the list now. Nothing filtered, not paused = all of them.
function connCloseShown() {
  const shown = connShown(), all = !connPaused && !connFCount(connF) && !connQuery();
  if (!shown.length) return;
  const ids = new Set(shown.map(c => c.id));
  (all ? backend.closeConn(null) : Promise.all(shown.map(c => backend.closeConn(c.id)))).then(() => {
    connGone(all ? null : ids);
    toast(all ? 'All connections closed' : shown.length + ' connection' + (shown.length === 1 ? '' : 's') + ' closed');
  }, e => toast('Not closed: ' + e.message));
}
function connSetPaused(on) {
  connPaused = on; connSnap = on ? connLive().slice() : null;
  renderLiveConns();
}

/* Copy: `tcp host:port · app · rule · via · ↓↑ bytes · age`, one connection per line */
const connText = c => [c.net + ' ' + c.host + (c.port ? ':' + c.port : ''), connApp(c) || 'Unknown', connRule(c) || 'final', connViaText(c.out),
  '↓' + fmtBytes(c.down) + ' ↑' + fmtBytes(c.up), trafficAge(c.start)].join(' · ');
function connCopyOne(id) { const c = connById(id); if (c) copyText(connText(c), 'Connection'); }
function connCopyShown() {
  const shown = connShown();
  if (!shown.length) { toast('Nothing to copy'); return; }
  copyText(shown.map(connText).join('\n'), shown.length + ' connection' + (shown.length === 1 ? '' : 's'));
}
// A new rule with one condition taken from the connection: its host (a domain or an address) or its app.
function connRuleFor(what, id) {
  const c = connById(id); if (!c) return;
  const g = what === 'app' ? { process: { not: false, v: { process: [connApp(c)] } } }
    : /^[\d.]+$/.test(c.host) || c.host.includes(':') ? { ip: { not: false, v: { ip_cidr: [c.host] } } }
    : { domain: { not: false, v: { domain: [c.host] } } };
  openRuleForm();
  ruleDraft = newRule({ name: what === 'app' ? connApp(c) : c.host, groups: g });
  renderRuleForm();
}

/* Menus: ⋮ and Sort (the compact `actions` sheet, like the Nodes menus) */
const CONN_ICON = {
  pause: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>',
  play: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M7 4l13 8-13 8z"/></svg>',
  funnel: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/></svg>',
};
function openConnMore() {
  const n = connShown().length, some = !!(connFCount(connF) || connQuery());
  openActions('Connections',
    menuRow(connPaused ? CONN_ICON.play : CONN_ICON.pause, connPaused ? 'Resume' : 'Pause<div class="menu-sub">Freezes the list, the cards on Home keep counting</div>', "closeSheet('actions');connSetPaused(" + !connPaused + ')') +
    menuRow(ICON.copy, 'Copy' + '<div class="menu-sub">The shown list as text</div>', "closeSheet('actions');connCopyShown()") +
    menuRow(CONN_ICON.funnel, 'Filter by exit…', "closeSheet('actions');openConnFilter('exit')") +
    menuRow(ICON.close, some ? `Close ${n} shown` : 'Close all', n ? "closeSheet('actions');connCloseShown()" : '', 'danger' + (n ? '' : ' disabled')));
}
function openConnSort() {
  openActions('Sort connections', CONN_SORTS.map(([k, name]) =>
    menuRow(connSort === k ? ICON.check : '<span style="width:18px"></span>', name, `connSetSort('${k}')`)).join(''));
}
function connSetSort(k) { connSort = k; closeSheet('actions'); renderLiveConns(); }

/* Filter sheet. only = 'exit' shows that one section (the ⋮ → Filter by exit… entry). */
function openConnFilter(only) {
  connFD = connFNew(); CONN_SECS.forEach(([k]) => connF[k].forEach(v => connFD[k].add(v)));
  connFExp = new Set(); connFOnly = typeof only === 'string' ? only : null;
  document.getElementById('cfSearch').value = '';
  document.querySelector('#sh-connfilter .sheet-title').textContent = connFOnly ? 'Filter by exit' : 'Filter';
  renderConnFilter();
  openSheet('connfilter');
}
function renderConnFilter() {
  const q = document.getElementById('cfSearch').value.trim().toLowerCase(), src = connSource();
  document.getElementById('cf-body').innerHTML = CONN_SECS.filter(([k]) => !connFOnly || k === connFOnly).map(([k, title, get, label]) => {
    const count = new Map(), entry = new Map();
    src.forEach(c => get(c).forEach(v => {
      count.set(v, (count.get(v) || 0) + 1);
      if (k === 'exit' && c.out.length > 1) (entry.get(v) || entry.set(v, new Set()).get(v)).add(connViaText(c.out.slice(1)));
    }));
    connFD[k].forEach(v => { if (!count.has(v)) count.set(v, 0); });   // selected, no connection now
    const vals = [...count].filter(([v]) => !q || label(v).toLowerCase().includes(q))
      .sort((a, b) => b[1] - a[1] || label(a[0]).localeCompare(label(b[0])));
    if (!vals.length) return '';
    const cap = !connFOnly && !q && !connFExp.has(k) && vals.length > 8;
    const rows = (cap ? vals.slice(0, 8) : vals).map(([v, n]) => `
      <div class="cf-row ${n ? '' : 'zero'}" data-k="${k}" data-v="${esc(v)}" onclick="connFilterToggle(this.dataset.k,this.dataset.v)">
        <div class="sub-checkbox ${connFD[k].has(v) ? 'checked' : ''}"></div>
        <span class="cf-name">${esc(label(v))}${entry.has(v) ? `<span class="cf-dim">via ${esc([...entry.get(v)].join(', '))}</span>` : ''}</span><span class="cf-count">${n}</span></div>`).join('');
    return `<div class="list-caption"><span>${title}</span><span>${connFD[k].size ? connFD[k].size + ' selected' : ''}</span></div>${rows}`
      + (cap ? `<button class="cf-more" onclick="connFExp.add('${k}');renderConnFilter()">Show all ${vals.length}</button>` : '');
  }).join('') || '<div class="live-conn-empty">Nothing matches</div>';
}
function connFilterToggle(k, v) {
  if (!connFD[k].delete(v)) connFD[k].add(v);
  renderConnFilter();
}
function connFilterClear() { connFD = connFNew(); renderConnFilter(); }
function connFilterApply() {
  connF = connFNew(); CONN_SECS.forEach(([k]) => connFD[k].forEach(v => connF[k].add(v)));
  closeSheet('connfilter');
  renderLiveConns();
}
