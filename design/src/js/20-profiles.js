/* ══════════════════════ PROFILES SHEET (entries + chains in one priority list) ══════════════════════
   Entries are sources in simple mode, profiles in profiles mode (see connectMode).
   connectOrder is the Auto priority: with Auto on, the first usable entry that has
   inAuto wins. Tapping an entry pins it (Auto off). Everything else about an entry —
   sources and picked nodes, chain ends, "use in Auto" — lives in its editor (⋯). */

const connectEntry = id => profilesData[id] || chainsData[id] || sourcesData[id];
const simpleMode = () => connectMode === 'simple';
const unitWord = () => simpleMode() ? 'source' : 'profile';

/* Servers switched off one by one in Nodes: s.disabledNodes (node ids). Like a source
   switched off, a disabled server is hidden from every list and picker (entries, profiles,
   chains) but every setting naming it is kept — switched back on, it is where it was.
   liveNodes(s) = the servers the rest of the app sees. */
const isNodeDisabled = (s, nid) => !!s.disabledNodes && s.disabledNodes.includes(nid);
const liveNodes = s => s.nodes.filter(n => !isNodeDisabled(s, n.id));

/* Delete preview: while simExclude(ref) is set, units act as if those servers were gone
   (see deleteImpact in 30-nodes.js). */
let simExclude = null;
const simKeep = r => !simExclude || !simExclude(r);

// Nodes a profile can use right now (enabled sources, live servers only), as {sid, node}.
// p.sources = whole sources (every node, including ones a subscription update adds later);
// p.nodes = individually picked nodes as 'sid::nid' (kept while the provider has dropped
// the server too — see s.gone — so the pick is back when the server is).
// withOff: also what is switched off in Nodes (to tell why a profile has nothing).
function profileNodeRefs(p, withOff) {
  const refs = [];
  sourceOrder.forEach(sid => {
    const s = sourcesData[sid];
    if (!s || !(s.enabled || withOff)) return;
    const whole = p.sources.includes(sid);
    (withOff ? s.nodes : liveNodes(s)).forEach(n => { if (whole || p.nodes.includes(sid + '::' + n.id)) refs.push({ sid, node: n }); });
  });
  return refs.filter(simKeep);
}

const isNodeOff = (s, nid) => !!s.offNodes && s.offNodes.includes(nid);
const offCount = s => liveNodes(s).filter(n => isNodeOff(s, n.id)).length;

// A "unit" is what a list entry / chain end stands for: a profile, or (simple mode) a source.
function unitRefs(id, withOff) {
  if (profilesData[id]) return profileNodeRefs(profilesData[id], withOff);
  const s = sourcesData[id];
  if (!s || !(s.enabled || withOff)) return [];
  return (withOff ? s.nodes : liveNodes(s)).filter(n => !isNodeOff(s, n.id)).map(node => ({ sid: id, node })).filter(simKeep);
}
// Servers of a unit the provider dropped (s.gone), shown under "Unavailable" with their
// kept settings. Disabled sources show nothing, like their live nodes.
function unitGoneRefs(id) {
  const p = profilesData[id];
  const sids = p ? sourceOrder : [id];
  const refs = [];
  sids.forEach(sid => {
    const s = sourcesData[sid];
    if (!s || !s.enabled) return;
    (s.gone || []).forEach(node => { if (!p || p.sources.includes(sid) || p.nodes.includes(sid + '::' + node.id)) refs.push({ sid, node }); });
  });
  return refs;
}

/* Switching a source or a single server off in Nodes never edits what uses it: switched
   back on, it is back in its profiles and chains with the same ticks and priority.
   - simple mode: a switched-off source's own entry is hidden;
   - an entry / chain that has nothing left without it is "broken": greyed with a red
     edge, shown below the list (its priority slot is kept), skipped by Auto; tapping it
     says what is off. brokenBy(id) = what to switch back on — {sid} for a source,
     {sid, nid} for a server — or [] when the entry works. */
function offReasons(allRefs) {
  const m = new Map();
  allRefs.forEach(r => {
    const s = sourcesData[r.sid];
    if (!s.enabled) m.set(r.sid, { sid: r.sid });
    else if (isNodeDisabled(s, r.node.id)) m.set(refKey(r), { sid: r.sid, nid: r.node.id });
  });
  return [...m.values()];
}
// Sides that have no live server, but would with everything in Nodes switched on.
const sideReasons = (live, all) => live.length ? [] : offReasons(all);
function brokenBy(id) {
  if (chainsData[id]) {
    const c = chainsData[id], seen = new Set();
    return sideReasons(chainEntryRefs(c), chainEntryRefs(c, true)).concat(sideReasons(chainExitRefs(c), chainExitRefs(c, true)))
      .filter(r => { const k = r.sid + '::' + (r.nid || ''); return !seen.has(k) && seen.add(k); });
  }
  return connectEntry(id) ? sideReasons(unitRefs(id), unitRefs(id, true)) : [];
}
const reasonNode = r => sourcesData[r.sid].nodes.find(n => n.id === r.nid);
const reasonLabel = r => r.nid ? reasonNode(r).flag + ' ' + reasonNode(r).name : sourcesData[r.sid].name;
// "Remnawave is off" / "🇩🇪 Frankfurt 01, 🇳🇱 Amsterdam 01 are off" (up to 3 named).
function reasonsText(rs) {
  const names = rs.slice(0, 3).map(reasonLabel).join(', ') + (rs.length > 3 ? ` +${rs.length - 3}` : '');
  return names + (rs.length > 1 ? ' are' : ' is') + ' off in Nodes';
}
const isBroken = id => brokenBy(id).length > 0;
const entryVisible = id => !(sourcesData[id] && !sourcesData[id].enabled);
// The list as shown: working entries in priority order (draggable), broken ones below.
const visibleOrder = () => connectOrder.filter(id => entryVisible(id) && !isBroken(id));
const brokenOrder = () => connectOrder.filter(id => entryVisible(id) && isBroken(id));

const unitName = id => { const u = profilesData[id] || sourcesData[id]; return u ? u.name : '—'; };

/* Which server a unit connects through: pickMode 'fastest' (default — the best alive one)
   or 'priority' (the first alive one in pickOrder, 'sid::nid' keys; servers missing from
   it follow in source order). A setting of the list entry — a profile, or in simple mode
   the source's entry — not of the subscription; Nodes has no order. */
const unitOwner = id => profilesData[id] || sourcesData[id];
const unitPriority = id => { const u = unitOwner(id); return !!u && u.pickMode === 'priority'; };
function unitPickRefs(id, withOff) {
  const refs = unitRefs(id, withOff);
  return unitPriority(id) ? orderRefs(refs, unitOwner(id).pickOrder) : refs;
}
// The pinned server of the pinned entry, while it is still one of the entry's servers.
function pinnedRef(id) {
  if (autoConnect || id !== activeConnectId || !pinnedNode) return null;
  return unitRefs(id).find(r => refKey(r) === pinnedNode) || null;
}
/* Live and connected, the core's Auto says where traffic really goes (95-live.js, from
   /api/status → auto): {id: the Route entry it is on, server: the unit's or the chain
   exit's server, entryServer: the chain entry's server} ('sid::nid' keys). The dock and
   Route show that instead of their own guess. Always null in the mockup. */
let coreRoute = null;
function coreNode(id, which, refs) {
  if (!coreRoute || coreRoute.id !== id || !coreRoute[which]) return null;
  const r = refs.find(r => refKey(r) === coreRoute[which]);
  return r ? r.node : null;
}
function unitNode(id) {
  const pin = pinnedRef(id);
  if (pin) return pin.node;   // Manual on a server: that one, answering or not
  const core = coreNode(id, 'server', unitPickRefs(id));
  if (core) return core;
  const nodes = unitPickRefs(id).map(r => r.node);
  return unitPriority(id) ? nodes.find(isAlive) || null : bestAlive(nodes);
}
const profileNode = p => p ? unitNode(p.id) : null;

/* Chains keep their own node choice on each end: inOff / outOff = 'sid::nid' keys switched
   off for this chain. The exit is picked by exitMode: 'fastest' (best alive) or 'priority'
   (first alive in exitOrder; servers missing from exitOrder follow in source order). */
const refKey = r => r.sid + '::' + r.node.id;
function bestAlive(nodes) {
  let best = null;
  nodes.forEach(n => { if (isAlive(n) && (!best || ping(n) < ping(best))) best = n; });
  return best;
}
function chainEntryRefs(c, withOff) { return unitRefs(c.inId, withOff).filter(r => !(c.inOff || []).includes(refKey(r))); }
// Refs sorted by a list of 'sid::nid' keys; ones missing from it follow in their own order.
function orderRefs(refs, order) {
  order = order || [];
  const pos = k => { const i = order.indexOf(k); return i < 0 ? Infinity : i; };
  return refs.map((r, i) => ({ r, i }))
    .sort((a, b) => (pos(refKey(a.r)) - pos(refKey(b.r))) || a.i - b.i).map(x => x.r);
}
// Every exit server in priority order, unticked ones included.
function chainExitOrder(c, withOff) { return orderRefs(unitRefs(c.outId, withOff), c.exitOrder); }
function chainExitRefs(c, withOff) { return chainExitOrder(c, withOff).filter(r => !(c.outOff || []).includes(refKey(r))); }
const chainEntryNode = c => coreNode(c.id, 'entryServer', chainEntryRefs(c)) || bestAlive(chainEntryRefs(c).map(r => r.node));
function chainExitNode(c) {
  const core = coreNode(c.id, 'server', chainExitRefs(c));
  if (core) return core;
  const exits = chainExitRefs(c).map(r => r.node);
  return c.exitMode === 'priority' ? exits.find(isAlive) || null : bestAlive(exits);
}

function isUsable(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    return !!chainEntryNode(c) && !!chainExitNode(c);
  }
  const n = unitNode(id);
  return !!n && isAlive(n);
}

/* Auto passes over an entry only when it is known not to work: every server it would use
   silent failAfter times in a row, the last time within PING_FRESH_MS (a result being
   re-measured keeps counting until the new one is in). Servers not measured yet (a fresh
   start before the launch ping, a new subscription) or measured long ago still count, so
   a restart never hands the top spot to the next entry over one lost ping. */
const knownDead = n => {
  const e = pingEntry(n);
  return !!e && e.ms !== null && !(e.ms >= 0) && (e.fails || 0) >= autoCfg.failAfter && Date.now() - e.at < PING_FRESH_MS;
};
function mayWork(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    return chainEntryRefs(c).some(r => !knownDead(r.node)) && chainExitRefs(c).some(r => !knownDead(r.node));
  }
  return unitPickRefs(id).some(r => !knownDead(r.node));
}

// What is actually connected: the pinned entry, or Auto's pick — live and connected, the
// entry the core's Auto is really on; ownGuess = the UI's pick regardless (a new plan).
function effectiveConnectId(ownGuess) {
  if (!autoConnect && entryVisible(activeConnectId) && !isBroken(activeConnectId)) return activeConnectId;
  const order = visibleOrder();
  if (!ownGuess && coreRoute && order.includes(coreRoute.id) && connectEntry(coreRoute.id).inAuto) return coreRoute.id;
  return order.find(id => connectEntry(id).inAuto && mayWork(id))
      || order.find(id => connectEntry(id).inAuto) || null;   // every entry off Auto: Auto picks nothing
}
// Auto with every Route entry switched off Auto: nothing to connect through.
const nothingInAuto = () => autoConnect && visibleOrder().length > 0 && !visibleOrder().some(id => connectEntry(id).inAuto);
// The alert on power / connect: says why and leads to the switches (Route in edit mode).
function alertNothingInAuto() {
  const close = "closeSheet('actions');";
  openActions('Nothing in Auto', `<div class="menu-note">Every entry in Route is switched off Auto, so Auto has nothing to connect through. Turn <b>Use in Auto</b> on for at least one entry, or pick one yourself with MANUAL.</div>`
    + menuRow(ICON.bolt, 'Open Route', close + 'openProfiles();setRouteEdit(true)')
    + menuRow(ICON.close, 'Cancel', close));
}

function nodeSummaryHtml(n, fixed) {
  if (!n) return `<span>${fixed ? 'Fixed node not set' : 'No working nodes'}</span>`;
  return `<span class="conn-node"><span class="conn-flag">${n.flag}</span>${esc(n.name)}</span>${latHtml(n)}`;
}

function entrySummaryHtml(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    const end = (uid, n) => (n ? `<span class="conn-flag">${n.flag}</span> ` : '') + esc(unitName(uid));
    return `<span>${end(c.inId, chainEntryNode(c))}</span><span class="conn-arrow">→</span>`
      + (c.exitMode === 'priority' ? '<span class="conn-tag muted">priority</span>' : '') + `<span>${end(c.outId, chainExitNode(c))}</span>`;
  }
  return (unitPriority(id) ? '<span class="conn-tag muted">priority</span>' : '') + nodeSummaryHtml(unitNode(id), false);
}

const GRIP_SVG = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>';

function renderConnectRow(id) {
  const e = connectEntry(id);
  const chain = !!chainsData[id];
  const current = id === effectiveConnectId();
  const tags = (chain ? '<span class="conn-tag">chain</span>' : sourcesData[id] && offCount(sourcesData[id]) ? `<span class="conn-tag muted">${offCount(sourcesData[id])} off</span>` : '')
    + (autoConnect && !e.inAuto && !routeEdit ? '<span class="conn-tag muted">not in Auto</span>' : '');   // in edit its toggle says it
  return `<div class="conn-row ${current ? 'current' : ''} ${routeOpen.has(id) ? 'open' : ''} ${autoConnect && !e.inAuto ? 'skip' : ''}" data-id="${id}">
    ${routeEdit ? `<div class="drag-handle" onpointerdown="startConnectDrag(event,'${id}')" title="Drag to set Auto priority">${GRIP_SVG}</div>` : ''}
    <div class="conn-main" ${chain ? '' : `onclick="toggleRouteRow('${id}')"`}>
      <div class="conn-name"><button class="conn-state ${current ? 'on' : ''}" onclick="event.stopPropagation();selectConnect('${id}')" title="${current && !autoConnect ? 'Back to Auto' : 'Use only this one (Manual)'}">${current && autoConnect ? 'auto' : 'manual'}</button>${routeEdit ? `<span class="route-auto" title="Use in Auto: Auto may pick it">${miniToggleHtml(id, 'toggleEntryAuto', e.inAuto)}</span>` : ''}<span class="conn-title">${esc(e.name)}</span>${tags}</div>
      <div class="conn-sub">${entrySummaryHtml(id)}</div>
    </div>
    <div class="route-ping">${pingAllBtn(`testEntryLatency('${id}')`, 'Ping its servers')}</div>
    ${!chain && routeOpen.has(id) ? routeRowBodyHtml(id) : ''}
  </div>`;
}

/* A source or profile row unfolds to its servers: Fastest / Priority and, in Priority, the
   order by drag — the same pickMode / pickOrder as the entry editors (Nodes → Route
   settings, the profile form), just at hand. Leaving servers out stays in those editors.
   The switch and the ⋮⋮ grips show only in edit mode; otherwise the row says how it picks. */
// Unfolded rows: each on its own, unfolding one never folds another.
const routeOpen = new Set();
let routeRowFocus = null;   // the row whose switch / grips were touched last
function toggleRouteRow(id) {
  if (routeOpen.has(id)) routeOpen.delete(id); else { routeOpen.add(id); routeRowFocus = id; }
  renderConnects();
}
function routeRowBodyHtml(id) {
  const priority = unitPriority(id);
  const refs = priority ? unitPickRefs(id) : byPing(unitRefs(id), r => r.node);
  let rank = 0;
  const pin = pinnedRef(id);
  const rows = refs.map(r => `<div class="node-row ps-node on ${pin && refKey(pin) === refKey(r) ? 'pinned' : ''}" data-id="${refKey(r)}" onclick="pinRouteNode('${id}','${refKey(r)}',event)" title="Use only this server (Manual)">
      ${priority && routeEdit ? `<div class="drag-handle cc-grip" onpointerdown="startRouteNodeDrag(event,'${refKey(r)}')">${GRIP_SVG}</div>` : ''}${priority ? `<span class="cc-rank">${++rank}</span>` : ''}
      
      <span class="node-name"><span class="node-flag">${r.node.flag}</span>${esc(r.node.name)}</span>
      <span class="node-proto">${protoLabel(r.node)}</span>
      <span class="lat-hit" onclick="event.stopPropagation();testLatency([['${r.sid}','${r.node.id}']])" title="Tap to ping">${latHtml(r.node)}</span>
    </div>`).join('');
  const acts = `<div class="conn-acts">${routeUpdateBtn(id)}</div>`;   // ⚡ sits on the row itself
  const hint = pin ? 'Manual: only the highlighted server.'
    : priority ? 'The first working one from the top.' + (routeEdit ? ' Drag ⋮⋮ to order.' : '') : 'Connects through the fastest of them.';
  return `<div class="conn-body" onpointerdown="routeRowFocus='${id}'">${routeEdit
      ? `<div class="seg-row">${pickModeSwitch('rt:' + id, priority, 'setRouteRowMode')}${acts}</div><div class="set-hint conn-hint">${hint}</div>`
      : `<div class="seg-row"><div class="set-hint conn-hint conn-pick-hint">${hint}</div>${acts}</div>`}
    <div class="se-nodes">${rows || '<div class="route-empty">No servers</div>'}</div></div>`;
}
// Update: the row's subscription, or every subscription a profile takes servers from.
const routeSubs = id => [...new Set(unitRefs(id, true).map(r => r.sid))].filter(sid => sourcesData[sid] && sourcesData[sid].kind === 'sub');
const routeUpdateBtn = id => { const subs = routeSubs(id); return subs.length ? `<button class="icon-btn ghost" onclick="updateRouteRow('${id}')" title="Update"><span class="${subs.some(sid => sourcesData[sid].updating) ? 'spin' : ''}" style="display:inline-flex">${ICON.refresh}</span></button>` : ''; };
const updateRouteRow = id => routeSubs(id).forEach(updateSource);
/* Tap a server of an unfolded row: Manual on this entry and on this server. Tap the pinned
   server again: the entry stays Manual and picks by its Fastest / Priority again. Any other
   pick (another entry, AUTO / MANUAL, the Auto badge) drops the server pin. */
function pinRouteNode(id, key, e) {
  if (dragCtx || (e && e.target.closest('.drag-handle'))) return;   // the end of a drag, not a tap
  const again = !autoConnect && activeConnectId === id && pinnedNode === key;
  autoConnect = false; activeConnectId = id; pinnedNode = again ? null : key;
  journal('user', 'pin', { action: 'pin', entry: id, server: again ? null : key });
  routeRowChanged();
}
function routeRowChanged() {
  renderConnects();
  updateMainConnectCard();
}
function setRouteRowMode(mode) {
  unitOwner(routeRowFocus).pickMode = mode;
  routeRowChanged();
}
function startRouteNodeDrag(e, key) {
  routeRowFocus = e.currentTarget.closest('.conn-row').dataset.id;
  const u = unitOwner(routeRowFocus), shown = unitPickRefs(routeRowFocus).map(refKey), cur = u.pickOrder || [];
  const [order, done] = dragShown(cur.concat(shown.filter(k => !cur.includes(k))), shown, o => { u.pickOrder = o; });
  const rowEl = document.querySelector(`#connects-list .conn-row[data-id="${routeRowFocus}"] .conn-body .node-row[data-id="${key}"]`);
  startRowDrag(e, rowEl, '.node-row', order, () => { done(); routeRowChanged(); });
}

/* Edit mode (✎ left of Simple / Profiles, ✓ while on; off whenever the sheet opens): the ⋮⋮
   grips of the priority and, in an unfolded row, the Fastest / Priority switch and the
   server grips. Without it the list is for looking and picking only. */
let routeEdit = false;
function setRouteEdit(on) {
  routeEdit = on;
  const b = document.getElementById('routeEditBtn');
  b.classList.toggle('on', on);
  b.title = on ? 'Done' : 'Edit: priority order, Fastest / Priority';
  b.innerHTML = on ? ICON.check : ICON.edit;
  renderConnects();
}

/* A row: ⋮⋮ grip (Auto priority, in edit mode), tap the card = unfold its servers, the
   AUTO / MANUAL button = the only way to pick: on another row it pins that one (Manual),
   on the pinned row it goes back to Auto. The switch = Use in Auto. Everything else: Nodes. */

function renderConnects() {
  syncCatalog();
  document.getElementById('connectsCaption').innerHTML = routeEdit ? '⋮⋮ = order · switch = in Auto' : `<span class="cap-ico">${ICON.bolt}</span> = ping its servers`;
  const badge = document.getElementById('autoBadge');
  badge.classList.toggle('off', !autoConnect);
  badge.querySelector('span').textContent = autoConnect ? 'Auto' : 'Manual';
  document.getElementById('routeModes').dataset.mode = connectMode;
  document.querySelectorAll('#routeModes button').forEach(b => b.classList.toggle('on', b.dataset.mode === connectMode));
  document.getElementById('routeOrderNote').innerHTML = routeCustom[connectMode]
    ? `Own priority order<button class="am-link" onclick="resetRouteOrder()">Follow Nodes order</button>`
    : 'Priority follows the order in Nodes · ' + (routeEdit ? 'drag here to override it' : '✎ to set its own');
  const broken = brokenOrder();
  document.getElementById('connects-list').innerHTML = (visibleOrder().map(renderConnectRow).join('')
    || `<div class="route-empty">${simpleMode() ? 'No enabled subscriptions or servers — add or switch one on in Nodes' : 'No working profiles — create one in Nodes → Profiles'}</div>`)
    + (broken.length ? `<div class="conn-broken-list">${broken.map(renderBrokenRow).join('')}</div>` : '');
}

// Outside #connects-list's direct children, so the drag never counts these rows.
function renderBrokenRow(id) {
  const e = connectEntry(id);
  return `<div class="conn-row broken" data-id="${id}" onclick="explainBroken('${id}')">
    ${routeEdit ? '<div class="drag-handle"></div>' : ''}
    <div class="conn-main">
      <div class="conn-name"><span class="conn-title">${esc(e.name)}</span>${chainsData[id] ? '<span class="conn-tag">chain</span>' : ''}<span class="conn-tag off">off</span></div>
      <div class="conn-sub"><span>${esc(reasonsText(brokenBy(id)))}</span></div>
    </div>
  </div>`;
}

function explainBroken(id) {
  const rs = brokenBy(id), kind = chainsData[id] ? 'chain' : profilesData[id] ? 'profile' : 'entry';
  const close = "closeSheet('actions');";
  const what = rs.some(r => !r.nid) ? (rs.some(r => r.nid) ? 'sources and servers' : rs.length > 1 ? 'sources' : 'source')
    : rs.length > 1 ? 'servers' : 'server';
  const edit = chainsData[id] ? `openEditChain('${id}')` : profilesData[id] ? `openEditProfile('${id}')` : `openSourceEntry('${id}')`;
  openActions(connectEntry(id).name,
    `<div class="menu-note">This ${kind} has nothing to connect through: the ${what} it uses ${rs.length > 1 ? 'are' : 'is'} switched off in Nodes. Switch ${rs.length > 1 ? 'one' : 'it'} on, or select another server in the ${kind}. Its settings are kept either way.</div>`
    + rs.map(r => menuRow(ICON.power, 'Switch on ' + esc(reasonLabel(r)) + (r.nid ? `<div class="menu-sub">${esc(sourcesData[r.sid].name)}</div>` : ''),
        close + (r.nid ? `enableNode('${r.sid}','${r.nid}')` : `enableSource('${r.sid}')`))).join('')
    + menuRow(ICON.edit, 'Edit ' + kind, close + edit));
}
function enableSource(sid) {
  sourcesData[sid].enabled = true;
  renderAll();
}
function enableNode(sid, nid) {
  const s = sourcesData[sid];
  s.disabledNodes = (s.disabledNodes || []).filter(x => x !== nid);
  renderAll();
}

// The dock opens Route and, since it stays on top of it, closes it too.
const toggleRoute = () => document.getElementById('sh-profiles').classList.contains('open') ? closeSheet('profiles') : openProfiles();
function openProfiles() {
  setRouteEdit(false);
  openSheet('profiles');
}

/* On Home, Route sits above the bottom block: it ends at the dock's top edge, its bottom
   tucks under the power tab, and the dock and the nav stay on top and usable. The raised
   layers drop back once the sheet has slid away. With no dock on screen: the whole screen. */
function placeRouteSheet() {
  const sh = document.getElementById('sh-profiles'), dock = document.querySelector('#view-home.active .dock');
  document.querySelector('.phone').classList.toggle('route-docked', !!dock);
  sh.style.bottom = dock ? (document.documentElement.clientHeight - dock.getBoundingClientRect().top) + 'px' : '';
}
document.getElementById('sh-profiles').addEventListener('transitionend', e => {
  if (e.target.id === 'sh-profiles' && !e.target.classList.contains('open')) {
    document.querySelector('.phone').classList.remove('route-docked');
    e.target.style.bottom = '';
  }
});
window.addEventListener('resize', () => { if (document.getElementById('sh-profiles').classList.contains('open')) placeRouteSheet(); });

/* Keeps the catalog, sourceOrder and both route lists in step after anything was added
   or deleted: entries that no longer exist drop out; a route that follows Nodes copies
   the catalog, a route with its own order keeps it and appends new entries. */
function syncCatalog() {
  const exists = id => sourcesData[id] || profilesData[id] || chainsData[id];
  catalogOrder.simple = catalogOrder.simple.filter(exists);
  sourceOrder.forEach(id => { if (!catalogOrder.simple.includes(id)) catalogOrder.simple.push(id); });
  catalogOrder.profiles = catalogOrder.profiles.filter(exists);
  sourceOrder = catalogOrder.simple.filter(id => sourcesData[id]);
  ['simple', 'profiles'].forEach(m => {
    const cat = catalogOrder[m], cur = modeOrder(m);
    const next = routeCustom[m] ? cur.filter(id => cat.includes(id)).concat(cat.filter(id => !cur.includes(id))) : cat.slice();
    setModeOrder(m, next);
    if (m === connectMode) { if (!next.includes(activeConnectId)) activeConnectId = next[0]; }
    else if (!next.includes(modeState[m].active)) modeState[m].active = next[0];
  });
}

function resetRouteOrder() {
  routeCustom[connectMode] = false;
  closeSheet('actions');
  renderConnects();
  updateMainConnectCard();
}
function toggleEntryAuto(id) {
  const e = connectEntry(id);
  e.inAuto = !e.inAuto;
  renderConnects();
  updateMainConnectCard();
  // the tunnel is not dropped under the user: it stays on its server until they disconnect
  if (connected && nothingInAuto()) toast('Nothing left in Auto — the connection stays until you disconnect');
}

function setAutoConnect(on) {
  autoConnect = on; pinnedNode = null;
  if (!on) activeConnectId = effectiveConnectIdWhenAuto();
  renderConnects();
  updateMainConnectCard();
}
function effectiveConnectIdWhenAuto() {
  const was = autoConnect; autoConnect = true;
  const id = effectiveConnectId(); autoConnect = was; return id;
}

function selectConnect(id) {
  pinnedNode = null;
  if (!autoConnect && activeConnectId === id) autoConnect = true;   // second tap on the pinned entry → back to Auto
  else { autoConnect = false; activeConnectId = id; }
  renderConnects();
  updateMainConnectCard();
}

const CHAIN_ICON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/></svg>';

// "+" on the Profiles tab of Nodes (the Simple tab has its Add sheet with a Chain row).
function openCreateMenu() {
  const close = "closeSheet('actions');";
  openActions('Create',
    menuRow(ICON.plus.replace(/16/g, '18'), 'Profile<div class="menu-sub">Chosen subscriptions or single servers — uses the fastest</div>', close + 'openCreateProfile()') +
    menuRow(CHAIN_ICON,
      'Chain<div class="menu-sub">' + (getProfileIds().length < 2 ? 'Needs at least two profiles' : 'Enter through one profile, exit through another') + '</div>',
      close + "openCreateChain(null,'profiles')", getProfileIds().length < 2 ? 'disabled' : ''));
}

/* ── Mode: simple (sources) / profiles — the switch under the Route header ── */

function setConnectMode(mode) {
  closeSheet('actions');
  if (mode === connectMode) return;
  modeState[connectMode] = { order: connectOrder, active: activeConnectId, auto: autoConnect, pin: pinnedNode };
  ({ order: connectOrder, active: activeConnectId, auto: autoConnect } = modeState[mode]);
  pinnedNode = modeState[mode].pin || null;
  connectMode = mode;
  renderConnects();
  // The list slides in from the side the switch moved to.
  const list = document.getElementById('connects-list');
  list.style.setProperty('--swap-from', mode === 'profiles' ? '16px' : '-16px');
  list.classList.remove('swap'); void list.offsetWidth; list.classList.add('swap');
  updateMainConnectCard();
  if (typeof renderNodesTabs === 'function') renderNodesTabs();
}

// Priority list of either mode (the active one lives in the globals).
function modeOrder(mode) { return mode === connectMode ? connectOrder : modeState[mode].order; }
function setModeOrder(mode, order) { if (mode === connectMode) connectOrder = order; else modeState[mode].order = order; }

// A new source joins the end of the Simple tab (and so of the simple-mode route).
function sourceAdded(id) {
  if (sourcesData[id].inAuto === undefined) sourcesData[id].inAuto = true;
  if (!sourcesData[id].offNodes) sourcesData[id].offNodes = [];
  if (!catalogOrder.simple.includes(id)) catalogOrder.simple.push(id);
  syncCatalog();
  if (document.getElementById('sh-profiles').classList.contains('open')) renderConnects();
}

// Remove a unit and every chain that uses it from both modes' lists.
function dropConnectEntry(id) {
  const gone = new Set([id]);
  Object.values(chainsData).forEach(c => { if (c.inId === id || c.outId === id) { gone.add(c.id); delete chainsData[c.id]; } });
  ['simple', 'profiles'].forEach(mode => {
    catalogOrder[mode] = catalogOrder[mode].filter(x => !gone.has(x));
    const order = modeOrder(mode).filter(x => !gone.has(x));
    setModeOrder(mode, order);
    const st = mode === connectMode ? null : modeState[mode];
    if (st ? gone.has(st.active) : gone.has(activeConnectId)) {
      if (st) st.active = order[0]; else activeConnectId = order[0];
    }
  });
  renderConnects();
  updateMainConnectCard();
}


function toggleRuleEnabled(id) {
  rulesData[id].enabled = !rulesData[id].enabled;
  renderRules();
}

/* ── Home dock ── */

/* What is connected right now, the whole route:
   simple mode   — subscription / server set + node;
   profiles mode — profile + the node's subscription + node;
   chain         — chain + entry node → exit node (their sources in the sheet).
   The right column is the latency (a chain: the two hops added up). */
function updateMainConnectCard() {
  syncCatalog();
  const id = effectiveConnectId();
  const e = connectEntry(id);
  const badge = document.getElementById('profModeBadge');
  const detail = document.getElementById('profModeDetail');
  const nodeHtml = n => n ? `<span class="dock-node">${n.flag} ${esc(n.name)}</span>` : '<span class="dock-node none">no working node</span>';
  const ms = n => n && isAlive(n) ? ping(n) : null;
  const none = !e && nothingInAuto(), empty = !e && catalogEmpty();   // empty: 50-home.js dockTap
  document.getElementById('profCardName').textContent = e ? e.name : none ? 'Nothing in Auto'
    : empty ? (simpleMode() ? 'No servers yet' : 'No profiles yet') : '—';
  document.getElementById('profCardLabel').textContent = chainsData[id] ? 'Chain' : profilesData[id] ? 'Profile'
    : sourcesData[id] ? (sourcesData[id].kind === 'sub' ? 'Sub' : 'Servers') : simpleMode() ? 'Simple' : 'Profiles';
  badge.textContent = autoConnect ? 'AUTO' : 'MANUAL';
  badge.style.color = autoConnect ? 'var(--active)' : 'var(--warn)';
  badge.style.background = autoConnect ? 'rgba(var(--active-rgb),.15)' : 'rgba(var(--warn-rgb),.15)';

  let lat = null;
  if (!e) detail.innerHTML = none ? '<span class="dock-node none">turn on Use in Auto in Route</span>'
    : empty ? `<span class="dock-node none">${simpleMode() ? 'Add in Nodes' : 'Create one in Nodes'}</span>` : '';
  else if (chainsData[id]) {
    const c = chainsData[id], a = chainEntryNode(c), b = chainExitNode(c);
    detail.innerHTML = nodeHtml(a) + '<span class="dock-arrow">→</span>' + nodeHtml(b);
    if (ms(a) != null && ms(b) != null) lat = ms(a) + ms(b);
  } else {
    const n = unitNode(id), ref = unitRefs(id).find(r => r.node === n);
    detail.innerHTML = (profilesData[id] && ref ? `<span class="dock-src">${esc(sourcesData[ref.sid].name)}</span><span class="dock-sep">›</span>` : '') + nodeHtml(n);
    lat = ms(n);
  }
  document.getElementById('profMetaCount').textContent = lat == null ? '—' : lat;
  document.getElementById('profMetaSrc').textContent = 'ms';
}
