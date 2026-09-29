/* ══════════════════════ LIVE MODE (Dart core) ══════════════════════
   When the Dart core serves the page (core/bin/jormd.dart sets window.JORMD), `backend`
   talks to it over /api and the mock data gives way to the state the core keeps: the
   UI's own state (sources with their nodes, profiles, chains, order, switches) as one
   snapshot, saved after every change. The core fetches and parses subscriptions,
   builds the sing-box config, runs sing-box and measures latency.
   Opened as a file, as the Artifact or from the Cloudflare site nothing here runs. */

const live = { ready: false, saveTimer: null, planSig: null, reconnectTimer: null, pairQueue: null };

function api(path, body, method) {
  return fetch(path, {
    method: method || (body ? 'POST' : 'GET'),
    headers: { 'X-Jorm': '1', 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  }).then(r => r.json().catch(() => ({})).then(j => {
    if (!r.ok) throw new Error(j.error || 'HTTP ' + r.status);
    return j;
  }));
}

// /api/ping streams one JSON line per result as soon as it is measured; each goes to
// onLine at once. Resolves when the stream ends; rejects on a failed request.
function apiPing(body, onLine) {
  // Settings → Connection → Latency test URL
  return ndjson('/api/ping', Object.assign({ url: connCfg.testUrl || undefined, checkers: connCfg.checkers }, body), onLine);
}
// A POST whose answer is NDJSON (/api/ping, /api/speedtest): each line to onLine as it comes.
function ndjson(path, body, onLine, signal) {
  return fetch(path, {
    method: 'POST',
    headers: { 'X-Jorm': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  }).then(async r => {
    if (!r.ok || !r.body) throw new Error('HTTP ' + r.status);
    const reader = r.body.getReader(), dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { value, done } = await reader.read();
      buf += dec.decode(value || new Uint8Array(), { stream: !done });
      const lines = buf.split('\n');
      buf = lines.pop();
      lines.filter(Boolean).forEach(l => {
        const j = JSON.parse(l);
        if (j.error) throw new Error(j.error);
        onLine(j);
      });
      if (done) break;
    }
  });
}

/* ── State kept by the core ── */

function liveSnapshot() {
  return { sourcesData, sourceOrder, sourceSeq, connectMode, connectOrder, activeConnectId, autoConnect, pinnedNode,
    modeState, profilesData, profileSeq, chainsData, chainSeq, catalogOrder, routeCustom, segState, connCfg, autoCfg, genCfg, notifCfg, logCfg,
    // Rules, apps, rule sets, DNS (sent to the core as plan.routing, see 93-routing-plan.js)
    rulesData, ruleOrder, ruleSeq, quickCfg, appRules, ruleSets, rsSeq, dnsServers, dnsOrder, dnsSeq, dnsCfg,
    // measured pings survive a restart, so Auto starts from what it knew
    pings: [...pingCache].filter(([, e]) => typeof e.ms === 'number') };
}
const replaceObj = (target, src) => { Object.keys(target).forEach(k => delete target[k]); Object.assign(target, src); };
// null = a first run: nothing added yet.
function liveApply(s) {
  s = s || {};
  sourcesData = s.sourcesData || {};
  sourceOrder = s.sourceOrder || [];
  sourceSeq = s.sourceSeq || 1;
  connectMode = s.connectMode || 'simple';
  connectOrder = s.connectOrder || [];
  activeConnectId = s.activeConnectId || null;
  autoConnect = s.autoConnect !== false;
  pinnedNode = s.pinnedNode || null;
  profilesData = s.profilesData || {};
  profileSeq = s.profileSeq || 1;
  chainsData = s.chainsData || {};
  chainSeq = s.chainSeq || 1;
  replaceObj(modeState, s.modeState || { profiles: { order: [], active: null, auto: true } });
  replaceObj(catalogOrder, s.catalogOrder || { simple: [], profiles: [] });
  replaceObj(routeCustom, s.routeCustom || { simple: false, profiles: false });
  if (s.segState) Object.assign(segState, s.segState);
  if (s.connCfg) Object.assign(connCfg, s.connCfg);
  if (s.autoCfg) Object.assign(autoCfg, s.autoCfg);
  if (s.genCfg) {
    // older states kept the two notification toggles in General
    if ('statusNotif' in s.genCfg && !(s.notifCfg && 'status' in s.notifCfg)) notifCfg.status = s.genCfg.statusNotif;
    if ('switchNotif' in s.genCfg && !(s.notifCfg && 'autoSwitch' in s.notifCfg)) notifCfg.autoSwitch = notifCfg.unstable = s.genCfg.switchNotif;
    const g = Object.assign({}, s.genCfg); delete g.statusNotif; delete g.switchNotif;
    Object.assign(genCfg, g);
  }
  if (s.notifCfg) Object.assign(notifCfg, s.notifCfg);
  if (s.logCfg) { logCfg.showOwn = !!s.logCfg.showOwn; logCfg.seen = Array.isArray(s.logCfg.seen) ? s.logCfg.seen.slice() : []; }
  // no demo rules or apps: a first run starts with the defaults of a fresh install
  rulesData = s.rulesData || {};
  ruleOrder = s.ruleOrder || [];
  ruleSeq = s.ruleSeq || 1;
  appRules = s.appRules || {};
  replaceObj(quickCfg, Object.assign({ regionOn: true, region: 'RU', ads: false, final: 'proxy', fallback: 'main', services: {} }, s.quickCfg));
  SERVICES.forEach(([k]) => { quickCfg.services[k] = quickCfg.services[k] || 'default'; });
  ruleSets = s.ruleSets || ['geosite', 'geoip'].map(id => ({ id, name: id, builtin: true, url: 'built-in', format: 'srs', via: 'vpn', every: 7 * 86400, updated: 'with the first connect' }));
  rsSeq = s.rsSeq || 1;
  if (s.dnsServers) { replaceObj(dnsServers, s.dnsServers); dnsOrder = s.dnsOrder; dnsSeq = s.dnsSeq || 1; }
  if (s.dnsCfg) Object.assign(dnsCfg, s.dnsCfg);
  restorePings(s.pings);   // 15-ping.js: older states keyed a server, not its variant
  // a page closed mid-update saved the spinner: it would block every later update
  Object.values(sourcesData).forEach(x => { delete x.updating; });
  renderEvents(); renderNavDots();   // 47-events.js: the Show my actions switch and the seen marks came with it
}
function liveSave() {
  if (!live.ready) return;          // never overwrite the stored state before it is loaded
  clearTimeout(live.saveTimer);
  live.saveTimer = setTimeout(() => api('/api/state', { snapshot: liveSnapshot() }, 'PUT').catch(e => toast('Not saved: ' + e.message)), 400);
}

/* ── What to connect: the plan the core turns into a sing-box config ── */

const usableRef = r => r.node.outbound && !r.node.unsupported;
function planGroup(refs, pick, chosenRef) {
  const ok = refs.filter(usableRef);
  const bad = refs.find(r => r.node.unsupported);
  if (!ok.length) throw new Error('No server here the core can use' + (bad ? ` (${bad.node.unsupported} is not in sing-box)` : ''));
  // sing-box's urltest uses its first server until its own first round of tests is done
  // (a minute with a hundred servers): put the known fastest first, the dead ones last
  const nodes = pick === 'fastest' ? ok.slice().sort((a, b) => pingRank(a.node) - pingRank(b.node)) : ok;
  return { pick, chosen: pick === 'priority' && chosenRef ? refKey(chosenRef) : null, nodes: nodes.map(r => ({ key: refKey(r), outbound: r.node.outbound })) };
}
// The plan around one entry (anchor; default: the UI's own pick) — main-flow routes:
// 94-live-auto.js, rules / apps / DNS: 93-routing-plan.js. Built on the UI's own picks, not
// the core's (withoutCore), so the core moving a Priority group is no new plan.
function livePlan(anchor) {
  return withoutCore(() => {
    const id = anchor || effectiveConnectId(true);
    if (!id || !connectEntry(id)) throw new Error(nothingInAuto() ? 'Nothing in Auto — turn on Use in Auto in Route' : 'Nothing to connect — add a subscription in Nodes');
    const base = { mixedPort: connCfg.port || 2080, global: segState.route === 'global',
      urlTest: { interval: autoCfg.checkEvery, tolerance: autoCfg.threshold, url: connCfg.testUrl || undefined }, auto: planAuto(), routing: routingPlan() };
    return Object.assign(base, planRoutes(id));
  });
}
/* What a reconnect is worth: the routes, rules and the servers in each group — not their
   ping order (a ping reorders Fastest, in routes and in rule targets alike, and flips
   servers to 'testing': neither may restart sing-box and drop every connection), nor the
   server a main-flow group is on (the core moves those itself; only a Manual pin counts).
   A rule target's Priority pick does count: nothing but a new plan moves it. The system
   proxy is in it: switched while connected, the core gets it with the reconnect. */
function planSigOf(plan) {
  const keys = x => x.pick === 'fastest' ? x.nodes.map(n => n.key).sort() : x.nodes.map(n => n.key);
  // a Priority group with no pick (nothing measured yet) starts on its first server: the same
  const pick = x => x.pick === 'priority' ? x.chosen || (x.nodes[0] && x.nodes[0].key) || null : null;
  const g = x => x && Object.assign({}, x, { chosen: x.pinned ? x.chosen : null, nodes: keys(x) });
  const gt = x => x && Object.assign({}, x, { chosen: pick(x), nodes: keys(x) });
  const r = (x, f) => x && Object.assign({}, x, { main: f(x.main), entry: f(x.entry) });
  const routing = plan.routing && Object.assign({}, plan.routing,
    { targets: Object.fromEntries(Object.entries(plan.routing.targets || {}).map(([k, x]) => [k, r(x, gt)])) });
  // plan.auto is not in it: the running core takes Settings → Auto mode as it is (liveSyncAuto)
  return JSON.stringify(Object.assign({}, plan, { current: null, auto: null, routing, systemProxy: segState.sys === 'on',
    routes: (plan.routes || []).map(x => r(x, g)) }));
}
const planSig = () => { try { return planSigOf(livePlan(liveSigAnchor())); } catch (e) { return null; } };
const pingsRunning = () => [...pingCache.values()].some(v => v.ms === 'testing');

// Connected and the plan changed (another entry, a server switched off, Global/Rules…):
// the core gets the new config. Not mid-ping: the last result re-renders and checks again.
function liveMaybeReconnect() {
  liveSyncAuto();
  if (!live.ready || !connected || connecting || !live.planSig || pingsRunning()) return;
  const sig = planSig();
  if (!sig || sig === live.planSig) { clearTimeout(live.reconnectTimer); return; }
  clearTimeout(live.reconnectTimer);
  live.reconnectTimer = setTimeout(() => {
    if (connected && !connecting && planSig() !== live.planSig) backend.connect().catch(e => toast(e.message));
  }, 600);
}

// Settings → Auto mode changed while connected: the core's Auto takes it at its next check, no reconnect.
function liveSyncAuto() {
  if (!live.ready || !connected || connecting || !live.planSig) return;
  const a = JSON.stringify(planAuto());
  if (a === live.autoSig) return;
  live.autoSig = a;
  backend.autoSettings(planAuto()).catch(e => toast(e.message));
}

/* ── The real backend ── */

/* Subscriptions: the core fetches with the source's own settings (UA, HWID, filter,
   Download via) and answers with a patch of the fields it owns — the same list as
   sourceServerFields in core/lib/src/state.dart. The user's fields are never in it. */
const SERVER_FIELDS = ['nodes', 'gone', 'count', 'uaStrategy', 'discoveredAt', 'usage', 'expire', 'format',
  'providerInterval', 'webPage', 'supportUrl', 'announce', 'updatedAt', 'lastError'];
function liveFetch(s, opts) {
  const source = {};
  ['url', 'userAgent', 'uaStrategy', 'discoveredAt', 'nodes', 'gone', 'hwid', 'filter', 'channel'].forEach(k => { source[k] = s[k]; });
  return api('/api/sources/fetch', { sid: s.id, source, rediscover: !!(opts && opts.rediscover) }).then(r => {
    Object.assign(s, r.patch);
    let host = '';
    try { host = new URL(s.url).hostname; } catch (e) {}
    if (r.title && s.name === host) s.name = r.title;
    if (!r.notModified) liveKeepRunning([s]);
  });
}

/* "Reconnect after update" off: new servers from an update must not restart sing-box. The
   plan they make is taken as the running one, so the next reconnect for another reason
   (another entry, a server switched off…) brings them in. */
function liveKeepRunning(updated) {
  if (!connected || !live.planSig || updated.some(s => s.reloadAfterUpdate)) return;
  const sig = planSig();
  if (sig) live.planSig = sig;
}

/* The core also updates subscriptions on its own timer (core/lib/src/updater.dart), with
   this page closed too. /api/status carries sourcesRev, which moves with each such update:
   then the sources the core updated after us (newer updatedAt, same URL) take its server
   fields; everything the user set stays as it is here. */
function liveSyncSources() {
  if (!live.ready || document.hidden) return;
  api('/api/status').then(st => {
    if (st.sourcesRev === undefined || st.sourcesRev === live.sourcesRev) return;
    return api('/api/state').then(r => {
      live.sourcesRev = r.status.sourcesRev;
      const theirs = (r.snapshot && r.snapshot.sourcesData) || {}, updated = [];
      let failed = false;
      Object.keys(theirs).forEach(sid => {
        const s = sourcesData[sid], t = theirs[sid];
        if (!s || s.kind !== 'sub' || s.updating || s.url !== t.url) return;
        // a timer update that failed: only its lastError (the card's error strip with Retry)
        if (t.lastError && (t.updatedAt || 0) === (s.updatedAt || 0) && t.lastError.at > ((s.lastError && s.lastError.at) || 0)) {
          s.lastError = t.lastError;
          failed = true;   // the core's events journal says so (sub/failed → a notification, 58-notif.js)
        }
        if (!((t.updatedAt || 0) > (s.updatedAt || 0))) return;
        const gone0 = (s.gone || []).length;
        SERVER_FIELDS.forEach(k => { if (k in t) s[k] = t[k]; else delete s[k]; });
        updated.push(s);
        // the core's own sub/updated / sub/failed say the update happened; what it did to the
        // provider's servers (removed / back) is worked out here, so the UI posts those
        const gone1 = (s.gone || []).length, data = { source: sid, name: s.name };
        if (gone1 > gone0) journal('sub', 'removed', Object.assign({ count: gone1 - gone0 }, data), { level: 'warn', own: false });
        else if (gone1 < gone0) journal('sub', 'back', Object.assign({ count: gone0 - gone1 }, data), { own: false });
      });
      if (failed && !updated.length) refreshSourceViews();
      if (!updated.length) return;
      liveKeepRunning(updated);
      purgeExpiredGone();
      refreshSourceViews();
      updated.filter(s => s.testAfterUpdate).forEach(s => testLatency(liveNodes(s).map(n => [s.id, n.id])));
    });
  }).catch(() => {});
}

function flushPairs() {
  const q = live.pairQueue.filter(x => x.entry.outbound && x.exit.outbound);
  live.pairQueue.filter(x => !q.includes(x)).forEach(x => x.resolve(-1));
  live.pairQueue = null;
  if (!q.length) return;
  q.forEach(x => { x.key = x.entry.id + '>' + x.exit.id; });
  // resolve() twice is a no-op, so the final sweep only answers the ones never reported.
  apiPing({ pairs: q.map(x => ({ key: x.key, entry: { outbound: x.entry.outbound }, exit: { outbound: x.exit.outbound } })) },
    l => { if (l.kind === 'p') q.filter(x => x.key === l.key).forEach(x => x.resolve(l.ms)); })
    .catch(() => {}).then(() => q.forEach(x => x.resolve(-1)));
}

const liveBackend = {
  live: true,
  fetchSource: liveFetch,
  updateSource: liveFetch,
  // Links: every server the core's parser finds. Fields: the core builds the outbound; an
  // edit of the same protocol keeps the server's TLS / transport (manual.dart).
  manualNodes(f) {
    if (f.link) return api('/api/parse', { text: f.link }).then(r => {
      if (!r.nodes.length) throw new Error(LINK_FORMS);
      if (r.nodes.length === 1) typedName(r.nodes[0], f);
      return f.edit ? r.nodes.slice(0, 1) : r.nodes;
    });
    const same = f.edit && f.edit.protocol === f.protocol, name = f.name || f.address;
    return api('/api/node', { protocol: f.protocol, address: f.address, port: f.port, secret: f.secret,
      // no flag typed: an edited server keeps its own
      name: f.edit && f.edit.flag !== '🌐' && splitFlagLite(name).flag === '🌐' ? f.edit.flag + ' ' + name : name,
      outbound: same ? f.edit.outbound : undefined, unsupported: same ? f.edit.unsupported : undefined,
    }).then(r => [r.node]);
  },
  speedTest(n, onProgress, signal) {
    if (!n.outbound || n.unsupported) return Promise.reject(new Error('This server cannot be tested (no sing-box outbound)'));
    return ndjson('/api/speedtest', { node: { key: n.id, outbound: n.outbound } }, onProgress, signal);
  },
  shareLink(n) {
    return api('/api/share', { outbound: n.outbound, name: n.name, flag: n.flag === '🌐' ? '' : n.flag, unsupported: n.unsupported }).then(r => r.link);
  },
  log(since) { return api('/api/log' + (since != null ? '?since=' + since : '')); },
  clearLog() { return api('/api/log', null, 'DELETE'); },
  // Events journal (core: events.dart): the same three calls as the mock's.
  events(since) { return api('/api/events' + (since != null ? '?since=' + since : '')); },
  addEvent(ev) { return api('/api/events', { cat: ev.cat, type: ev.type, level: ev.level || 'info', own: !!ev.own, data: ev.data || {} }); },
  clearEvents() { return api('/api/events', null, 'DELETE'); },
  version() { return api('/api/version'); },
  autoSettings(auto) { return api('/api/auto', { auto }); },
  closeConn(id) { return api('/api/connections' + (id ? '/' + encodeURIComponent(id) : ''), null, 'DELETE'); },
  // Backup = the snapshot the core stores; a restore replaces it and loads it at once.
  exportState() { return api('/api/state').then(st => st.snapshot || liveSnapshot()); },
  importState(snap) {
    clearTimeout(live.saveTimer);
    return api('/api/state', { snapshot: snap }, 'PUT').then(() => api('/api/state')).then(st => liveApply(st.snapshot));
  },
  // One core call for the whole batch; the same server in two sources is pinged once.
  ping(nodes, onResult) {
    const ok = nodes.filter(n => n.outbound && !n.unsupported);
    nodes.filter(n => !ok.includes(n)).forEach(n => onResult(n, -1));
    if (!ok.length) return Promise.resolve();
    const uniq = new Map(ok.map(n => [n.id, n])), left = new Set(ok);
    const report = (n, ms) => { if (left.delete(n)) onResult(n, ms); };
    return apiPing({ nodes: [...uniq.values()].map(n => ({ key: n.id, outbound: n.outbound })) },
      l => { if (l.kind === 'n') ok.filter(n => n.id === l.key).forEach(n => report(n, l.ms)); })
      .catch(e => toast('Ping failed: ' + e.message))
      .then(() => [...left].forEach(n => report(n, -1)));
  },
  // Pairs asked in the same moment (a chain check) go to the core as one batch.
  pingPair(entry, exit) {
    return new Promise(resolve => {
      if (!live.pairQueue) { live.pairQueue = []; setTimeout(flushPairs, 30); }
      live.pairQueue.push({ entry, exit, resolve });
    });
  },
  connect(anchor) {
    return Promise.resolve().then(() => {
      const plan = livePlan(anchor);
      if (segState.mode === 'tun') toast('TUN is not in the core yet — proxy on 127.0.0.1:' + (connCfg.port || 2080));
      // Kill switch options as the core reads them (killswitch: rules.md §7); the sub-options only count with their conditions
      const ks = killPlan();
      killSig = JSON.stringify(ks);
      return api('/api/connect', Object.assign({ plan, systemProxy: segState.sys === 'on', dnsAuto: dnsCfg.auto }, ks)).then(st => {
        live.anchor = plan.routes[plan.current].id;
        live.planSig = planSigOf(plan);
        live.autoSig = JSON.stringify(plan.auto);
        liveAutoStatus(st);
        if (st.warning) toast(st.warning);
        liveWatchExit();   // the core checks the exit after every (re)connect
      });
    });
  },
  disconnect() {
    live.planSig = null;
    liveAutoStatus(null);
    return api('/api/disconnect', {}).then(st => { liveVpnState(st, false); return st; });
  },
  releaseSysProxy() { return api('/api/sysproxy/release', {}); },
  retry() { return api('/api/retry', {}); },
  // Kill switch settings changed while connected / down: the core takes them live (same fields as the connect body).
  killSettings(cfg) { return api('/api/killswitch', cfg); },
  // Settings → DNS → Switch automatically changed while connected (the connect body has it too: dnsAuto).
  dnsAuto(on) { return api('/api/dns/auto', { auto: on }); },
  // Connected: the tunnel's exit; not connected: the direct IP (the core knows which).
  traffic() { return api('/api/traffic'); },
  exitIp() {
    return api('/api/exit', {}).then(() => liveWatchExit());
  },
};

// The core's exit check takes a second or two: poll its status until the answer is in
// (a newer watch replaces an older one). Resolves with {ip, country, city?} or {error}.
function liveWatchExit() {
  const seq = live.exitSeq = (live.exitSeq || 0) + 1;
  exitInfo = null;
  renderExitIp();
  return new Promise(resolve => {
    let tries = 0;
    const poll = () => api('/api/status').then(st => {
      if (seq !== live.exitSeq) return;
      if (st.exit || ++tries > 20) {
        exitInfo = st.exit || { error: 'no answer' };
        renderExitIp();
        resolve(exitInfo);
      } else setTimeout(poll, 1000);
    }, () => setTimeout(poll, 1000));
    setTimeout(poll, 700);
  });
}

function livePaste() {
  (navigator.clipboard ? navigator.clipboard.readText() : Promise.reject(new Error('no clipboard'))).then(text => {
    text = text.trim();
    if (/^https?:\/\//i.test(text)) { openSrcForm(null, text); return; }
    if (/^[a-z0-9+.-]+:\/\//i.test(text)) {
      openNodeForm();
      document.getElementById('nf-link').value = text;   // several lines: all of them
      parseNodeLink();
      return;
    }
    toast('No subscription URL or server link in the clipboard');
  }, () => toast('Clipboard is not readable here'));
}

function liveInit() {
  backend = liveBackend;
  window.pasteFromClipboard = livePaste;
  liveApply(null);                  // empty until the stored state arrives
  connected = false;
  ['trafficDown', 'trafficUp'].forEach(id => { document.getElementById(id).textContent = '0 B'; });   // no session yet (the markup has the mock's)
  pingCache.clear();

  // Everything that re-renders after a change also saves and re-checks the connection.
  ['renderAll', 'renderConnects', 'renderNodes', 'renderAutoMode', 'renderConnSettings', 'renderGeneral', 'renderNotif', 'setSegment', 'updateMainConnectCard',
    'renderRules', 'renderApps', 'renderRuleSets', 'renderDns'].forEach(name => {
    const orig = window[name];
    window[name] = function () { const r = orig.apply(this, arguments); liveSave(); liveMaybeReconnect(); return r; };
  });

  api('/api/state').then(st => {
    if (st.snapshot) liveApply(st.snapshot);
    purgeExpiredGone();   // the start-up purge in 99-init ran on the empty pre-load state; only 15-day-old ones go
    connected = !!st.status.connected;
    exitInfo = st.status.exit || null;
    liveVpnState(st.status);
    if (!exitInfo) liveWatchExit();   // still checking (the direct one runs from the core's start)
    renderAutoMode(); renderConnSettings(); renderDns(); renderGeneral(); renderNotif();
    ['mode', 'route', 'sys'].forEach(g => setSegment(g, segState[g]));
    renderConnects(); renderNodes(); renderRules(); updateMainConnectCard(); renderConnState();
    if (connected) {
      liveAutoStatus(st.status);
      live.anchor = liveFindAnchor(live.routes || []);
      live.planSig = planSig();
      live.autoSig = JSON.stringify(planAuto());   // what the running core has is not known: the next change sends it
    }
    live.sourcesRev = st.status.sourcesRev;
    live.ready = true;
    toast(st.snapshot ? 'Core connected' : 'Core connected — add a subscription in Nodes');
    if (genCfg.pingOnLaunch) pingOnLaunch();
    // not when the core is already up (a page reload, another window): only a fresh start connects
    if (genCfg.connectOnLaunch && !connected && !st.status.error) toggleMain();
  }, e => toast('Core not reachable: ' + e.message));

  setInterval(liveSyncSources, 5000);

  // sing-box can stop on its own (bad server, crash): the dock must say so.
  setInterval(() => {
    if (!live.ready || connecting) return;
    // not connected: only the Kill switch plaque (blocking) is read from the core
    if (!connected) { api('/api/status').then(st => { if (!connected && !connecting) liveVpnState(st, false); }, () => {}); return; }
    api('/api/status').then(st => {
      liveAutoStatus(st);   // where the core's Auto is, what it measured (94-live-auto.js)
      if (st.connected) {
        // a check the core finished on its own (e.g. after liveMaybeReconnect)
        if (st.exit && JSON.stringify(st.exit) !== JSON.stringify(exitInfo)) { exitInfo = st.exit; renderExitIp(); }
        return;
      }
      connected = false;
      live.planSig = null;
      renderConnState();   // the core's core/crashed event tells the user (58-notif.js)
    }, () => {});
  }, 4000);
}

if (window.JORMD) liveInit();
