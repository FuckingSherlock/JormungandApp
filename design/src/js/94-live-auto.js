/* ══════════════════════ AUTO IN THE CORE (live) ══════════════════════
   With jormd, Auto runs in the core while connected (core/lib/src/auto.dart, see
   connect-model.md → Auto): the plan carries every Auto entry as a route (and which one to
   start on), and the core moves between them — and between a Priority entry's
   servers — through sing-box's Clash API, with no restart. This file builds those routes
   and reads back what the core did: the entry and server it is really on (coreRoute →
   dock, Route) and what it measured (→ the ping cache, so knownDead agrees with it).
   (Flutter: the same AutoService in-process; this is its view model.) */

// f() on the UI's own picks: coreRoute off meanwhile (a plan is the UI's guess; the core
// then moves inside it by itself).
function withoutCore(f) {
  const c = coreRoute;
  coreRoute = null;
  try { return f(); } finally { coreRoute = c; }
}

// One Route entry as a route of the plan (config.dart turns it into sing-box groups).
function planRoute(id) {
  if (chainsData[id]) {
    const c = chainsData[id], exits = chainExitRefs(c), exitNode = chainExitNode(c);
    return { id, kind: 'chain', entry: planGroup(chainEntryRefs(c), 'fastest'),
      main: planGroup(exits, c.exitMode === 'priority' ? 'priority' : 'fastest', exits.find(r => r.node === exitNode)) };
  }
  const refs = unitPickRefs(id), n = unitNode(id), pin = pinnedRef(id);
  const main = planGroup(refs, pin || unitPriority(id) ? 'priority' : 'fastest', pin || refs.find(r => r.node === n));
  if (pin) main.pinned = true;   // Manual on a server: held there, the core never moves it
  return { id, kind: 'unit', main };
}

/* The routes of the plan and the one to start on (the anchor). Auto: every Auto entry —
   the core moves between them through a selector, so a failover or a return never
   restarts sing-box; only a change of this list does. Manual: the anchor alone.
   Entries the core cannot use (no server with an outbound) are left out; the anchor
   itself must be usable (planGroup says why not). */
function planRoutes(anchor) {
  const order = autoOrder(), i = order.indexOf(anchor);
  const ids = !autoConnect || i < 0 ? [anchor] : order;
  const routes = [];
  ids.forEach(id => {
    if (id === anchor) routes.push(planRoute(id));
    else try { routes.push(planRoute(id)); } catch (e) { /* nothing usable: not a route */ }
  });
  return { routes, current: routes.findIndex(r => r.id === anchor) };
}
const autoOrder = () => visibleOrder().filter(id => connectEntry(id).inAuto);
// Settings → Auto mode as the core reads it (auto.dart → AutoSettings.fromPlan).
const planAuto = () => ({ failAfter: autoCfg.failAfter, threshold: autoCfg.threshold, checkEvery: autoCfg.checkEvery,
  standby: autoCfg.standby, warmEvery: autoCfg.warmEvery, retryPause: autoCfg.retryPause, returnTo: autoCfg.returnTo,
  flapGuard: autoCfg.flapGuard, flapMax: autoCfg.flapMax, flapReset: autoCfg.flapReset,
  checkers: connCfg.checkers });   // Settings → Connection → Backup checks, taken live too

/* Which anchor the running plan is compared with (liveMaybeReconnect): in Auto the one it
   was built on while that is still an Auto entry — the core moves inside the plan by
   itself, so neither its moves nor a ping may restart sing-box; otherwise (Manual, the
   entry left Auto) the UI's pick, and a different pick is a new plan. */
const liveSigAnchor = () => autoConnect && live.anchor && autoOrder().includes(live.anchor) ? live.anchor : effectiveConnectId(true);
// A page opened while connected: the anchor whose routes are the ones the core runs.
function liveFindAnchor(ids) {
  const same = id => { try { return planRoutes(id).routes.map(r => r.id).join() === ids.join(); } catch (e) { return false; } };
  return ids.find(same) || (coreRoute && coreRoute.id) || null;
}

// A 'sid::nid' key of the plan → its server.
function nodeOfKey(key) {
  const i = key.indexOf('::'), s = i > 0 && sourcesData[key.slice(0, i)];
  return s ? (s.nodes || []).find(n => n.id === key.slice(i + 2)) || null : null;
}
// The core's own checks land in the ping cache: newer ones only, a ping in flight wins.
function mergeCorePings(members) {
  let changed = false;
  (members || []).forEach(m => {
    const n = nodeOfKey(m.key), e = n && pingEntry(n);
    if (!n || typeof m.ms !== 'number' || m.ms < -1 || (e && (e.ms === 'testing' || e.at >= m.at))) return;
    pingCache.set(pingKey(n), { ms: m.ms, at: m.at, fails: m.fails || 0 });
    changed = true;
  });
  return changed;
}

const entryLabel = id => { const e = connectEntry(id); return e ? e.name : chainsData[id] ? chainsData[id].name : unitName(id); };

/* Every status from the core while connected (the poll, the answer to a connect; null on
   disconnect): what its Auto is on and measured. Views re-render only on a change. What
   the core did (switched, unstable, blocked, lost, crashed…) is not read from here: it comes
   as events (47-events.js), which also drive the background notifications; only a
   subscription's servers all failing (sourcesDown) is the UI's to post. */
function liveAutoStatus(st) {
  liveVpnState(st);
  const a = st && st.connected ? st.auto : null, was = JSON.stringify(coreRoute);
  coreRoute = a ? { id: a.now, server: a.server || null, entryServer: a.entryServer || null } : null;
  const pings = a ? mergeCorePings(a.members) : false;
  if (a) { sourcesDown(a.members); live.routes = (a.routes || []).map(r => r.id); } else live.srcDown = new Set();
  if (pings) refreshSourceViews();
  else if (JSON.stringify(coreRoute) !== was) { renderConnects(); updateMainConnectCard(); }
  // status.dns: the server in use and the ones that do not answer (Settings → DNS marks them)
  const dns = st && st.connected ? st.dns || null : null;
  if (JSON.stringify(dns) !== JSON.stringify(liveDns)) { liveDns = dns; renderDns(); }
}

/* status.recovering / down / blocking → the dock and Home (50-home.js vpn). A background restart
   (recovering) is deliberately invisible: no toast, the dock stays Connected; its events stay in
   the journal (core/crashed → the coreCrash toggle, default off). conn: whether the UI takes the
   status as connected (default: st.connected). */
function liveVpnState(st, conn) {
  const on = conn === undefined ? !!(st && st.connected) : conn;
  const next = { recovering: on && st && st.recovering || null, down: on && st && st.down || null, blocking: !on && st && st.blocking || null };
  if (JSON.stringify(next) === JSON.stringify(vpn)) return;
  Object.assign(vpn, next);
  renderConnState();
}

/* A request through the current node got nothing back while the node passes traffic, and
   the site opens through another Auto entry (the core checked both): offer a rule. */
const destHost = d => d.replace(/:\d+$/, '').replace(/^\[|\]$/g, '');
function openBlockedRule(b) {
  const host = destHost(b.dest);
  openRuleForm();
  ruleDraft = newRule({ name: host + ' via ' + entryLabel(b.via), action: 'proxy', target: b.via,
    groups: { domain: { not: false, v: { domain_suffix: [host] } } } });
  renderRuleForm();
}

/* Every tested server of one subscription fails the checks (failAfter in a row) while a
   server of another source answers: the provider's side (run out, blocked, down). The UI
   knows this (it maps the core's members to sources), so it posts the sub/dead event, once
   per subscription until one of its servers answers again. */
function sourcesDown(members) {
  const by = {}, fa = autoCfg.failAfter || 2;
  (members || []).forEach(m => { const i = m.key.indexOf('::'); if (i > 0) (by[m.key.slice(0, i)] ||= []).push(m); });
  live.srcDown ||= new Set();
  Object.entries(by).forEach(([sid, ms]) => {
    const s = sourcesData[sid];
    const down = s && s.kind === 'sub' && ms.length >= 2 && ms.every(m => m.ms < 0 && m.fails >= fa);
    const others = Object.entries(by).some(([o, x]) => o !== sid && x.some(m => m.ms >= 0));
    if (!down) { live.srcDown.delete(sid); return; }
    if (!others || live.srcDown.has(sid)) return;
    live.srcDown.add(sid);
    journal('sub', 'dead', { source: sid, name: s.name }, { level: 'error', own: false });
  });
}
