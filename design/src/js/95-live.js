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
  return fetch('/api/ping', {
    method: 'POST',
    headers: { 'X-Jorm': '1', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
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
  return { sourcesData, sourceOrder, sourceSeq, connectMode, connectOrder, activeConnectId, autoConnect,
    modeState, profilesData, profileSeq, chainsData, chainSeq, catalogOrder, routeCustom, segState, connCfg, autoCfg };
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
  if (!ok.length) throw new Error('No server here the core can use' + (refs.some(r => r.node.unsupported) ? ' (XHTTP is not in sing-box)' : ''));
  // sing-box's urltest uses its first server until its own first round of tests is done
  // (a minute with a hundred servers): put the known fastest first, the dead ones last
  const rank = r => isAlive(r.node) ? ping(r.node) : ping(r.node) == null ? 1e9 : 2e9;
  const nodes = pick === 'fastest' ? ok.slice().sort((a, b) => rank(a) - rank(b)) : ok;
  return { pick, chosen: pick === 'priority' && chosenRef ? refKey(chosenRef) : null, nodes: nodes.map(r => ({ key: refKey(r), outbound: r.node.outbound })) };
}
function livePlan() {
  const id = effectiveConnectId();
  if (!id || !connectEntry(id)) throw new Error('Nothing to connect — add a subscription in Nodes');
  const base = { mixedPort: 2080, global: segState.route === 'global',
    urlTest: { interval: autoCfg.checkEvery, tolerance: autoCfg.threshold } };
  if (chainsData[id]) {
    const c = chainsData[id], exits = chainExitRefs(c), exitNode = chainExitNode(c);
    return Object.assign(base, { kind: 'chain',
      entry: planGroup(chainEntryRefs(c), 'fastest'),
      main: planGroup(exits, c.exitMode === 'priority' ? 'priority' : 'fastest', exits.find(r => r.node === exitNode)) });
  }
  const refs = unitPickRefs(id), n = unitNode(id);
  return Object.assign(base, { kind: 'unit', main: planGroup(refs, unitPriority(id) ? 'priority' : 'fastest', refs.find(r => r.node === n)) });
}
const planSig = () => { try { return JSON.stringify(livePlan()); } catch (e) { return null; } };

// Connected and the plan changed (another entry, a server switched off, Global/Rules…):
// the core gets the new config.
function liveMaybeReconnect() {
  if (!live.ready || !connected || connecting || !live.planSig) return;
  const sig = planSig();
  if (!sig || sig === live.planSig) return;
  clearTimeout(live.reconnectTimer);
  live.reconnectTimer = setTimeout(() => backend.connect().catch(e => toast(e.message)), 600);
}

/* ── The real backend ── */

function liveFetch(s) {
  return api('/api/sources/fetch', {
    url: s.url, userAgent: s.userAgent, strategy: s.uaStrategy || [], discoveredAt: s.discoveredAt || 0,
    prev: { nodes: s.nodes || [], gone: s.gone || [] },
  }).then(r => {
    if (r.notModified) return;
    s.nodes = r.nodes;
    s.gone = r.gone;
    s.uaStrategy = r.strategy;
    s.discoveredAt = r.discoveredAt;
    if (r.usage) s.usage = r.usage;
    if (r.expire) s.expire = r.expire;
    let host = '';
    try { host = new URL(s.url).hostname; } catch (e) {}
    if (r.title && s.name === host) s.name = r.title;
  });
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
  manualNode(f) {
    if (!f.link) return Promise.reject(new Error('Paste the server link (vless://, ss://, hy2://…) — the core builds the server from it'));
    return api('/api/parse', { text: f.link }).then(r => {
      const n = r.nodes[0];
      if (!n) throw new Error('Link not recognised');
      // The form's name comes from the link's #fragment, flag included; keep an edited one.
      const typed = (f.name || '').replace(n.flag, '').trim();
      if (typed && f.name !== f.address) n.name = typed;
      return n;
    });
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
  connect() {
    return Promise.resolve().then(() => {
      const plan = livePlan();
      if (segState.mode === 'tun') toast('TUN is not in the core yet — proxy on 127.0.0.1:2080');
      return api('/api/connect', { plan, systemProxy: segState.sys === 'on' }).then(st => {
        live.planSig = JSON.stringify(plan);
        if (st.warning) toast(st.warning);
        liveWatchExit();   // the core checks the exit after every (re)connect
      });
    });
  },
  disconnect() {
    live.planSig = null;
    return api('/api/disconnect', {});
  },
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
      if (st.exit || !st.connected || ++tries > 20) {
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
      document.getElementById('nf-link').value = text.split(/\s/)[0];
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
  pingCache.clear();

  // Everything that re-renders after a change also saves and re-checks the connection.
  ['renderAll', 'renderConnects', 'renderNodes', 'renderAutoMode', 'renderConnSettings', 'setSegment', 'updateMainConnectCard'].forEach(name => {
    const orig = window[name];
    window[name] = function () { const r = orig.apply(this, arguments); liveSave(); liveMaybeReconnect(); return r; };
  });

  api('/api/state').then(st => {
    if (st.snapshot) liveApply(st.snapshot);
    connected = !!st.status.connected;
    exitInfo = st.status.exit || null;
    if (connected && !exitInfo) liveWatchExit();
    renderAutoMode(); renderConnSettings(); renderDns(); renderGeneral();
    ['mode', 'route', 'sys'].forEach(g => setSegment(g, segState[g]));
    renderConnects(); renderNodes(); renderRules(); updateMainConnectCard(); renderConnState();
    if (connected) live.planSig = planSig();
    live.ready = true;
    toast(st.snapshot ? 'Core connected' : 'Core connected — add a subscription in Nodes');
    if (genCfg.pingOnLaunch) pingOnLaunch();
  }, e => toast('Core not reachable: ' + e.message));

  // sing-box can stop on its own (bad server, crash): the dock must say so.
  setInterval(() => {
    if (!live.ready || !connected || connecting) return;
    api('/api/status').then(st => {
      if (st.connected) {
        // a check the core finished on its own (e.g. after liveMaybeReconnect)
        if (st.exit && JSON.stringify(st.exit) !== JSON.stringify(exitInfo)) { exitInfo = st.exit; renderExitIp(); }
        return;
      }
      connected = false;
      live.planSig = null;
      renderConnState();
      toast(st.error || 'sing-box stopped');
    }, () => {});
  }, 4000);
}

if (window.JORMD) liveInit();
