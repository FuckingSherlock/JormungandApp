/* ══════════════════════ AUTO IN THE CORE (live) ══════════════════════
   With jormd, Auto runs in the core while connected (core/lib/src/auto.dart, see
   connect-model.md → Auto): the plan carries the entry to connect plus the Auto entries
   around it as routes, and the core moves between them — and between a Priority entry's
   servers — through sing-box's Clash API, with no restart. This file builds those routes
   and reads back what the core did: the entry and server it is really on (coreRoute →
   dock, Route), what it measured (→ the ping cache, so knownDead agrees with it) and when
   it switched (→ a toast, General → When Auto switches).
   (Flutter: the same AutoService in-process; this is its view model.) */

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

/* The routes around the entry to connect (the anchor). Auto: every Auto entry above it
   (the core moves back up when one answers again), the anchor, then autoCfg.standby
   entries below (spares; tested ahead while keepWarm is on). Manual: the anchor alone.
   Entries the core cannot use (no server with an outbound) are left out; the anchor
   itself must be usable (planGroup says why not). */
function planRoutes(anchor) {
  const order = autoOrder(), i = order.indexOf(anchor);
  const ids = !autoConnect || i < 0 ? [anchor] : order.slice(0, i + 1 + Math.max(0, autoCfg.standby | 0));
  const routes = [];
  ids.forEach(id => {
    if (id === anchor) routes.push(planRoute(id));
    else try { routes.push(planRoute(id)); } catch (e) { /* nothing usable: not a route */ }
  });
  return { routes, current: routes.findIndex(r => r.id === anchor) };
}
const autoOrder = () => visibleOrder().filter(id => connectEntry(id).inAuto);
const planAuto = () => ({ failAfter: autoCfg.failAfter, threshold: autoCfg.threshold, checkEvery: autoCfg.checkEvery,
  keepWarm: autoCfg.keepWarm, standby: autoCfg.standby });

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
function switchText(s) {
  if (!s.route) return `Auto: ${entryLabel(s.from)} → ${entryLabel(s.to)}`;
  const name = k => { const n = nodeOfKey(k); return n ? n.name : k; };
  return `Auto: ${entryLabel(s.route)} — ${name(s.from)} → ${name(s.to)}`;
}

/* Every status from the core while connected (the poll, the answer to a connect; null on
   disconnect): what its Auto is on and measured. Views re-render only on a change. */
function liveAutoStatus(st) {
  const a = st && st.connected ? st.auto : null, was = JSON.stringify(coreRoute);
  coreRoute = a ? { id: a.now, server: a.server || null, entryServer: a.entryServer || null } : null;
  const pings = a ? mergeCorePings(a.members) : false;
  if (a) {
    if (live.switches != null && a.switches > live.switches && a.lastSwitch && genCfg.switchNotif) toast(switchText(a.lastSwitch));
    live.switches = a.switches;
    live.routes = (a.routes || []).map(r => r.id);
  } else live.switches = null;
  // sing-box stopped on its own: the core puts the system proxy back and starts it again
  if (st && st.recovering && !live.recovering) toast('sing-box stopped — starting it again…');
  if (st && st.connected && live.restarts != null && st.restarts > live.restarts) toast(st.warning || 'sing-box started again');
  live.recovering = st ? st.recovering : null;
  live.restarts = st ? st.restarts : null;
  if (pings) refreshSourceViews();
  else if (JSON.stringify(coreRoute) !== was) { renderConnects(); updateMainConnectCard(); }
  if (a && a.allDown) liveBeyondDown();
}
/* Every route of this plan is down (the core tried them all): a new plan around the first
   Auto entry below them that may work, if there is one. */
function liveBeyondDown() {
  if (connecting || live.beyond || !autoConnect) return;
  const order = autoOrder(), last = Math.max(-1, ...live.routes.map(id => order.indexOf(id)));
  const next = order.slice(last + 1).find(mayWork);
  if (!next) return;
  live.beyond = true;
  liveBackend.connect(next).catch(e => toast(e.message)).then(() => { live.beyond = false; });
}
