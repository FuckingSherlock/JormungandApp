/* ══════════════════════ AUTO IN THE CORE (live) ══════════════════════
   With jormd, Auto runs in the core while connected (core/lib/src/auto.dart, see
   connect-model.md → Auto): the plan carries every Auto entry as a route (and which one to
   start on), and the core moves between them — and between a Priority entry's
   servers — through sing-box's Clash API, with no restart. This file builds those routes
   and reads back what the core did: the entry and server it is really on (coreRoute →
   dock, Route), what it measured (→ the ping cache, so knownDead agrees with it) and when
   it switched or found an entry unstable (→ a toast, General → When Auto switches).
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
    if (live.switches != null && a.switches > live.switches && a.lastSwitch) notify('autoSwitch', switchText(a.lastSwitch));
    if (live.unstable != null && a.unstable > live.unstable && a.lastUnstable) notify('unstable', unstableText(a.lastUnstable));
    if (live.blocked != null && a.blocked > live.blocked && a.lastBlocked) notify('blocked', blockedText(a.lastBlocked), { label: 'Rule', fn: () => openBlockedRule(a.lastBlocked) });
    // no network at all (the OS, or no route answers): said once, and once more when it is back
    const lost = !!(a.offline || a.noNet);
    if (live.lost != null && lost !== live.lost) notify('connLost', lost ? 'Connection lost — waiting for the network' : 'Connection restored');
    live.lost = lost;
    sourcesDown(a.members);
    live.switches = a.switches;
    live.unstable = a.unstable || 0;
    live.blocked = a.blocked || 0;
    live.routes = (a.routes || []).map(r => r.id);
  } else { live.switches = live.unstable = live.blocked = live.lost = null; live.srcDown = new Set(); }
  // sing-box stopped on its own: the core puts the system proxy back and starts it again
  if (st && st.recovering && !live.recovering) notify('coreCrash', 'sing-box stopped — starting it again…');
  if (st && st.connected && live.restarts != null && st.restarts > live.restarts) notify('coreCrash', st.warning || 'sing-box started again');
  live.recovering = st ? st.recovering : null;
  live.restarts = st ? st.restarts : null;
  if (pings) refreshSourceViews();
  else if (JSON.stringify(coreRoute) !== was) { renderConnects(); updateMainConnectCard(); }
}
// The flap guard (Settings → Auto mode): an entry that keeps dropping waits before it gets the traffic back.
const unstableText = u => `Auto: ${entryLabel(u.id)} is unstable — back to it after ${Math.round(u.hold / 60000)} min without drops`;

/* A request through the current node got nothing back while the node passes traffic, and
   the site opens through another Auto entry (the core checked both): offer a rule. */
const destHost = d => d.replace(/:\d+$/, '').replace(/^\[|\]$/g, '');
const blockedText = b => `${destHost(b.dest)} does not open via ${entryLabel(b.route)} — it does via ${entryLabel(b.via)}`;
function openBlockedRule(b) {
  const host = destHost(b.dest);
  openRuleForm();
  ruleDraft = newRule({ name: host + ' via ' + entryLabel(b.via), action: 'proxy', target: b.via,
    groups: { domain: { not: false, v: { domain_suffix: [host] } } } });
  renderRuleForm();
}

/* Every tested server of one subscription fails the checks (failAfter in a row) while a
   server of another source answers: the provider's side (run out, blocked, down). Once per
   subscription until one of its servers answers again. */
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
    notify('subFailed', `${s.name}: its servers do not respond — contact the subscription provider's support`);
  });
}
