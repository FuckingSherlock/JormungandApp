/* ══════════════════════ NODES TABS: Simple / Profiles ══════════════════════
   The two tabs are the catalog of the two connect modes (catalogOrder): Servers = sources
   and chains of sources, Profiles = profiles and chains of profiles. Everything is created,
   edited and deleted here; the Route sheet only picks Auto / Manual and may override the
   priority. Which tab the route uses is its mode (chosen in Route); a dot marks that tab.
   Tapping or swiping a tab only changes what is shown — never the route.

   Swipe: the whole list follows a horizontal finger; past ~20% of the width it snaps to the
   other tab. It starts only on a clearly horizontal move (vertical scroll and ⋮⋮ drags win)
   and never within 24px of the screen edge, where Android has its back gesture. */

const NODES_TABS = ['simple', 'profiles'];
let nodesTab = 'simple';
let pagerSwipe = null, pagerSwallowClick = false;

function setNodesTab(tab) {
  if (tab === nodesTab) return;
  nodesTab = tab;
  renderNodesTabs();
  renderNodesSummary();
}

function renderNodesTabs(dx = 0) {
  const i = NODES_TABS.indexOf(nodesTab);
  document.getElementById('nodesTrack').style.transform = `translateX(calc(${-i * 50}% + ${dx}px))`;
  document.getElementById('nodesTabInk').style.transform = `translateX(calc(${i * 100}% - ${dx / 2}px))`;
  document.querySelectorAll('#nodesTabs .nodes-tab').forEach(b => {
    b.classList.toggle('active', b.dataset.tab === nodesTab);
    b.classList.toggle('used', b.dataset.tab === connectMode);
  });
}

function initNodesPager() {
  const pager = document.getElementById('nodesPager');
  pager.addEventListener('pointerdown', e => {
    if (dragCtx || e.button > 0 || e.target.closest('.drag-handle, input, select, textarea')) return;
    const r = pager.getBoundingClientRect();
    if (e.pointerType !== 'mouse' && (e.clientX - r.left < 24 || r.right - e.clientX < 24)) return;
    pagerSwipe = { x: e.clientX, y: e.clientY, dir: null, w: r.width, dx: 0 };
  });
  window.addEventListener('pointermove', e => {
    const s = pagerSwipe;
    if (!s || dragCtx) return;
    const dx = e.clientX - s.x, dy = e.clientY - s.y;
    if (!s.dir) {
      if (Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.5) { s.dir = 'h'; document.getElementById('view-nodes').classList.add('swiping'); }
      else if (Math.abs(dy) > 10) { pagerSwipe = null; return; }
      else return;
    }
    const i = NODES_TABS.indexOf(nodesTab);
    s.dx = (i === 0 && dx > 0) || (i === NODES_TABS.length - 1 && dx < 0) ? dx / 4 : dx;   // rubber band at the ends
    renderNodesTabs(s.dx);
  });
  const end = () => {
    const s = pagerSwipe;
    pagerSwipe = null;
    if (!s || s.dir !== 'h') return;
    document.getElementById('view-nodes').classList.remove('swiping');
    pagerSwallowClick = true;
    setTimeout(() => { pagerSwallowClick = false; }, 0);
    const i = NODES_TABS.indexOf(nodesTab), step = Math.abs(s.dx) > s.w * 0.2 ? (s.dx < 0 ? 1 : -1) : 0;
    const next = NODES_TABS[Math.max(0, Math.min(NODES_TABS.length - 1, i + step))];
    if (next !== nodesTab) setNodesTab(next); else renderNodesTabs();
  };
  window.addEventListener('pointerup', end);
  window.addEventListener('pointercancel', end);
  // The pointerup of a swipe must not also tap the card under the finger.
  pager.addEventListener('click', e => { if (pagerSwallowClick) { e.stopPropagation(); e.preventDefault(); } }, true);
  renderNodesTabs();
}

function renderNodesSummary() {
  let text;
  if (nodesTab === 'simple') {
    const total = sourceOrder.reduce((sum, id) => sum + sourcesData[id].nodes.length, 0);
    text = sourceOrder.length + ' source' + (sourceOrder.length === 1 ? '' : 's') + ' · ' + total + ' nodes';
  } else {
    const p = getProfileIds().length, c = catalogOrder.profiles.filter(id => chainsData[id]).length;
    text = p + ' profile' + (p === 1 ? '' : 's') + ' · ' + c + ' chain' + (c === 1 ? '' : 's');
  }
  document.getElementById('nodesSummary').textContent = text;
}

function openNodesAdd() {
  if (nodesTab === 'profiles') { openCreateMenu(); return; }
  document.getElementById('addChainRow').classList.toggle('disabled', unitIdsOf('simple').length < 2);
  openSheet('addmenu');
}

/* ── Profile / chain cards (a tab's list, next to source cards) ──
   Head: name, what it is made of, Fastest / Priority. Line below: the server it would use
   now with its ping (a chain: entry → exit and the two hops added up), or what is off in
   Nodes. Expanded: its servers — tap one to ping it. ⋮ = Edit / Test / Delete. */

function entryMetaHtml(id) {
  const dot = '<span class="dot">·</span>';
  if (chainsData[id]) {
    const c = chainsData[id];
    return `<span class="fmt-tag">chain</span>${dot}<span class="entry-ends">${esc(unitName(c.inId))} → ${esc(unitName(c.outId))}</span>`
      + (c.exitMode === 'priority' ? `${dot}<span>exit by priority</span>` : '');
  }
  const p = profilesData[id], n = unitRefs(id).length;
  const made = [p.sources.length ? p.sources.length + ' source' + (p.sources.length === 1 ? '' : 's') : '',
    p.nodes.length ? p.nodes.length + ' picked' : ''].filter(Boolean).join(' + ');
  return `<span class="fmt-tag">profile</span>${dot}<span>${n} server${n === 1 ? '' : 's'}</span>`
    + (made ? `${dot}<span>${made}</span>` : '');   // Priority shows as a tag on the line below
}

function entryNowHtml(id) {
  if (isBroken(id)) return `<div class="entry-now bad">${esc(reasonsText(brokenBy(id)))}</div>`;
  if (chainsData[id]) {   // the ends' names are in the meta line: here the two servers and the hops added up
    const c = chainsData[id], a = chainEntryNode(c), b = chainExitNode(c);
    const node = n => n ? `<span class="conn-node">${n.flag} ${esc(n.name)}</span>` : '<span class="conn-node">no working server</span>';
    const total = a && b && isAlive(a) && isAlive(b) ? `<span class="entry-total">${latMsHtml(ping(a) + ping(b))}</span>` : '';
    return `<div class="entry-now">${node(a)}<span class="conn-arrow">→</span>${node(b)}${total}</div>`;
  }
  return `<div class="entry-now">${entrySummaryHtml(id)}</div>`;
}

function entryNodeRowsHtml(refs, now) {
  return refs.map(r => `<div class="node-row tap ${r.node === now ? 'now' : ''}" onclick="testLatency([['${r.sid}','${r.node.id}']])" title="Tap to ping">
      <span class="node-flag">${r.node.flag}</span>
      <span class="node-name">${esc(r.node.name)}<span class="node-src">${esc(sourcesData[r.sid].name)}</span></span>
      <span class="node-proto">${r.node.protocol}</span>${latHtml(r.node)}</div>`).join('')
    || '<div class="entry-empty">No working servers</div>';
}

// Edit mode on a chain card: every server of each end, framed = used by this chain,
// tap = on / off for this chain only (inOff / outOff, same as the ticks in the chain editor).
function chainEditRowsHtml(id, side) {
  const c = chainsData[id], off = (side === 'in' ? c.inOff : c.outOff) || [];
  const refs = side === 'in' || c.exitMode !== 'priority' ? byPing(side === 'in' ? unitRefs(c.inId) : chainExitOrder(c), r => r.node) : chainExitOrder(c);
  return refs.map(r => { const k = refKey(r), on = !off.includes(k);
    return `<div class="node-row pick ${on ? 'on' : 'disabled'}" data-key="${k}" onclick="toggleChainNodeIn('${id}','${side}','${k}')" title="Tap: on / off in this chain">
      <span class="node-flag">${r.node.flag}</span>
      <span class="node-name">${esc(r.node.name)}<span class="node-src">${esc(sourcesData[r.sid].name)}</span></span>
      <span class="node-proto">${r.node.protocol}</span>${latHtml(r.node)}</div>`; }).join('')
    || '<div class="entry-empty">No working servers</div>';
}
function toggleChainNodeIn(id, side, key) {
  const c = chainsData[id], f = side === 'in' ? 'inOff' : 'outOff', off = c[f] || [];
  c[f] = off.includes(key) ? off.filter(x => x !== key) : off.concat(key);
  renderNodes();
  if (document.getElementById('sh-profiles').classList.contains('open')) renderConnects();
}

function renderEntryCard(id, q) {
  const e = connectEntry(id);
  if (!e) return '';
  if (q && !e.name.toLowerCase().includes(q)) return '';
  const chain = chainsData[id];
  const open = !!expandState[id], broken = isBroken(id);
  const grip = !nodesEdit ? '' : q ? '<div class="drag-handle" style="visibility:hidden"></div>'
    : `<div class="drag-handle" onpointerdown="startSourceDrag(event,'${id}')" onclick="event.stopPropagation()" title="Drag to reorder">${GRIP_SVG}</div>`;
  const side = (s, label) => `<div class="entry-side">${label} · ${esc(unitName(s === 'in' ? chain.inId : chain.outId))}</div>`
    + (nodesEdit ? chainEditRowsHtml(id, s) : s === 'in' ? entryNodeRowsHtml(byPing(chainEntryRefs(chain), r => r.node), chainEntryNode(chain))
      : entryNodeRowsHtml(chain.exitMode === 'priority' ? chainExitRefs(chain) : byPing(chainExitRefs(chain), r => r.node), chainExitNode(chain)));
  const body = chain
    ? side('in', 'Entry') + side('out', 'Exit')
    : entryNodeRowsHtml(unitPriority(id) ? unitPickRefs(id) : byPing(unitPickRefs(id), r => r.node), unitNode(id));
  return `<div class="src-card entry-card ${open ? 'open' : ''} ${broken ? 'broken' : ''}" data-id="${id}">
    <div class="src-top">
    ${grip}
    <div class="src-top-main">
    <div class="src-head" onclick="toggleSourceOpen('${id}')">
      <div class="src-main">
        <div class="src-name">${esc(e.name)}${broken ? '<span class="conn-tag off">off</span>' : ''}<svg class="src-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg></div>
        <div class="src-meta">${entryMetaHtml(id)}</div>
      </div>
      ${nodesEdit ? '' : `<button class="icon-btn ghost" onclick="event.stopPropagation();testEntryLatency('${id}')" title="Test latency">${ICON.bolt}</button>`}
      <button class="icon-btn ghost" onclick="event.stopPropagation();${chain ? 'openEditChain' : 'openEditProfile'}('${id}')" title="Edit ${chain ? 'chain' : 'profile'}">${ICON.edit}</button>
    </div>
    ${entryNowHtml(id)}
    </div>
    </div>
    <div class="src-body">${body}</div>
  </div>`;
}

function entryRefs(id) {
  const c = chainsData[id];
  return c ? chainEntryRefs(c).concat(chainExitRefs(c)) : unitRefs(id);
}
function testEntryLatency(id) { testLatency(entryRefs(id).map(r => [r.sid, r.node.id])); }

/* Delete sits inside the profile / chain editor (the card has only ⚡ and ✎).
   Deleting a profile moves the chains that use it to the first other profile (a chain left
   with the same profile on both ends is deleted). Rules and apps that target the deleted
   profile / chain keep pointing at it and do what their "If unavailable" says. */
function confirmDeleteEntry(id) {
  const e = connectEntry(id);
  if (!e) return;
  const lines = [];
  const dead = new Set(['chain:' + id, 'profile:' + id]);
  if (profilesData[id]) {
    const others = getProfileIds().filter(x => x !== id);
    if (!others.length) { toast('Keep at least one profile'); return; }
    const fb = others[0];
    Object.values(chainsData).forEach(c => {
      if (c.inId !== id && c.outId !== id) return;
      const inId = c.inId === id ? fb : c.inId, outId = c.outId === id ? fb : c.outId;
      if (inId === outId) { lines.push([c.name, 'chain', 'is deleted with it', 'bad']); dead.add('chain:' + c.id); }
      else lines.push([c.name, 'chain', `its ${c.inId === id ? 'entry' : 'exit'} moves to ${esc(profilesData[fb].name)}`, 'warn']);
    });
  }
  if (effectiveConnectId() === id) lines.unshift(['Current connection', '', 'goes through it — will reconnect through the next entry', 'warn']);
  const kind = chainsData[id] ? 'chain' : 'profile';
  openActions('Delete ' + e.name + '?', confirmDeleteHtml(`The ${kind} is removed from Nodes and from the route. This can’t be undone.`,
    lines.concat(targetImpact(t => dead.has(t))), `deleteEntry('${id}')`, 'Delete ' + kind));
}

function deleteEntry(id) {
  if (profilesData[id]) { editingProfileId = id; deleteEditingProfile(); }
  else if (chainsData[id]) { editingChainId = id; deleteEditingChain(); }
}
