/* ══════════════════════ PROFILES SHEET (profiles + chains in one priority list) ══════════════════════
   connectOrder is the Auto priority: with Auto on, the first usable entry that has
   inAuto wins. Tapping an entry pins it (Auto off). Everything else about an entry —
   sources and picked nodes, chain ends, "use in Auto" — lives in its editor (⋯). */

const connectEntry = id => profilesData[id] || chainsData[id];

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

// The node a profile would connect through: the best alive one.
function profileNode(p) {
  if (!p) return null;
  const refs = profileNodeRefs(p);
  let best = null;
  refs.forEach(({ node }) => { if (isAlive(node) && (!best || ping(node) < ping(best))) best = node; });
  return best;
}

// A chain's exit server: its own fixed exit if set, else what the exit profile picks.
function chainExitNode(c) {
  if (c.exitNodeId) {
    const r = profileNodeRefs(profilesData[c.outId]).find(r => r.sid + '::' + r.node.id === c.exitNodeId);
    return r ? r.node : null;
  }
  return profileNode(profilesData[c.outId]);
}

function isUsable(id) {
  if (chainsData[id]) {
    const c = chainsData[id];
    const exit = chainExitNode(c);
    return isUsable(c.inId) && !!exit && isAlive(exit);
  }
  const n = profileNode(profilesData[id]);
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
    const end = (pid, n) => { const p = profilesData[pid]; return (n ? n.flag + ' ' : '') + esc(p ? p.name : '—'); };
    return `<span>${end(c.inId, profileNode(profilesData[c.inId]))}</span><span class="conn-arrow">→</span>`
      + (c.exitNodeId ? '<span class="conn-tag warn">fixed</span>' : '') + `<span>${end(c.outId, chainExitNode(c))}</span>`;
  }
  const p = profilesData[id];
  return nodeSummaryHtml(profileNode(p), false);
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
    <button class="icon-btn ghost" onclick="${chain ? 'openEditChain' : 'openEditProfile'}('${id}')" title="Edit">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg>
    </button>
  </div>`;
}

function renderConnects() {
  const badge = document.getElementById('autoBadge');
  badge.classList.toggle('off', !autoConnect);
  badge.querySelector('span').textContent = autoConnect ? 'Auto' : 'Manual';
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

function openCreateMenu() {
  const close = "closeSheet('actions');";
  openActions('Create',
    menuRow(ICON.plus.replace(/16/g, '18'), 'Profile<div class="menu-sub">Chosen subscriptions or single servers — uses the fastest</div>', close + 'openCreateProfile()') +
    menuRow('<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/></svg>',
      'Chain<div class="menu-sub">' + (getProfileIds().length < 2 ? 'Needs at least two profiles' : 'Enter through one profile, exit through another') + '</div>',
      close + 'openCreateChain()', getProfileIds().length < 2 ? 'disabled' : ''));
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
  badge.textContent = autoConnect ? 'AUTO' : 'MANUAL';
  badge.style.color = autoConnect ? 'var(--active)' : 'var(--warn)';
  badge.style.background = autoConnect ? 'rgba(var(--active-rgb),.15)' : 'rgba(var(--warn-rgb),.15)';

  if (chainsData[id]) {
    const c = chainsData[id];
    const nm = pid => profilesData[pid] ? profilesData[pid].name : '—';
    detail.textContent = nm(c.inId) + ' → ' + nm(c.outId);
    document.getElementById('profMetaCount').textContent = '';
    document.getElementById('profMetaSrc').textContent = 'chain';
    return;
  }
  const p = profilesData[id];
  const n = profileNode(p);
  detail.textContent = n ? n.flag + ' ' + n.name + (isAlive(n) ? ' · ' + ping(n) + ' ms' : '') : 'no working nodes';
  document.getElementById('profMetaCount').textContent = profileNodeCount(p);
  document.getElementById('profMetaSrc').textContent = 'nodes · ' + p.sources.length + ' src';
}
