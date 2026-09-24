/* ══════════════════════ PROFILES SHEET (entries + chains in one priority list) ══════════════════════
   Entries are sources in simple mode, profiles in profiles mode (see connectMode).
   connectOrder is the Auto priority: with Auto on, the first usable entry that has
   inAuto wins. Tapping an entry pins it (Auto off). Everything else about an entry —
   sources and picked nodes, chain ends, "use in Auto" — lives in its editor (⋯). */

const connectEntry = id => profilesData[id] || chainsData[id] || sourcesData[id];
const simpleMode = () => connectMode === 'simple';
const unitWord = () => simpleMode() ? 'source' : 'profile';

// Nodes a profile can use right now (enabled sources only), as {sid, node}.
// p.sources = whole sources (every node, including ones a subscription update adds later);
// p.nodes = individually picked nodes as 'sid::nid' (kept while the provider has dropped
// the server too — see s.gone — so the pick is back when the server is).
function profileNodeRefs(p) {
  const refs = [];
  sourceOrder.forEach(sid => {
    const s = sourcesData[sid];
    if (!s || !s.enabled) return;
    const whole = p.sources.includes(sid);
    s.nodes.forEach(n => { if (whole || p.nodes.includes(sid + '::' + n.id)) refs.push({ sid, node: n }); });
  });
  return refs;
}

const isNodeOff = (s, nid) => !!s.offNodes && s.offNodes.includes(nid);
const offCount = s => s.nodes.filter(n => isNodeOff(s, n.id)).length;

// A "unit" is what a list entry / chain end stands for: a profile, or (simple mode) a source.
function unitRefs(id) {
  if (profilesData[id]) return profileNodeRefs(profilesData[id]);
  const s = sourcesData[id];
  return s && s.enabled ? s.nodes.filter(n => !isNodeOff(s, n.id)).map(node => ({ sid: id, node })) : [];
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

/* Switching a source off in Nodes never edits what uses it: switched back on, it is back
   in its profiles and chains with the same ticks and priority.
   - simple mode: the source's own entry is hidden while off;
   - a profile / chain that has nothing left without it is "broken": greyed with a red
     edge, shown below the list (its priority slot is kept), skipped by Auto; tapping it
     says which required source is off. brokenBy(id) = names of those sources, or []. */
function profileOffSources(p) {
  return sourceOrder.filter(sid => !sourcesData[sid].enabled
    && (p.sources.includes(sid) || p.nodes.some(k => k.startsWith(sid + '::'))));
}
function brokenBy(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    return [...new Set(brokenBy(c.inId).concat(brokenBy(c.outId)))];
  }
  if (sourcesData[id]) return sourcesData[id].enabled ? [] : [sourcesData[id].name];
  const p = profilesData[id];
  return p && !profileNodeRefs(p).length ? profileOffSources(p).map(sid => sourcesData[sid].name) : [];
}
const isBroken = id => brokenBy(id).length > 0;
const entryVisible = id => !(sourcesData[id] && !sourcesData[id].enabled);
// The list as shown: working entries in priority order (draggable), broken ones below.
const visibleOrder = () => connectOrder.filter(id => entryVisible(id) && !isBroken(id));
const brokenOrder = () => connectOrder.filter(id => entryVisible(id) && isBroken(id));

const unitName = id => { const u = profilesData[id] || sourcesData[id]; return u ? u.name : '—'; };

// The node a unit would connect through: the best alive one.
function unitNode(id) {
  return bestAlive(unitRefs(id).map(r => r.node));
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
function chainEntryRefs(c) { return unitRefs(c.inId).filter(r => !(c.inOff || []).includes(refKey(r))); }
// Every exit server in priority order, switched-off ones included.
function chainExitOrder(c) {
  const order = c.exitOrder || [];
  const pos = k => { const i = order.indexOf(k); return i < 0 ? Infinity : i; };
  return unitRefs(c.outId).map((r, i) => ({ r, i }))
    .sort((a, b) => (pos(refKey(a.r)) - pos(refKey(b.r))) || a.i - b.i).map(x => x.r);
}
function chainExitRefs(c) { return chainExitOrder(c).filter(r => !(c.outOff || []).includes(refKey(r))); }
const chainEntryNode = c => bestAlive(chainEntryRefs(c).map(r => r.node));
function chainExitNode(c) {
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

// What is actually connected: the pinned entry, or Auto's pick.
function effectiveConnectId() {
  if (!autoConnect && entryVisible(activeConnectId) && !isBroken(activeConnectId)) return activeConnectId;
  const order = visibleOrder();
  return order.find(id => connectEntry(id).inAuto && isUsable(id))
      || order.find(id => connectEntry(id).inAuto) || order[0];
}

function nodeSummaryHtml(n, fixed) {
  if (!n) return `<span>${fixed ? 'Fixed node not set' : 'No working nodes'}</span>`;
  return `<span>${n.flag}</span><span class="conn-node">${esc(n.name)}</span>${latHtml(n)}`;
}

function entrySummaryHtml(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    const end = (uid, n) => (n ? n.flag + ' ' : '') + esc(unitName(uid));
    return `<span>${end(c.inId, chainEntryNode(c))}</span><span class="conn-arrow">→</span>`
      + (c.exitMode === 'priority' ? '<span class="conn-tag muted">priority</span>' : '') + `<span>${end(c.outId, chainExitNode(c))}</span>`;
  }
  return nodeSummaryHtml(unitNode(id), false);
}

const GRIP_SVG = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>';

function renderConnectRow(id) {
  const e = connectEntry(id);
  const chain = !!chainsData[id];
  const current = id === effectiveConnectId();
  const tags = (chain ? '<span class="conn-tag">chain</span>' : sourcesData[id] && offCount(sourcesData[id]) ? `<span class="conn-tag muted">${offCount(sourcesData[id])} off</span>` : '')
    + (autoConnect && !e.inAuto ? '<span class="conn-tag muted">not in Auto</span>' : '');
  return `<div class="conn-row ${current ? 'current' : ''} ${autoConnect && !e.inAuto ? 'skip' : ''}" data-id="${id}">
    <div class="drag-handle" onpointerdown="startConnectDrag(event,'${id}')" title="Drag to set Auto priority">${GRIP_SVG}</div>
    <div class="conn-main" onclick="selectConnect('${id}')">
      <div class="conn-name"><span class="conn-title">${esc(e.name)}</span>${tags}</div>
      <div class="conn-sub">${entrySummaryHtml(id)}</div>
    </div>
    ${current ? `<span class="conn-state">${autoConnect ? 'auto' : 'manual'}</span>` : ''}
    <button class="icon-btn ghost" onclick="${chain ? 'openEditChain' : profilesData[id] ? 'openEditProfile' : 'openSourceEntry'}('${id}')" title="Edit">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg>
    </button>
  </div>`;
}

function renderConnects() {
  const badge = document.getElementById('autoBadge');
  badge.classList.toggle('off', !autoConnect);
  badge.querySelector('span').textContent = autoConnect ? 'Auto' : 'Manual';
  document.getElementById('profilesTitle').textContent = simpleMode() ? 'Servers' : 'Profiles';
  document.getElementById('createEntryLabel').textContent = simpleMode() ? 'Create chain' : 'Create profile or chain';
  const broken = brokenOrder();
  document.getElementById('connects-list').innerHTML = (visibleOrder().map(renderConnectRow).join('')
    || `<div class="route-empty">${simpleMode() ? 'No enabled subscriptions or servers — add or switch one on in Nodes' : 'No working profiles'}</div>`)
    + (broken.length ? `<div class="conn-broken-list">${broken.map(renderBrokenRow).join('')}</div>` : '');
}

// Outside #connects-list's direct children, so the drag never counts these rows.
function renderBrokenRow(id) {
  const e = connectEntry(id);
  return `<div class="conn-row broken" data-id="${id}" onclick="explainBroken('${id}')">
    <div class="drag-handle"></div>
    <div class="conn-main">
      <div class="conn-name"><span class="conn-title">${esc(e.name)}</span>${chainsData[id] ? '<span class="conn-tag">chain</span>' : ''}<span class="conn-tag off">off</span></div>
      <div class="conn-sub"><span>${esc(brokenBy(id).join(', '))} ${brokenBy(id).length > 1 ? 'are' : 'is'} off in Nodes</span></div>
    </div>
  </div>`;
}

function explainBroken(id) {
  const names = brokenBy(id), kind = chainsData[id] ? 'chain' : 'profile';
  const offIds = sourceOrder.filter(sid => !sourcesData[sid].enabled && names.includes(sourcesData[sid].name));
  const close = "closeSheet('actions');";
  openActions(connectEntry(id).name,
    `<div class="menu-note">This ${kind} needs <b>${esc(names.join(', '))}</b>, switched off in Nodes. Switch it on, or pick another ${chainsData[id] ? unitWord() : 'subscription or server'} for the ${kind}. Its settings are kept either way.</div>`
    + offIds.map(sid => menuRow(ICON.power, 'Switch on ' + esc(sourcesData[sid].name), close + `enableSource('${sid}')`)).join('')
    + menuRow(ICON.edit, 'Edit ' + kind, close + `${chainsData[id] ? 'openEditChain' : 'openEditProfile'}('${id}')`));
}
function enableSource(sid) {
  sourcesData[sid].enabled = true;
  renderAll();
}

function openProfiles() {
  renderConnects();
  openSheet('profiles');
}

function setAutoConnect(on) {
  autoConnect = on;
  if (!on) activeConnectId = effectiveConnectIdWhenAuto();
  renderConnects();
  updateMainConnectCard();
}
function effectiveConnectIdWhenAuto() {
  const was = autoConnect; autoConnect = true;
  const id = effectiveConnectId(); autoConnect = was; return id;
}

function selectConnect(id) {
  if (!autoConnect && activeConnectId === id) autoConnect = true;   // second tap on the pinned entry → back to Auto
  else { autoConnect = false; activeConnectId = id; }
  renderConnects();
  updateMainConnectCard();
}

const CHAIN_ICON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/></svg>';

function openCreateMenu() {
  const close = "closeSheet('actions');";
  if (simpleMode()) { openCreateChain(); return; }   // entries themselves come from Nodes
  openActions('Create',
    menuRow(ICON.plus.replace(/16/g, '18'), 'Profile<div class="menu-sub">Chosen subscriptions or single servers — uses the fastest</div>', close + 'openCreateProfile()') +
    menuRow(CHAIN_ICON,
      'Chain<div class="menu-sub">' + (getProfileIds().length < 2 ? 'Needs at least two profiles' : 'Enter through one profile, exit through another') + '</div>',
      close + 'openCreateChain()', getProfileIds().length < 2 ? 'disabled' : ''));
}

/* ── Mode: simple (sources) / profiles ── */

function openProfilesMenu() {
  const radio = on => `<div class="profile-radio ${on ? 'active' : ''}"></div>`;
  openActions('Mode',
    menuRow(radio(simpleMode()), 'Simple<div class="menu-sub">Subscriptions and server sets from Nodes, plus chains of them</div>', "setConnectMode('simple')") +
    menuRow(radio(!simpleMode()), 'Profiles<div class="menu-sub">Group servers into profiles, plus chains of profiles</div>', "setConnectMode('profiles')"));
}

function setConnectMode(mode) {
  closeSheet('actions');
  if (mode === connectMode) return;
  modeState[connectMode] = { order: connectOrder, active: activeConnectId, auto: autoConnect };
  ({ order: connectOrder, active: activeConnectId, auto: autoConnect } = modeState[mode]);
  connectMode = mode;
  renderConnects();
  updateMainConnectCard();
}

// Priority list of either mode (the active one lives in the globals).
function modeOrder(mode) { return mode === connectMode ? connectOrder : modeState[mode].order; }
function setModeOrder(mode, order) { if (mode === connectMode) connectOrder = order; else modeState[mode].order = order; }

// A new source joins the end of the simple-mode list.
function sourceAdded(id) {
  if (sourcesData[id].inAuto === undefined) sourcesData[id].inAuto = true;
  if (!sourcesData[id].offNodes) sourcesData[id].offNodes = [];
  setModeOrder('simple', modeOrder('simple').concat(id));
  if (document.getElementById('sh-profiles').classList.contains('open')) renderConnects();
}

// Remove a unit and every chain that uses it from both modes' lists.
function dropConnectEntry(id) {
  const gone = new Set([id]);
  Object.values(chainsData).forEach(c => { if (c.inId === id || c.outId === id) { gone.add(c.id); delete chainsData[c.id]; } });
  ['simple', 'profiles'].forEach(mode => {
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
  const id = effectiveConnectId();
  const e = connectEntry(id);
  const badge = document.getElementById('profModeBadge');
  const detail = document.getElementById('profModeDetail');
  const nodeHtml = n => n ? `<span class="dock-node">${n.flag} ${esc(n.name)}</span>` : '<span class="dock-node none">no working node</span>';
  const ms = n => n && isAlive(n) ? ping(n) : null;
  document.getElementById('profCardName').textContent = e ? e.name : '—';
  document.getElementById('profCardLabel').textContent = chainsData[id] ? 'Chain' : profilesData[id] ? 'Profile'
    : sourcesData[id] ? (sourcesData[id].kind === 'sub' ? 'Sub' : 'Servers') : simpleMode() ? 'Servers' : 'Profiles';
  badge.textContent = autoConnect ? 'AUTO' : 'MANUAL';
  badge.style.color = autoConnect ? 'var(--active)' : 'var(--warn)';
  badge.style.background = autoConnect ? 'rgba(var(--active-rgb),.15)' : 'rgba(var(--warn-rgb),.15)';

  let lat = null;
  if (!e) detail.innerHTML = '';
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
