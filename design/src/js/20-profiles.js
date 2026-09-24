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
// p.nodes = individually picked nodes as 'sid::nid' (kept only while the server exists).
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

// A "unit" is what a list entry / chain end stands for: a profile, or (simple mode) a source.
function unitRefs(id) {
  if (profilesData[id]) return profileNodeRefs(profilesData[id]);
  const s = sourcesData[id];
  return s && s.enabled ? s.nodes.map(node => ({ sid: id, node })) : [];
}
const unitName = id => { const u = profilesData[id] || sourcesData[id]; return u ? u.name : '—'; };

// The node a unit would connect through: the best alive one.
function unitNode(id) {
  let best = null;
  unitRefs(id).forEach(({ node }) => { if (isAlive(node) && (!best || ping(node) < ping(best))) best = node; });
  return best;
}
const profileNode = p => p ? unitNode(p.id) : null;

// A chain's exit server: its own fixed exit if set, else the exit unit's best node.
function chainExitNode(c) {
  if (c.exitNodeId) {
    const r = unitRefs(c.outId).find(r => r.sid + '::' + r.node.id === c.exitNodeId);
    return r ? r.node : null;
  }
  return unitNode(c.outId);
}

function isUsable(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    const exit = chainExitNode(c);
    return isUsable(c.inId) && !!exit && isAlive(exit);
  }
  const n = unitNode(id);
  return !!n && isAlive(n);
}

// What is actually connected: the pinned entry, or Auto's pick.
function effectiveConnectId() {
  if (!autoConnect) return activeConnectId;
  return connectOrder.find(id => connectEntry(id).inAuto && isUsable(id))
      || connectOrder.find(id => connectEntry(id).inAuto) || connectOrder[0];
}

function nodeSummaryHtml(n, fixed) {
  if (!n) return `<span>${fixed ? 'Fixed node not set' : 'No working nodes'}</span>`;
  return `<span>${n.flag}</span><span class="conn-node">${esc(n.name)}</span>${latHtml(n)}`;
}

function entrySummaryHtml(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    const end = (uid, n) => (n ? n.flag + ' ' : '') + esc(unitName(uid));
    return `<span>${end(c.inId, unitNode(c.inId))}</span><span class="conn-arrow">→</span>`
      + (c.exitNodeId ? '<span class="conn-tag warn">fixed</span>' : '') + `<span>${end(c.outId, chainExitNode(c))}</span>`;
  }
  if (sourcesData[id] && !sourcesData[id].enabled) return '<span>Disabled in Nodes</span>';
  return nodeSummaryHtml(unitNode(id), false);
}

const GRIP_SVG = '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>';

function renderConnectRow(id) {
  const e = connectEntry(id);
  const chain = !!chainsData[id];
  const current = id === effectiveConnectId();
  const tags = (chain ? '<span class="conn-tag">chain</span>' : '')
    + (autoConnect && !e.inAuto ? '<span class="conn-tag muted">not in Auto</span>' : '');
  return `<div class="conn-row ${current ? 'current' : ''} ${autoConnect && !e.inAuto ? 'skip' : ''}" data-id="${id}">
    <div class="drag-handle" onpointerdown="startConnectDrag(event,'${id}')" title="Drag to set Auto priority">${GRIP_SVG}</div>
    <div class="conn-main" onclick="selectConnect('${id}')">
      <div class="conn-name"><span class="conn-title">${esc(e.name)}</span>${tags}</div>
      <div class="conn-sub">${entrySummaryHtml(id)}</div>
    </div>
    ${current ? `<span class="conn-state">${autoConnect ? 'auto' : 'manual'}</span>` : ''}
    <button class="icon-btn ghost" onclick="${chain ? 'openEditChain' : profilesData[id] ? 'openEditProfile' : 'openConnectSourceActions'}('${id}')" title="Edit">
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
  document.getElementById('connects-list').innerHTML = connectOrder.map(renderConnectRow).join('');
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
  if (simpleMode()) { openCreateChain(); return; }   // sources are added in Nodes
  const close = "closeSheet('actions');";
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
    menuRow(radio(simpleMode()), 'Simple<div class="menu-sub">Subscriptions and servers directly, plus chains of them</div>', "setConnectMode('simple')") +
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

// Simple mode ⋯ on a source row: Auto participation plus the source's own actions.
function openConnectSourceActions(sid) {
  const s = sourcesData[sid];
  const close = "closeSheet('actions');";
  let rows = `<div class="menu-row" onclick="toggleSourceInAuto('${sid}')"><div class="menu-label">Use in Auto<div class="menu-sub">Auto may connect this ${s.kind === 'sub' ? 'subscription' : 'group'}, in list order</div></div>${miniToggleHtml(sid, 'toggleSourceInAuto', s.inAuto)}</div>`;
  rows += menuRow(ICON.bolt, 'Ping all nodes', close + `testSourceLatency('${sid}')`);
  if (s.kind === 'sub') rows += menuRow(ICON.refresh, 'Update subscription', close + `updateSource('${sid}')`);
  rows += menuRow(ICON.edit, s.kind === 'sub' ? 'Edit subscription' : 'Rename group', close + `openSrcForm('${sid}')`);
  openActions(s.name, rows);
}

function toggleSourceInAuto(sid) {
  sourcesData[sid].inAuto = !sourcesData[sid].inAuto;
  renderConnects();
  updateMainConnectCard();
  openConnectSourceActions(sid);
}

function toggleRuleEnabled(id) {
  rulesData[id].enabled = !rulesData[id].enabled;
  renderRules();
}

/* ── Home dock ── */

function updateMainConnectCard() {
  const id = effectiveConnectId();
  const e = connectEntry(id);
  const badge = document.getElementById('profModeBadge');
  const detail = document.getElementById('profModeDetail');
  document.getElementById('profCardName').textContent = e ? e.name : '—';
  document.getElementById('profCardLabel').textContent = simpleMode() ? 'Servers' : 'Profiles';
  badge.textContent = autoConnect ? 'AUTO' : 'MANUAL';
  badge.style.color = autoConnect ? 'var(--active)' : 'var(--warn)';
  badge.style.background = autoConnect ? 'rgba(var(--active-rgb),.15)' : 'rgba(var(--warn-rgb),.15)';

  if (chainsData[id]) {
    const c = chainsData[id];
    detail.textContent = unitName(c.inId) + ' → ' + unitName(c.outId);
    document.getElementById('profMetaCount').textContent = '';
    document.getElementById('profMetaSrc').textContent = 'chain';
    return;
  }
  const n = unitNode(id);
  detail.textContent = n ? n.flag + ' ' + n.name + (isAlive(n) ? ' · ' + ping(n) + ' ms' : '') : 'no working nodes';
  document.getElementById('profMetaCount').textContent = unitRefs(id).length;
  document.getElementById('profMetaSrc').textContent = profilesData[id] ? 'nodes · ' + profilesData[id].sources.length + ' src'
    : sourcesData[id] && sourcesData[id].kind === 'sub' ? 'nodes · sub' : 'servers';
}
