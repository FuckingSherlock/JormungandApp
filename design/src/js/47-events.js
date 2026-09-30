/* ══════════════════════ EVENTS (Logs → Events) ══════════════════════
   EventsView: the events journal (contract: docs/core.md → Events; ids, cat, type, level, own,
   log, data) as rows a person reads. The core writes it (Auto switched, a site is blocked, a
   subscription failed, sing-box crashed…); the UI adds what only it knows (subscription
   results, the user's own actions) through backend.addEvent. Everything the UI shows is built
   here from the structured data: ids are resolved to names through the catalog, falling back
   to the raw id. The journal is polled every second while Events is open, every 3 s otherwise,
   because the background NOTIFICATIONS come from it too (58-notif.js): events newer than the
   page's first look (never history), not own, mapped to a toggle by EV_NOTIF.
   Oldest at the top, opened at the bottom; new event + at the bottom = a smooth scroll to it,
   scrolled up = the view stays and the pill counts them (the pill of the Raw tab, 46-logs.js).
   Filter (search, only problems, categories → event types) is temporary; Show my actions and
   which warnings / errors were seen (the dots on the Logs tab) are kept with the UI state.
   (Flutter: EventsView, EventRow, EventFilterSheet over the events stream.) */

const logCfg = { showOwn: false, seen: [], rawRead: 0 };   // kept (liveSnapshot): user actions shown; ids of warn / error events seen; the newest raw line read
const evState = { list: [], next: null, notifyFrom: null, busy: null, gen: 0, follow: true, unseen: 0, smoothUntil: 0, open: new Set(), shown: 0 };
const evFilter = { q: '', problems: false, off: new Set() };   // temporary: gone with the page
const evFilterOpen = new Set();                                 // categories unfolded in the sheet
const EV_KEEP = 1000;
const EV_REPEAT_MS = 10 * 60 * 1000;

// Category: label, icon (the colour is --ev-c of .cat-<cat>, 67-logs.css) and its event types.
const EV_CATS = [
  ['conn', 'Connection', [['connected', 'Connected'], ['disconnected', 'Disconnected'], ['connectFailed', 'Connect failed'], ['lost', 'Connection lost'], ['restored', 'Connection restored'], ['offline', 'No network'], ['online', 'Network back']]],
  ['auto', 'Auto', [['switched', 'Entry or server switched'], ['fastest', 'Fastest moved'], ['unstable', 'Unstable entry']]],
  ['site', 'Sites', [['blocked', 'Site does not open']]],
  ['sub', 'Subscriptions', [['updated', 'Updated'], ['failed', 'Update failed'], ['removed', 'Servers removed'], ['back', 'Servers back'], ['dead', 'Servers do not respond']]],
  ['rules', 'Rules', [['fallback', 'Rule target unavailable'], ['targetBack', 'Rule target back'], ['ruleSetFailed', 'Rule set not downloaded'], ['ruleSetUpdated', 'Rule set updated']]],
  ['dns', 'DNS', [['switched', 'DNS server switched']]],
  ['core', 'Core', [['crashed', 'sing-box stopped'], ['restarted', 'sing-box started again'], ['restartFailed', 'Could not start again'], ['down', 'VPN is down'], ['sysProxy', 'System proxy'], ['deprecated', 'Deprecated setting']]],
];
const svgI = d => `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
const EV_ICON = {
  conn: svgI('<path d="M5 12.55a11 11 0 0114.08 0M8.53 16.11a6 6 0 016.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/>'),
  auto: svgI('<polyline points="16 3 21 3 21 8"/><line x1="4" y1="20" x2="21" y2="3"/><polyline points="21 16 21 21 16 21"/><line x1="15" y1="15" x2="21" y2="21"/><line x1="4" y1="4" x2="9" y2="9"/>'),
  site: svgI('<circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/>'),
  sub: svgI('<path d="M8 17l4 4 4-4"/><path d="M12 12v9"/><path d="M20.88 18.09A5 5 0 0018 9h-1.26A8 8 0 103 16.29"/>'),
  rules: svgI('<line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 01-9 9"/>'),
  dns: svgI('<rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><line x1="7" y1="7" x2="7.01" y2="7"/><line x1="7" y1="17" x2="7.01" y2="17"/>'),
  core: svgI('<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 1v3M15 1v3M9 20v3M15 20v3M1 9h3M1 15h3M20 9h3M20 15h3"/>'),
  user: svgI('<circle cx="12" cy="8" r="4"/><path d="M4 20c0-4 3.58-7 8-7s8 3 8 7"/>'),
};
// Which Settings → Notifications toggle an event type answers to (none: never a notification).
const EV_NOTIF = {
  'auto/switched': 'autoSwitch', 'auto/fastest': 'autoSwitch', 'auto/unstable': 'unstable',
  'conn/lost': 'connLost', 'conn/restored': 'connLost', 'conn/offline': 'connLost', 'conn/online': 'connLost',
  'core/crashed': 'coreCrash', 'core/restarted': 'coreCrash', 'core/restartFailed': 'coreCrash',
  'core/down': 'connLost',
  'site/blocked': 'blocked', 'sub/updated': 'subUpdated',
  'sub/failed': 'subFailed', 'sub/removed': 'subFailed', 'sub/back': 'subFailed', 'sub/dead': 'subFailed',
  'rules/ruleSetFailed': 'ruleSets',
  'rules/fallback': 'autoSwitch', 'rules/targetBack': 'autoSwitch', 'dns/switched': 'autoSwitch',
};

/* ── Words: the structured data → the sentences ── */

const evEntry = id => { if (id == null || id === '') return ''; const e = connectEntry(id); return e ? e.name : String(id); };
const evServer = k => { if (k == null || k === '') return ''; const n = nodeOfKey(String(k)); return n ? n.name : String(k); };
const evSource = (sid, name) => (sourcesData[sid] && sourcesData[sid].name) || name || String(sid || '');
// A switch between two servers: when both show the same name (another protocol, or another address),
// the protocol is appended ("· HY2"), and when that is the same too, the address:port.
function evServerPair(from, to) {
  const a = evServer(from), b = evServer(to);
  if (!from || !to || a !== b) return [a, b];
  const na = nodeOfKey(String(from)), nb = nodeOfKey(String(to));
  if (!na || !nb || String(from) === String(to)) return [a, b];
  const pa = String(protoLabel(na)).toUpperCase(), pb = String(protoLabel(nb)).toUpperCase();
  return pa !== pb ? [`${a} · ${pa}`, `${b} · ${pb}`] : [`${a} · ${na.address}:${na.port}`, `${b} · ${nb.address}:${nb.port}`];
}
const evName = k => String(k).includes('::') ? evServer(k) : evEntry(k);   // 'sid::nid' is a server, anything else an entry
function evDuration(ms) {
  const s = Math.round(ms / 1000);
  return s < 90 ? s + ' s' : s < 5400 ? Math.round(s / 60) + ' min' : Math.floor(s / 3600) + ' h ' + Math.round((s % 3600) / 60) + ' min';
}
function evReason(d) {
  const [from, to] = d.route ? evServerPair(d.from, d.to) : [evEntry(d.from), evEntry(d.to)];
  if (d.reason === 'failover') return `${from} failed${d.fails ? ' ' + d.fails + ' checks' : ' its checks'}`;
  if (d.reason === 'back') return `${to} is back — returned to it`;
  if (d.reason === 'fastest') return `${to} is faster`;
  return d.reason ? String(d.reason) : '';
}
const evPlural = (n, one, many) => n + ' ' + (n === 1 ? one : many);
const evDns = id => (dnsServers[id] && dnsServers[id].name) || String(id);
// "Rule Streaming and 2 more"; an app when no rule is involved: "App Telegram"
const evRules = d => (d.rule ? `Rule ${d.rule}` : `App ${d.app}`) + (d.more ? ` and ${evPlural(d.more, 'more', 'more')}` : '');
const EV_FALLBACK = { block: 'blocked while it is down', direct: 'goes direct', main: 'goes through the main flow' };
const EV_TEXT = {
  'conn/connected': d => ['Connected' + (d.entry ? ': ' + evEntry(d.entry) : ''),
    [d.server && evServer(d.server), d.mode === 'tun' ? 'TUN' : d.mode === 'proxy' ? 'Proxy' : '', d.route === 'global' ? 'Global' : d.route === 'rules' ? 'By rules' : ''].filter(Boolean).join(' · ')],
  'conn/disconnected': d => ['Disconnected', d.by === 'error' ? d.reason || 'The connection dropped' : 'You disconnected'],
  'conn/connectFailed': d => ['Could not connect', d.reason || ''],
  'conn/lost': () => ['Connection lost', 'No route answers — waiting for the network'],
  'conn/restored': d => ['Connection restored', d.downMs != null ? 'Down for ' + evDuration(d.downMs) : ''],
  'conn/offline': () => ['No network', 'The system reports no connection'],
  'conn/online': d => ['Network is back', d.downMs != null ? 'Down for ' + evDuration(d.downMs) : ''],
  'auto/switched': d => { const [f, t] = evServerPair(d.from, d.to); return [d.route ? `Auto: ${evEntry(d.route)} — ${f} → ${t}` : `Auto: ${evEntry(d.from)} → ${evEntry(d.to)}`, evReason(d)]; },
  'auto/fastest': d => { const [f, t] = evServerPair(d.from, d.to); return [`Fastest: ${evEntry(d.route)} — ${f} → ${t}`, `${t} is now the fastest`]; },
  'auto/unstable': d => [`${evEntry(d.id)} is unstable`, `Dropped ${d.strikes}× — back to it after ${Math.max(1, Math.round(d.holdMs / 60000))} min without drops`],
  'site/blocked': d => {
    const host = d.host || destHost(String(d.dest || '')), entry = d.entry || d.route;
    return [`${host} does not open`, (entry ? `Not via ${evEntry(entry)}${d.server ? ' (' + evServer(d.server) + ')' : ''}` : '') + (d.via ? `${entry ? ' — it does' : 'It does'} via ${evEntry(d.via)}` : '')];
  },
  'sub/updated': d => [`${evSource(d.source, d.name)} updated`, [evPlural(d.total, 'server', 'servers'), d.added ? d.added + ' new' : '', d.removed ? d.removed + ' removed' : ''].filter(Boolean).join(' · ')],
  'sub/failed': d => [`${evSource(d.source, d.name)}: update failed`, d.error || ''],
  'sub/removed': d => [`${evSource(d.source, d.name)}: the provider removed ${evPlural(d.count, 'server', 'servers')}`, 'See Unavailable in Nodes — their settings are kept'],
  'sub/back': d => [`${evSource(d.source, d.name)}: ${evPlural(d.count, 'server is', 'servers are')} back`, 'Previous settings restored'],
  'sub/dead': d => [`${evSource(d.source, d.name)}: its servers do not respond`, "Contact the subscription provider's support"],
  'rules/ruleSetFailed': d => [`Rule set ${d.tag} not downloaded`, [d.error, 'the last copy is used'].filter(Boolean).join(' — ')],
  'rules/ruleSetUpdated': d => [`Rule set ${d.tag} updated`, ''],
  'rules/fallback': d => [`${targetName(d.target)} does not answer`, `${evRules(d)} ${EV_FALLBACK[d.to] || d.to}`],
  'rules/targetBack': d => [`${targetName(d.target)} answers again`, `${evRules(d)} back through it`],
  'dns/switched': d => [`DNS: ${evDns(d.from)} → ${evDns(d.to)}`,
    d.reason === 'failover' ? `${evDns(d.from)} does not answer` : d.reason === 'back' ? `${evDns(d.to)} answers again — returned to it` : 'Switch automatically is off: the first server is back'],
  'core/crashed': d => ['sing-box stopped', (d.code != null ? 'Exit code ' + d.code + ' — ' : '') + 'starting it again'],
  'core/restarted': d => ['sing-box started again', [d.attempt && 'Attempt ' + d.attempt, d.downMs != null && 'was down ' + evDuration(d.downMs)].filter(Boolean).join(' · ')],
  'core/down': d => ['VPN is down', d.proxy === 'kept' ? 'Internet is blocked (the system proxy is kept) — still trying' : 'Traffic goes direct — still trying'],
  'core/restartFailed': d => ['sing-box could not start again', [d.attempt && 'Attempt ' + d.attempt, d.error].filter(Boolean).join(' · ')],
  'core/sysProxy': d => d.by === 'user' ? ['You ' + (d.on ? 'set' : 'removed') + ' the system proxy', 'From the VPN is down / Kill switch notice'] : [d.error ?'System proxy could not be ' + (d.on ? 'set' : 'restored') : 'System proxy ' + (d.on ? 'on' : 'off'), d.error || ''],
  'core/deprecated': d => ['sing-box: a deprecated setting', d.text || ''],
};
const EV_USER = {
  connect: d => ['You connected', evEntry(d.entry)],
  disconnect: () => ['You disconnected', ''],
  pin: d => d.server ? ['You pinned ' + evServer(d.server), evEntry(d.entry)] : ['You unpinned the server', evEntry(d.entry)],
  mode: d => ['You switched to ' + (d.value === 'tun' ? 'TUN' : 'Proxy') + ' mode', ''],
  route: d => ['You switched to ' + (d.value === 'global' ? 'Global' : 'By rules'), ''],
  sysProxy: d => ['You turned the system proxy ' + (d.on ? 'on' : 'off'), ''],
};
function evDescribe(e) {
  const d = e.data || {}, f = e.cat === 'user' ? EV_USER[e.type] : EV_TEXT[e.cat + '/' + e.type];
  const [title, detail] = f ? f(d) : [e.cat + ' / ' + e.type, ''];
  return { title, detail: detail || '' };
}
// One line, for a notification and the export.
function evText(e) { const d = evDescribe(e); return d.title + (d.detail ? ' — ' + d.detail : ''); }

// The expanded row: every field of the event in words.
const EV_FIELD = { entry: 'Entry', server: 'Server', mode: 'Mode', route: 'Route', from: 'From', to: 'To', reason: 'Reason', by: 'By', host: 'Site', dest: 'Address', via: 'Opens via',
  source: 'Subscription', name: 'Name', added: 'New servers', removed: 'Removed', total: 'Servers', count: 'Servers', error: 'Error', tag: 'Rule set', url: 'URL', code: 'Exit code',
  rule: 'Rule', app: 'App', target: 'Target', more: 'More rules and apps',
  attempt: 'Attempt', downMs: 'Down for', holdMs: 'Waits', strikes: 'Drops', fails: 'Failed checks', id: 'Entry', on: 'State', action: 'Action', value: 'Value', text: 'Text' };
function evValue(k, v, e) {
  if (e && e.cat === 'dns') {
    if (k === 'from' || k === 'to') return evDns(v);
    if (k === 'reason') return { failover: 'It stopped answering', back: 'A higher server answers again', off: 'Switch automatically turned off' }[v] || String(v);
  }
  if (e && e.cat === 'rules') {
    if (k === 'target') return targetName(v);
    if (k === 'to') return { block: 'Block', direct: 'Direct', main: 'Main flow' }[v] || String(v);
  }
  if (typeof v === 'boolean') return k === 'on' ? (v ? 'On' : 'Off') : v ? 'Yes' : 'No';
  if (k === 'downMs' || k === 'holdMs') return evDuration(v);
  if (k === 'mode') return v === 'tun' ? 'TUN' : v === 'proxy' ? 'Proxy' : String(v);
  if (k === 'route' && (v === 'global' || v === 'rules')) return v === 'global' ? 'Global' : 'By rules';
  if (k === 'by') return v === 'user' ? 'You' : 'An error';
  if (k === 'source') return evSource(v);
  if ((k === 'from' || k === 'to') && e && e.cat === 'auto' && e.data && e.data.route && typeof v === 'string') return evServerPair(e.data.from, e.data.to)[k === 'from' ? 0 : 1];
  if (['entry', 'server', 'route', 'from', 'to', 'via', 'id'].includes(k) && typeof v === 'string') return evName(v);
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}
const evStamp = t => { const d = new Date(t); return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' }) + ' ' + logTime(t); };
function evFieldsHtml(g) {
  const e = g.ev, f = (k, v) => `<div class="ev-f"><span>${esc(k)}</span><b>${esc(v)}</b></div>`;
  let h = g.items.length > 1 ? f('Times', g.items.map(x => logTime(x.at)).join(', ')) : f('Time', evStamp(e.at));
  h += f('Event', e.cat + ' / ' + e.type + (e.own ? ' (yours)' : ''));
  Object.entries(e.data || {}).forEach(([k, v]) => { if (v != null && v !== '') h += f(EV_FIELD[k] || k.charAt(0).toUpperCase() + k.slice(1), evValue(k, v, e)); });
  return h;
}

/* ── Rows: repeats folded, day separators, actions ── */

const EV_KEYF = { 'site/blocked': ['host', 'entry'], 'auto/switched': ['route', 'from', 'to'], 'auto/fastest': ['route', 'from', 'to'], 'auto/unstable': ['id'], 'rules/fallback': ['target', 'to'], 'rules/targetBack': ['target'], 'dns/switched': ['from', 'to'], 'rules/ruleSetFailed': ['tag'], 'rules/ruleSetUpdated': ['tag'] };
function evKey(e) {
  const t = e.cat + '/' + e.type, d = e.data || {}, f = EV_KEYF[t] || (e.cat === 'sub' ? ['source'] : null);
  return t + '|' + (f ? f.map(k => d[k]).join('|') : e.cat === 'user' ? JSON.stringify(d) : '');
}
// The same event again within 10 minutes of its last time is one row: ×N, the last time; the
// row then sits where its last time puts it.
function evGroups(list) {
  const groups = [], last = new Map(), rank = { info: 0, warn: 1, error: 2 };
  list.forEach(e => {
    const k = evKey(e), g = last.get(k);
    if (g && e.at - g.at <= EV_REPEAT_MS) {
      g.items.push(e); g.at = e.at; g.ev = e;
      if (rank[e.level] > rank[g.level]) g.level = e.level;
      groups.splice(groups.indexOf(g), 1); groups.push(g);
    } else { const n = { key: e.id, items: [e], at: e.at, ev: e, level: e.level }; groups.push(n); last.set(k, n); }
  });
  return groups;
}
const evDayStart = t => { const d = new Date(t); return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime(); };
function evDayLabel(t) {
  const diff = Math.round((evDayStart(Date.now()) - evDayStart(t)) / 864e5);
  return diff === 0 ? 'Today' : diff === 1 ? 'Yesterday' : new Date(t).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
}
const evClock = t => logTime(t).slice(0, 5);

function evActions(e) {
  const d = e.data || {}, a = [];
  if (e.cat === 'site' && e.type === 'blocked' && d.via) a.push(['rule', 'Rule']);
  if (e.cat === 'sub' && e.type === 'failed' && sourcesData[d.source] && sourcesData[d.source].kind === 'sub') a.push(['retry', 'Retry']);
  if (evOpenTarget(e)) a.push(['open', 'Open']);
  if (e.log != null) a.push(['raw', 'In raw log']);
  return a;
}
function evOpenTarget(e) {
  const d = e.data || {};
  if (e.cat === 'sub') return sourcesData[d.source] ? d.source : null;
  if (e.cat === 'auto' && e.type === 'unstable') return connectEntry(d.id) ? d.id : null;
  if (e.cat === 'site') return d.entry && connectEntry(d.entry) ? d.entry : null;
  if (e.cat === 'rules') return e.type === 'fallback' || e.type === 'targetBack' ? 'rulelist' : 'rules';
  if (e.cat === 'dns') return 'dns';
  return null;
}
function evAct(key, id) {
  const e = evState.list.find(x => x.id === id), d = e && e.data || {};
  if (!e) return;
  if (key === 'rule') openBlockedRule({ dest: d.dest || d.host, via: d.via });
  else if (key === 'retry') updateSource(d.source);
  else if (key === 'raw') showRawLine(e.log);
  else if (key === 'open') {
    const t = evOpenTarget(e);
    if (t === 'rules') { openRuleSets(); return; }
    if (t === 'rulelist') { openRules(); return; }
    if (t === 'dns') { openDnsSettings(); return; }
    switchTab('nodes');
    setNodesTab(catalogOrder.simple.includes(t) ? 'simple' : 'profiles');
    expandState[t] = true;
    renderNodes();
    requestAnimationFrame(() => { const c = document.querySelector('#view-nodes .src-card[data-id="' + t + '"]'); if (c) c.scrollIntoView({ block: 'center' }); });
  }
}

function evRowHtml(g) {
  const e = g.ev, d = evDescribe(e), acts = evActions(e), rep = g.items.length;
  const tag = g.level === 'warn' || g.level === 'error' ? `<span class="log-tag ${g.level}">${g.level === 'warn' ? 'WARN' : 'ERROR'}</span>` : '';
  const repH = rep > 1 ? `<span class="ev-rep">×${rep}</span>` : '', timeH = `<span class="ev-time">${evClock(g.at)}</span>`;
  // the meta line (level for warnings / errors, repeats, time), the title on its own line below
  const top = `<div class="ev-meta">${timeH}${tag}${repH}</div><div class="ev-title">${esc(d.title)}</div>`;
  return `<div class="ev-row cat-${e.cat} lvl-${g.level}${evState.open.has(g.key) ? ' open' : ''}" data-key="${g.key}" data-ids="${g.items.map(x => x.id).join(',')}" onclick="evToggle(${g.key})">
    <div class="ev-ico">${EV_ICON[e.cat] || ''}</div>
    <div class="ev-body">
      ${top}
      ${d.detail ? `<div class="ev-detail">${esc(d.detail)}</div>` : ''}
      ${acts.length ? `<div class="ev-acts">${acts.map(([k, l]) => `<button class="ev-act" onclick="event.stopPropagation();evAct('${k}',${e.id})">${l}</button>`).join('')}</div>` : ''}
      <div class="ev-more">${evFieldsHtml(g)}</div>
    </div></div>`;
}
function evToggle(key) {
  const row = document.querySelector('#evList .ev-row[data-key="' + key + '"]');
  if (evState.open.delete(key)) row.classList.remove('open');
  else { evState.open.add(key); row.classList.add('open'); }
}

/* ── Filter: temporary (evFilter) + Show my actions (kept, logCfg) ── */

const evTypeKey = e => e.cat + '/' + e.type;
function evVisible(e) {
  if (e.cat === 'user' && !logCfg.showOwn) return false;
  if (evFilter.problems && e.level === 'info') return false;
  if (evFilter.off.has(evTypeKey(e))) return false;
  if (evFilter.q && !(evText(e) + ' ' + Object.values(e.data || {}).join(' ')).toLowerCase().includes(evFilter.q)) return false;
  return true;
}
const evOffCats = () => EV_CATS.filter(([c, , ts]) => ts.some(([t]) => evFilter.off.has(c + '/' + t)));
const evFilterCount = () => (evFilter.q ? 1 : 0) + (evFilter.problems ? 1 : 0) + evOffCats().length;
function evFilterText() {
  const parts = [];
  if (evFilter.q) parts.push('“' + evFilter.q + '”');
  if (evFilter.problems) parts.push('only problems');
  evOffCats().forEach(([c, label, ts]) => {
    const n = ts.filter(([t]) => !evFilter.off.has(c + '/' + t)).length;
    parts.push(n ? `${label} ${n}/${ts.length}` : 'no ' + label);
  });
  return parts.join(' · ');
}
function renderEvFilterBar() {
  const n = evFilterCount(), bar = document.getElementById('evFilterBar'), badge = document.getElementById('evFilterBadge');
  badge.style.display = n ? '' : 'none';
  badge.textContent = n;
  document.getElementById('evFilterBtn').classList.toggle('on', n > 0);
  bar.style.display = n && logTab === 'events' ? '' : 'none';
  bar.innerHTML = `<span class="evfb-text">Filtered: ${esc(evFilterText())}</span><button class="evfb-reset" onclick="evResetFilter()">Reset</button>`;
}
// A filter changed: the list is built again and stays at the bottom if it was there.
function evRefilter() {
  renderEvents();
  evFollowIfPinned();
  renderEvFilterBar();
  renderLogSummary();
  if (document.getElementById('sh-evfilter').classList.contains('open')) renderEvFilter();
  evMarkSeenSoon();
}
function setEvQuery(v) { evFilter.q = v.trim().toLowerCase(); evRefilter(); }
function setEvProblems(v) { evFilter.problems = v; evRefilter(); }
function evResetFilter() { evFilter.q = ''; evFilter.problems = false; evFilter.off.clear(); document.getElementById('evQ').value = ''; evRefilter(); }
function evToggleType(key) { if (!evFilter.off.delete(key)) evFilter.off.add(key); evRefilter(); }
// All of a category's types on → all off; otherwise → all on.
function evToggleCat(cat) {
  const types = EV_CATS.find(c => c[0] === cat)[2].map(([t]) => cat + '/' + t), allOn = types.every(k => !evFilter.off.has(k));
  types.forEach(k => allOn ? evFilter.off.add(k) : evFilter.off.delete(k));
  evRefilter();
}
function evFilterFold(cat) { if (!evFilterOpen.delete(cat)) evFilterOpen.add(cat); renderEvFilter(); }
function setShowOwn(v) { logCfg.showOwn = v; evRefilter(); liveSave(); }

function openEvFilter() {
  document.getElementById('evQ').value = evFilter.q;
  renderEvFilter();
  openSheet('evfilter');
}
function renderEvFilter() {
  const toggle = (on, fn) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${fn}"><div class="mini-toggle-thumb"></div></div>`;
  const check = st => `<div class="evf-check ${st}">${st === 'on' ? '✓' : st === 'part' ? '–' : ''}</div>`;
  const cat = ([c, label, types]) => {
    const n = types.filter(([t]) => !evFilter.off.has(c + '/' + t)).length, st = n === types.length ? 'on' : n ? 'part' : '', open = evFilterOpen.has(c);
    return `<div class="evf-cat cat-${c}" data-cat="${c}">
      <div class="set-row evf-head"><span onclick="evToggleCat('${c}')">${check(st)}</span>
        <div class="evf-name" onclick="evFilterFold('${c}')"><span class="evf-ico">${EV_ICON[c]}</span>${label}<span class="evf-n">${n}/${types.length}</span></div>
        <div class="evf-chev ${open ? 'open' : ''}" onclick="evFilterFold('${c}')">›</div></div>
      ${open ? types.map(([t, tl]) => `<div class="set-row evf-type" data-type="${c}/${t}" onclick="evToggleType('${c}/${t}')">${check(evFilter.off.has(c + '/' + t) ? '' : 'on')}<div class="evf-name">${tl}</div></div>`).join('') : ''}
    </div>`;
  };
  document.getElementById('evfilter-body').innerHTML = `
    <div class="set-group"><div class="set-row" data-key="problems"><div class="set-label" style="flex:1">Only problems<div class="set-hint">Warnings and errors</div></div>${toggle(evFilter.problems, `setEvProblems(${!evFilter.problems})`)}</div></div>
    <div class="set-caption">Categories</div>
    <div class="set-group">${EV_CATS.map(cat).join('')}</div>
    ${evFilterCount() ? '<div class="evf-reset"><button class="ev-act" onclick="evResetFilter()">Reset the filter</button></div>' : ''}
    <div class="set-caption">Kept with your settings</div>
    <div class="set-group evf-kept"><div class="set-row" data-key="showOwn"><div class="set-label" style="flex:1">Show my actions<div class="set-hint">Connect, disconnect, pin, mode and route switches, system proxy. The filter above is forgotten when the app restarts; this switch is not.</div></div>${toggle(logCfg.showOwn, `setShowOwn(${!logCfg.showOwn})`)}</div></div>`;
}

/* ── The list ── */

function renderEvents() {
  const box = document.getElementById('evScroll'), list = document.getElementById('evList'), top = box.scrollTop;
  const shown = evState.list.filter(evVisible), groups = evGroups(shown);
  evState.shown = shown.length;
  let html = '', day = null;
  groups.forEach(g => {
    const dk = evDayStart(g.at);
    if (dk !== day) { day = dk; html += `<div class="ev-day">${evDayLabel(g.at)}</div>`; }
    html += evRowHtml(g);
  });
  list.innerHTML = html || `<div class="log-empty">${evState.list.length ? 'No events match the filter' : 'No events yet'}</div>`;
  if (!evState.follow && box.clientHeight) box.scrollTop = top;
}
function evSummaryText() {
  const all = evState.list, warn = all.filter(e => e.level === 'warn').length, err = all.filter(e => e.level === 'error').length;
  return (evFilterCount() ? evState.shown + ' of ' : '') + evPlural(all.length, 'event', 'events')
    + (err ? ' · ' + evPlural(err, 'error', 'errors') : '') + (warn ? ' · ' + evPlural(warn, 'warning', 'warnings') : '');
}

/* Follow: at the bottom, a new event scrolls smoothly to itself; scrolled up, the view stays
   and the pill counts the new ones. The scroll handler ignores the smooth scroll's own
   steps (the bottom is still a few pixels away while it runs). */
function evScrollBottom(smooth) {
  const box = document.getElementById('evScroll');
  if (!box.clientHeight) return;
  if (smooth) { evState.smoothUntil = Date.now() + 700; box.scrollTo({ top: box.scrollHeight, behavior: 'smooth' }); }
  else box.scrollTop = box.scrollHeight;
}
function evFollowIfPinned(smooth) { if (evState.follow) evScrollBottom(smooth); }
function evFollow(smooth) {
  evState.follow = true;
  evState.unseen = 0;
  evScrollBottom(smooth);
  renderLogSummary();
  evMarkSeenSoon();
}
function evScrolled() {
  const box = document.getElementById('evScroll'), atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 24;
  evMarkSeenSoon();
  if (!atEnd && evState.follow && Date.now() < evState.smoothUntil) return;
  if (atEnd === evState.follow) return;
  evState.follow = atEnd;
  if (atEnd) evState.unseen = 0;
  renderLogSummary();
}

/* ── Seen: the dots on the Logs tab ── */

let evSeenTimer = null;
const evMarkSeenSoon = () => { if (!evSeenTimer) evSeenTimer = setTimeout(() => { evSeenTimer = null; evMarkSeen(); }, 150); };
// The warnings / errors whose row is in the list's viewport are seen (a folded row: all its repeats).
function evMarkSeen() {
  if (!logsOpen() || logTab !== 'events') return;
  const r = document.getElementById('evScroll').getBoundingClientRect();
  if (!r.height) return;
  const ids = [];
  document.querySelectorAll('#evList .ev-row.lvl-warn, #evList .ev-row.lvl-error').forEach(row => {
    const b = row.getBoundingClientRect();
    if (b.bottom > r.top + 8 && b.top < r.bottom - 8) ids.push(...row.dataset.ids.split(',').map(Number));
  });
  evMarkIds(ids);
}
function evMarkIds(ids) {
  const seen = new Set(logCfg.seen), n = seen.size;
  ids.forEach(id => seen.add(id));
  if (seen.size === n) return;
  logCfg.seen = [...seen];
  renderNavDots();
  liveSave();
}
// red = an unseen error, yellow = an unseen warning (both may show); hidden-by-filter ones count
function renderNavDots() {
  const seen = new Set(logCfg.seen), unseen = lvl => evState.list.some(e => e.level === lvl && !seen.has(e.id));
  const err = unseen('error'), warn = unseen('warn'), E = document.getElementById('navDotErr'), W = document.getElementById('navDotWarn');
  E.classList.toggle('on', err); W.classList.toggle('on', warn);
  E.classList.toggle('both', err && warn); W.classList.toggle('both', err && warn);
}

/* ── The journal: poll, notify, add, clear ── */

function pollEvents() {
  if (evState.busy) { evState.again = true; return evState.busy; }   // asked again meanwhile (an event was just added): once more after
  const gen = evState.gen, first = evState.next == null;
  return evState.busy = backend.events(evState.next).then(r => {
    if (gen !== evState.gen) return;
    // numbering started over (the core's data was reset): read the journal again, notify nothing
    if (!first && r.next < evState.next) { evState.next = null; evState.list = []; return; }
    const n0 = evState.list.length;
    if (r.first != null) evState.list = evState.list.filter(e => e.id >= r.first);   // pruned, or cleared elsewhere
    const fresh = r.events.filter(e => first || e.id >= evState.next);
    if (first) evState.notifyFrom = r.next;   // what was there when the page looked is history: never a notification
    evState.next = r.next;
    evState.list.push(...fresh);
    if (evState.list.length > EV_KEEP) evState.list.splice(0, evState.list.length - EV_KEEP);
    const ids = new Set(evState.list.map(e => e.id)), seen = logCfg.seen.filter(id => ids.has(id));
    if (seen.length !== logCfg.seen.length) { logCfg.seen = seen; liveSave(); }
    if (fresh.length || first || evState.list.length !== n0) evAfterNew(fresh, first);
    fresh.filter(e => e.id >= evState.notifyFrom && !e.own).forEach(evNotify);
  }, () => {}).finally(() => { evState.busy = null; if (evState.again) { evState.again = false; pollEvents(); } });
}
function evAfterNew(fresh, first) {
  const open = logsOpen() && logTab === 'events';
  renderEvents();
  if (open) {
    if (evState.follow) evScrollBottom(!first);
    else evState.unseen += fresh.filter(evVisible).length;
  }
  renderLogSummary();
  renderNavDots();
  evMarkSeenSoon();
}
// A background event → its notification (Settings → Notifications decides). Tap → the event in Logs.
function evNotify(e) {
  const kind = EV_NOTIF[evTypeKey(e)];
  if (!kind) return;
  notify(kind, evText(e), e.cat === 'site' && e.data && e.data.via ? { label: 'Rule', fn: () => evAct('rule', e.id) } : null, e.id);
}
let evTick = 0;
setInterval(() => { if (!document.hidden && (logsOpen() && logTab === 'events' || (++evTick) % 3 === 0)) pollEvents(); }, 1000);

setTimeout(pollEvents, 0);

// What only the UI knows goes into the journal: a subscription's result, the user's own action.
// opts: level ('info'), own (true for cat 'user'). The list follows at once.
function journal(cat, type, data, opts) {
  const o = opts || {};
  return backend.addEvent({ cat, type, level: o.level || 'info', own: o.own != null ? o.own : cat === 'user', data: data || {} })
    .then(() => pollEvents(), () => {});
}

// A notification was tapped: Logs → Events at that event (the filter cleared if it hides it).
function openEventInLogs(id) {
  switchTab('logs');
  const e = evState.list.find(x => x.id === id);
  if (e && !evVisible(e)) evResetFilter();
  const row = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id)));
  if (!row) return;
  evMarkIds(row.dataset.ids.split(',').map(Number));
  row.scrollIntoView({ block: 'center' });
  row.classList.add('hit');
  setTimeout(() => row.classList.remove('hit'), 2600);
  evScrolled();
}

function confirmClearEvents() {
  openActions('Clear events?', '<div class="menu-note">The events list is emptied. The raw log stays as it is.</div>'
    + menuRow(ICON.trash, 'Clear events', "closeSheet('actions');clearEvents()", 'danger')
    + menuRow(ICON.close, 'Cancel', "closeSheet('actions')"));
}
function clearEvents() {
  evState.gen++;
  backend.clearEvents().then(() => {
    evState.gen++;
    evState.list = [];
    evState.follow = true;
    evState.unseen = 0;
    logCfg.seen = [];
    renderEvents(); renderNavDots(); renderLogSummary();
    liveSave();
  }, e => toast('Not cleared: ' + e.message));
}

// Both logs as text: the events (readable), then the raw lines.
function logsExportText() {
  return Promise.all([backend.events(0), backend.log(null)]).then(([ev, raw]) => {
    const events = ev.events.map(e => `${new Date(e.at).toISOString()} ${e.level.toUpperCase().padEnd(5)} ${e.own ? '[you] ' : ''}${evText(e)}`).join('\n');
    return `Jormungand logs, ${new Date().toISOString()}\n\n== Events (${ev.events.length}) ==\n${events}\n\n== Raw log (${raw.lines.length} lines) ==\n${rawLogText(raw.lines)}\n`;
  });
}
function exportLogs() {
  logsExportText().then(text => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
    a.download = 'jormungand-logs-' + new Date().toISOString().slice(0, 10) + '.txt';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    toast('Logs saved: ' + a.download);
  }, e => toast('Export failed: ' + e.message));
}
