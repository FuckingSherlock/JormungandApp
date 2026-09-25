/* ══════════════════════ CREATE / EDIT PROFILE ══════════════════════ */

// Draft selection: whole sources + single nodes ('sid::nid'). Ticking a source takes all
// its nodes (and future ones after an update); ticking nodes picks just those servers.
let createProfileSelected = new Set();
let cpNodes = new Set();
let editingProfileId = null;
let cpPickMode = 'fastest', cpPickOrder = [];   // Fastest / Priority of the draft (p.pickMode, p.pickOrder)

function cpSourceState(id) {
  if (createProfileSelected.has(id)) return 'all';
  return liveNodes(sourcesData[id]).some(n => cpNodes.has(id + '::' + n.id)) ? 'some' : 'none';
}

function openCreateProfile(editId) {
  editingProfileId = editId || null;
  if (editingProfileId) {
    const p = profilesData[editingProfileId];
    document.getElementById('cpTitle').textContent = 'Edit profile';
    document.getElementById('cpSaveBtn').textContent = 'Save changes';
    document.getElementById('cpDeleteBtn').style.display = '';
    document.getElementById('cp-name').value = p.name;
    createProfileSelected = new Set(p.sources);
    cpNodes = new Set(p.nodes);
    cpPickMode = p.pickMode || 'fastest';
    cpPickOrder = [...(p.pickOrder || [])];
    document.getElementById('cp-inauto').classList.toggle('on', p.inAuto);
  } else {
    document.getElementById('cpTitle').textContent = 'Create profile';
    document.getElementById('cpSaveBtn').textContent = 'Create profile';
    document.getElementById('cpDeleteBtn').style.display = 'none';
    document.getElementById('cp-name').value = '';
    createProfileSelected = new Set();
    cpNodes = new Set();
    cpPickMode = 'fastest';
    cpPickOrder = [];
    document.getElementById('cp-inauto').classList.add('on');
  }
  cpOpen.clear();
  const partial = cpSourceIds().find(id => cpSourceState(id) === 'some');
  if (partial) cpOpen.add(partial);   // show where the single picks are
  renderCreateProfileSources();
  openSheet('createprofile');
}

function openEditProfile(id) { openCreateProfile(id); }

// Each source is a collapsible card: tick = whole source; tap the name to see its nodes
// and tick single ones; update / ping act on the whole source.
const cpOpen = new Set();
// Sources switched off in Nodes are not offered, except ones this profile already uses:
// those show greyed ("off in Nodes") so the user sees why, picks kept for when it's back.
const cpSourceIds = () => sourceOrder.filter(id => sourcesData[id].enabled || cpSourceState(id) !== 'none');
const cpOffPicked = () => sourceOrder.filter(id => !sourcesData[id].enabled && cpSourceState(id) !== 'none');
// Servers the draft would use now: must be at least one to save. Servers switched off in
// Nodes are hidden here (picks kept) — cpDraftRefs(true) counts them to explain an empty draft.
const cpDraftRefs = withOff => profileNodeRefs({ sources: [...createProfileSelected], nodes: [...cpNodes] }, withOff);
const cpPickedCount = () => cpDraftRefs().length;

function renderCreateProfileSources() {
  const el = document.getElementById('cp-source-list');
  const none = !cpPickedCount(), offs = offReasons(cpDraftRefs(true));
  const warn = document.getElementById('cp-warn');
  warn.hidden = !none;
  warn.textContent = offs.length ? `${reasonsText(offs)} — switch ${offs.length > 1 ? 'one' : 'it'} on there or select another server`
    : 'Select at least 1 server — a profile with none can’t connect';
  document.getElementById('cpSaveBtn').disabled = none;
  renderCpOrder();
  el.innerHTML = cpSourceIds().map(id => {
    const s = sourcesData[id];
    const state = cpSourceState(id);
    if (!s.enabled) return `<div class="ps-card off" data-id="${id}">
      <div class="ps-head">
        <div class="ps-check" onclick="toggleCreateProfileSource('${id}')"><div class="sub-checkbox ${state === 'all' ? 'checked' : 'partial'}"></div></div>
        <div class="ps-main"><div class="ps-name">${esc(s.name)}</div><div class="src-meta"><span class="off-meta">off in Nodes</span><span class="dot">·</span>tap the box to drop it</div></div>
      </div>
    </div>`;
    const open = cpOpen.has(id), live = liveNodes(s);
    const alive = live.filter(isAlive).length;
    const picked = state === 'all' ? live.length : live.filter(n => cpNodes.has(id + '::' + n.id)).length;
    const meta = [s.kind === 'sub' ? 'subscription' : 'manual',
                  state === 'some' ? `${picked} of ${live.length} nodes` : `${live.length} nodes`, `${alive} alive`]
      .concat((s.gone || []).length ? [`<span class="gone-meta">${s.gone.length} unavailable</span>`] : []).join('<span class="dot">·</span>');
    const rows = open ? sortedNodes(live).map(n => {
      const key = id + '::' + n.id;
      const on = state === 'all' || cpNodes.has(key);
      return `<div class="node-row ps-node pick ${on ? 'on' : ''}" onclick="toggleCpNode('${id}','${n.id}')">
        <span class="node-flag">${n.flag}</span>
        <span class="node-name">${esc(n.name)}</span>
        <span class="node-proto">${n.protocol}</span>
        <span onclick="event.stopPropagation();testLatency([['${id}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
      </div>`;
    }).join('') + goneBlockHtml('cp:' + id, goneRefs(id),
      r => state === 'all' || cpNodes.has(id + '::' + r.node.id)) : '';
    const box = state === 'all' ? 'checked' : state === 'some' ? 'partial' : '';
    return `<div class="ps-card ${open ? 'open' : ''} ${state !== 'none' ? 'sel' : ''}" data-id="${id}">
      <div class="ps-head">
        <div class="ps-check" onclick="toggleCreateProfileSource('${id}')"><div class="sub-checkbox ${box}"></div></div>
        <div class="ps-main" onclick="toggleCpOpen('${id}')">
          <div class="ps-name">${esc(s.name)}<svg class="src-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg></div>
          <div class="src-meta">${meta}</div>
        </div>
        ${s.kind === 'sub' ? `<button class="icon-btn ghost" onclick="updateSource('${id}')" title="Update"><span class="${s.updating ? 'spin' : ''}" style="display:inline-flex">${ICON.refresh}</span></button>` : ''}
        <button class="icon-btn ghost" onclick="cpOpen.add('${id}');testSourceLatency('${id}')" title="Ping all">${ICON.bolt}</button>
      </div>
      <div class="ps-body">${rows}</div>
    </div>`;
  }).join('');
}

// Fastest / Priority: in Priority, every server the draft uses, in order, draggable.
function renderCpOrder() {
  const priority = cpPickMode === 'priority';
  document.getElementById('cp-mode').innerHTML = pickModeSwitch('cp:' + (editingProfileId || 'new'), priority, 'setCpPickMode')
    + pingAllBtn('testLatency(cpDraftRefs().map(r => [r.sid, r.node.id]))', 'Test latency of all its servers');
  document.getElementById('cp-mode-hint').textContent = priority
    ? 'The first working server from the top is used. Drag ⋮⋮ to order; pick servers above.'
    : 'The profile connects through the fastest of its servers.';
  document.getElementById('cp-order').innerHTML = !priority ? '' : orderRefs(cpDraftRefs(), cpPickOrder).map((r, i) => `<div class="node-row ps-node static" data-id="${refKey(r)}">
      <div class="drag-handle cc-grip" onpointerdown="startCpOrderDrag(event,'${refKey(r)}')">${GRIP_SVG}</div><span class="cc-rank">${i + 1}</span>
      <span class="node-flag">${r.node.flag}</span>
      <span class="node-name">${esc(r.node.name)}</span>
      <span class="node-proto">${esc(sourcesData[r.sid].name)}</span>
      <span onclick="event.stopPropagation();testLatency([['${r.sid}','${r.node.id}']])" title="Tap to ping">${latHtml(r.node)}</span>
    </div>`).join('') || '<div class="route-empty">Pick servers above</div>';
}
function setCpPickMode(mode) {
  cpPickMode = mode;
  renderCpOrder();
}
// Servers not shown now (off in Nodes, dropped, source switched off) keep their slots.
function startCpOrderDrag(e, key) {
  const shown = orderRefs(cpDraftRefs(), cpPickOrder).map(refKey);
  const full = cpPickOrder.concat(shown.filter(k => !cpPickOrder.includes(k)));
  const [order, done] = dragShown(full, shown, o => { cpPickOrder = o; });
  const rowEl = document.querySelector(`#cp-order .node-row[data-id="${key}"]`);
  startRowDrag(e, rowEl, '.node-row', order, () => { done(); renderCpOrder(); });
}

function toggleCpOpen(id) {
  if (cpOpen.has(id)) cpOpen.delete(id); else cpOpen.add(id);
  renderCreateProfileSources();
}

sourceViewHooks.push(() => {
  if (!document.getElementById('sh-createprofile').classList.contains('open')) return;
  renderCreateProfileSources();
});

const cpDropNodes = id => sourcesData[id].nodes.forEach(n => cpNodes.delete(id + '::' + n.id));

// Source tick: none/some → whole source, whole → none.
function toggleCreateProfileSource(id) {
  if (!sourcesData[id].enabled) {   // off in Nodes: the tick only removes it
    createProfileSelected.delete(id);
    [...cpNodes].forEach(k => { if (k.startsWith(id + '::')) cpNodes.delete(k); });
    renderCreateProfileSources();
    return;
  }
  const all = cpSourceState(id) === 'all';
  cpDropNodes(id);
  if (all) createProfileSelected.delete(id); else createProfileSelected.add(id);
  renderCreateProfileSources();
}

// Node tick. Unticking one node of a whole source turns it into "all but this one";
// ticking the last missing node turns the picks back into the whole source.
function toggleCpNode(sid, nid) {
  const s = sourcesData[sid], key = sid + '::' + nid;
  if (createProfileSelected.has(sid)) {
    createProfileSelected.delete(sid);
    s.nodes.concat(s.gone || []).forEach(n => { if (n.id !== nid) cpNodes.add(sid + '::' + n.id); });
  } else if (cpNodes.has(key)) cpNodes.delete(key);
  else {
    cpNodes.add(key);
    if (s.nodes.every(n => cpNodes.has(sid + '::' + n.id))) { cpDropNodes(sid); createProfileSelected.add(sid); }   // disabled ones count: a pick is kept as a pick
  }
  renderCreateProfileSources();
}

function saveCreateProfile() {
  if (!cpPickedCount()) return;
  const name = document.getElementById('cp-name').value.trim() || ('Profile ' + (++profileSeq));
  const fields = { sources: Array.from(createProfileSelected), nodes: Array.from(cpNodes),
                   inAuto: document.getElementById('cp-inauto').classList.contains('on'),
                   pickMode: cpPickMode, pickOrder: cpPickOrder.slice() };
  if (editingProfileId) {
    const p = profilesData[editingProfileId];
    p.name = name;
    Object.assign(p, fields);
  } else {
    const id = 'profile' + Date.now();
    profilesData[id] = Object.assign({ id, name }, fields);
    catalogOrder.profiles.push(id);
  }
  editingProfileId = null;
  renderAll();
  closeSheet('createprofile');
}

function deleteEditingProfile() {
  if (!editingProfileId) return;
  if (getProfileIds().length <= 1) { editingProfileId = null; closeSheet('createprofile'); return; }
  delete profilesData[editingProfileId];   // the catalog and both route lists drop it (syncCatalog)
  const fallback = getProfileIds()[0];
  if (activeConnectId === editingProfileId) activeConnectId = fallback;
  Object.values(chainsData).forEach(c => {
    if (c.inId === editingProfileId) c.inId = fallback;
    if (c.outId === editingProfileId) c.outId = fallback;
    if (c.inId === c.outId) {   // a chain through one profile is pointless: drop it
      delete chainsData[c.id];
      if (activeConnectId === c.id) activeConnectId = fallback;
    }
  });
  editingProfileId = null;
  renderAll();
  closeSheet('createprofile');
}

/* ══════════════════════ CREATE / EDIT CHAIN ══════════════════════
   Ends are profiles (profiles mode) or sources (simple mode) — "units", see unitRefs.
   Entry and exit must be different units. The chosen unit on each side expands to its
   servers, framed when used: tap a server to keep this chain off it. The exit side picks its
   server by Fastest or by Priority (drag ⋮⋮ to order; the first working one is used).
   "Check route" is informational only (it does not change the chain or Auto): it tells
   the user whether the chain can work and which entry -> exit pairs are fastest. */

const newChainDraft = (inId, outId) => ({ inId, outId, inOff: [], outOff: [], exitMode: 'fastest', exitOrder: [] });
let chainDraft = newChainDraft(null, null);
const ccOpen = new Set();   // expanded units in the editor, 'in:<id>' / 'out:<id>'
let chainTest = null;   // { running, stage, done, total, pairs: [{entry, exit, ms}], showAll }
let editingChainId = null;
let chainMode = 'simple';   // the Nodes tab the chain lives on: its ends are sources or profiles

function openCreateChain(editId, mode) {
  editingChainId = editId || null;
  chainMode = (editId && modeOf(editId)) || mode || connectMode;
  const ids = unitIdsOf(chainMode);
  if (!editingChainId && ids.length < 2) { toast(chainMode === 'simple' ? 'A chain needs two subscriptions or server groups — add one in Nodes' : 'A chain needs two profiles — create another profile first'); return; }
  if (editingChainId) {
    const c = chainsData[editingChainId];
    document.getElementById('ccTitle').textContent = 'Edit chain';
    document.getElementById('ccSaveBtn').textContent = 'Save changes';
    document.getElementById('ccDeleteBtn').style.display = '';
    document.getElementById('cc-name').value = c.name;
    chainDraft = Object.assign(newChainDraft(c.inId, c.outId), { inOff: [...(c.inOff || [])], outOff: [...(c.outOff || [])],
      exitMode: c.exitMode || 'fastest', exitOrder: [...(c.exitOrder || [])] });
    document.getElementById('cc-inauto').classList.toggle('on', c.inAuto);
  } else {
    document.getElementById('ccTitle').textContent = 'Create chain';
    document.getElementById('ccSaveBtn').textContent = 'Create chain';
    document.getElementById('ccDeleteBtn').style.display = 'none';
    document.getElementById('cc-name').value = '';
    chainDraft = newChainDraft(ids[0], ids[1]);
    document.getElementById('cc-inauto').classList.add('on');
  }
  chainTest = null;
  ccOpen.clear();
  renderChainEditor();
  openSheet('createchain');
}

function openEditChain(id) { openCreateChain(id); }

function renderChainEditor() {
  renderChainPicker('cc-in-list', 'in');
  renderChainPicker('cc-out-list', 'out');
  renderChainTest();
}

const CHEVRON = '<svg class="src-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg>';

function renderChainPicker(elId, side) {
  const el = document.getElementById(elId);
  const d = chainDraft;
  const current = side === 'in' ? d.inId : d.outId;
  const other = side === 'in' ? d.outId : d.inId;
  const off = side === 'in' ? d.inOff : d.outOff;
  const priority = side === 'out' && d.exitMode === 'priority';
  const ids = unitIdsOf(chainMode);
  if (current && !ids.includes(current) && (sourcesData[current] || profilesData[current])) ids.push(current);   // an end switched off in Nodes
  el.innerHTML = ids.map(id => {
    const taken = id === other;
    const open = ccOpen.has(side + ':' + id);
    const active = id === current;
    const all = unitRefs(id);
    const nOn = active ? all.filter(r => !off.includes(refKey(r))).length : all.length;
    const n = active ? (side === 'in' ? chainEntryNode(d) : chainExitNode(d)) : unitNode(id);
    const broken = isBroken(id);
    const sub = broken ? '<span class="off-meta">off in Nodes</span>' : taken ? (side === 'in' ? 'used as exit' : 'used as entry')
      : (n ? n.flag + ' ' : '') + (nOn < all.length ? `${nOn} of ${all.length}` : all.length) + ' nodes';
    let rank = 0;
    const list = active && priority ? chainExitOrder(d) : sortedNodes(all, r => r.node);
    const nodes = open ? list.map(r => {
      const { sid, node } = r, key = refKey(r);
      const lat = `<span onclick="event.stopPropagation();pingNodes([sourcesData['${sid}'].nodes.find(x=>x.id==='${node.id}')])" title="Tap to ping">${latHtml(node)}</span>`;
      if (!active) return `<div class="node-row static"><span class="node-flag">${node.flag}</span><span class="node-name">${esc(node.name)}</span><span class="node-proto">${node.protocol}</span>${lat}</div>`;
      const isOn = !off.includes(key);
      const grip = priority ? `<div class="drag-handle cc-grip" onclick="event.stopPropagation()" onpointerdown="startExitDrag(event,'${key}')">${GRIP_SVG}</div>` : '';
      const num = priority && isOn ? `<span class="cc-rank">${++rank}</span>` : priority ? '<span class="cc-rank"></span>' : '';
      return `<div class="node-row ps-node pick ${isOn ? 'on' : ''}" data-id="${key}" onclick="toggleChainNode('${side}','${key}')">
        ${grip}${num}
        <span class="node-flag">${node.flag}</span>
        <span class="node-name">${esc(node.name)}</span>
        <span class="node-proto">${node.protocol}</span>${lat}
      </div>`;
    }).join('') + (active ? goneBlockHtml(`cc:${side}:${id}`, unitGoneRefs(id),
      r => !off.includes(refKey(r))) : '') : '';
    return `<div class="cc-prof ${open ? 'open' : ''} ${taken ? 'disabled' : ''} ${broken ? 'off' : ''}" data-id="${id}">
      <div class="pick-row" ${taken ? '' : `onclick="pickChainSide('${side}','${id}')"`}>
        <div class="profile-radio ${active ? 'active' : ''}"></div>
        <span class="pick-row-name">${esc(unitName(id))}</span>
        <span class="pick-row-sub">${sub}</span>
      </div>
      ${all.length > 1 ? `<button class="icon-btn ghost cc-expand" onclick="toggleCcOpen('${side}','${id}')" title="Show nodes">${CHEVRON}</button>` : '<span class="cc-expand"></span>'}
      ${open ? `<div class="cc-nodes">${active && all.length ? `<div class="se-bar cc-bar"><span class="se-count">${nOn} of ${all.length} selected</span><div class="chip" onclick="setChainNodesAll('${side}')">${nOn === all.length ? 'None' : 'All'}</div></div>` : ''}${nodes || '<div class="route-empty">No enabled nodes</div>'}</div>` : ''}
    </div>`;
  }).join('');
  renderChainWarn();
  if (side === 'out') {
    const hint = document.getElementById('cc-out-hint');
    if (hint) hint.innerHTML = `<div class="seg-row">${pickModeSwitch('cc:' + (editingChainId || 'new'), priority, 'setChainExitMode')}`
      + `${pingAllBtn('testLatency(chainExitRefs(chainDraft).map(r => [r.sid, r.node.id]))', 'Test latency of the exit servers')}</div>`
      + (priority ? 'The first working server from the top is used. Expand the exit, drag ⋮⋮ to order, tap a server to skip it.'
                  : 'The fastest selected server of the exit is used. Expand and tap servers to leave them out.');
  }
}

// Each end needs at least one ticked server, and nothing it stands on switched off in Nodes.
function chainProblems(d = chainDraft) {
  return [['entry', chainEntryRefs(d), chainEntryRefs(d, true), d.inId], ['exit', chainExitRefs(d), chainExitRefs(d, true), d.outId]].map(([name, refs, all, uid]) =>
    refs.length ? '' : offReasons(all).length ? `The ${name}: ${reasonsText(offReasons(all))} — switch it on there or select another server`
    : unitRefs(uid).length ? `Select at least 1 server of the ${name}` : '').filter(Boolean);
}
function renderChainWarn() {
  const problems = chainProblems();
  const w = document.getElementById('cc-warn');
  w.hidden = !problems.length;
  w.textContent = problems.join('. ');
  document.getElementById('ccSaveBtn').disabled = problems.length > 0;
}

function toggleCcOpen(side, id) {
  const k = side + ':' + id;
  if (ccOpen.has(k)) ccOpen.delete(k); else ccOpen.add(k);
  renderChainPicker(side === 'in' ? 'cc-in-list' : 'cc-out-list', side);
}

function toggleChainNode(side, key) {
  const k = side === 'in' ? 'inOff' : 'outOff';
  chainDraft[k] = chainDraft[k].includes(key) ? chainDraft[k].filter(x => x !== key) : chainDraft[k].concat(key);
  chainTest = null;
  renderChainEditor();
}

function setChainNodesAll(side) {
  const k = side === 'in' ? 'inOff' : 'outOff';
  const keys = unitRefs(side === 'in' ? chainDraft.inId : chainDraft.outId).map(refKey);
  const kept = chainDraft[k].filter(x => !keys.includes(x));   // dropped servers keep their tick
  chainDraft[k] = chainDraft[k].some(x => keys.includes(x)) ? kept : kept.concat(keys);
  chainTest = null;
  renderChainEditor();
}

function setChainExitMode(mode) {
  chainDraft.exitMode = mode;
  if (mode === 'priority') ccOpen.add('out:' + chainDraft.outId);
  renderChainEditor();
}

// Full order = saved order (dropped servers keep their places) + servers not ordered yet.
function startExitDrag(e, key) {
  const shown = chainExitOrder(chainDraft).map(refKey);
  const full = chainDraft.exitOrder.concat(shown.filter(k => !chainDraft.exitOrder.includes(k)));
  const [order, done] = dragShown(full, shown, o => { chainDraft.exitOrder = o; });
  const rowEl = document.querySelector(`#cc-out-list .cc-nodes .node-row[data-id="${key}"]`);
  startRowDrag(e, rowEl, '.node-row', order, () => { done(); renderChainEditor(); });
}

function pickChainSide(side, id) {
  if (side === 'in') { if (chainDraft.inId !== id) chainDraft.inOff = []; chainDraft.inId = id; }
  else { if (chainDraft.outId !== id) Object.assign(chainDraft, { outOff: [], exitOrder: [] }); chainDraft.outId = id; }
  chainTest = null;   // ends changed: the old check no longer applies (a running one stops)
  renderChainEditor();
}

sourceViewHooks.push(() => {
  if (!document.getElementById('sh-createchain').classList.contains('open')) return;
  renderChainPicker('cc-in-list', 'in');
  renderChainPicker('cc-out-list', 'out');
});

const ROUTE_TOP = 4;   // working pairs shown before "show all"

function renderChainTest() {
  const el = document.getElementById('cc-test');
  if (!el) return;
  const t = chainTest;
  const nEntry = chainEntryRefs(chainDraft).length;
  const nExit = chainExitRefs(chainDraft).length;
  const btn = t && t.running
    ? `<button class="btn-secondary" onclick="stopChainRoute()">Stop</button>`
    : `<button class="btn-secondary" onclick="testChainRoute()" ${nEntry && nExit ? '' : 'disabled'}>${ICON.bolt}${t ? 'Check again' : 'Check route'}</button>`;
  let sum;
  if (!nEntry || !nExit) sum = `<div class="route-sum warn">${!nEntry ? 'Entry' : 'Exit'} has no selected working nodes.</div>`;
  else if (!t) sum = `<div class="route-sum">Tries every exit node through the entry nodes, fastest entries first.</div>`;
  else if (t.running) sum = `<div class="route-sum">${t.stage}<div class="route-progress"><div style="width:${t.total ? t.done / t.total * 100 : 0}%"></div></div></div>`;
  else if (t.pairs.length) sum = `<div class="route-sum good">${t.pairs.length} working pair${t.pairs.length === 1 ? '' : 's'}${t.stopped ? ' (stopped early)' : ''} · best ${t.pairs[0].ms} ms</div>`;
  else sum = `<div class="route-sum bad">${t.stopped ? 'Stopped — no working pair found yet.' : 'No exit node answers through any entry node — this chain will not connect.'}</div>`;

  let list = '';
  if (t && t.pairs.length) {
    const views = [['pairs', 'Pairs'], ['entry', 'By entry'], ['exit', 'By exit']];
    const chips = `<div class="chip-row route-views">${views.map(([k, l]) =>
      `<div class="chip ${t.view === k ? 'active' : ''}" onclick="chainTest.view='${k}';chainTest.showAll=false;renderChainTest()">${l}</div>`).join('')}</div>`;
    const end = n => `<span class="route-end"><span class="node-flag">${n.flag}</span><span class="node-name">${esc(n.name)}</span></span>`;
    const many = (k, word) => `<span class="route-end route-count">${k} ${word}</span>`;
    const arrow = '<span class="conn-arrow">→</span>';
    let rows;
    if (t.view === 'pairs') {
      rows = t.pairs.map(({ entry, exit, ms }) => `<div class="route-pair">${end(entry)}${arrow}${end(exit)}${latMsHtml(ms)}</div>`);
    } else {
      // Group by one end; each group shows its best total and expands to its pairs.
      const byEntry = t.view === 'entry';
      const groups = new Map();
      t.pairs.forEach(pr => {
        const n = byEntry ? pr.entry : pr.exit, k = serverKey(n);
        if (!groups.has(k)) groups.set(k, { key: k, node: n, pairs: [] });
        groups.get(k).pairs.push(pr);
      });
      rows = [...groups.values()].sort((a, b) => a.pairs[0].ms - b.pairs[0].ms).map(g => {
        const open = t.open.has(g.key);
        const cnt = many(g.pairs.length, g.pairs.length === 1 ? 'node' : 'nodes');
        const head = `<div class="route-pair route-group ${open ? 'open' : ''}" onclick="toggleRouteGroup('${g.key}')">
          ${byEntry ? end(g.node) + arrow + cnt : cnt + arrow + end(g.node)}
          <span class="route-min">min</span>${latMsHtml(g.pairs[0].ms)}
          <svg class="src-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg>
        </div>`;
        const sub = open ? `<div class="route-sub">${g.pairs.map(({ entry, exit, ms }) =>
          `<div class="route-pair">${byEntry ? arrow + end(exit) : end(entry) + arrow}${latMsHtml(ms)}</div>`).join('')}</div>` : '';
        return head + sub;
      });
    }
    const shown = t.showAll ? rows : rows.slice(0, ROUTE_TOP);
    list = `${chips}<div class="route-list">${shown.join('')}
      ${rows.length > ROUTE_TOP ? `<div class="route-more" onclick="chainTest.showAll=!chainTest.showAll;renderChainTest()">${t.showAll ? 'Show top ' + ROUTE_TOP : 'Show all ' + rows.length}
        <svg class="src-chevron" style="${t.showAll ? 'transform:rotate(180deg)' : ''}" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg></div>` : ''}
    </div>`;
  }
  el.innerHTML = `<div class="route-box">${sum}${btn}</div>${list}`;
}

/* Route check:
   1. Entry nodes: use cached pings if all are younger than 5 min, otherwise ping them all.
   2. Take alive entries fastest first; for each, ping every exit through it (exits in
      parallel, entries one after another) and collect the working pairs.
   3. If cached entry pings were used and the first 2 entries gave no working pair, the
      cache is probably stale: re-ping the entries once and start over.
   A server never pairs with itself (both profiles may share a subscription).
   Results: working pairs sorted by total latency. */
async function testChainRoute() {
  const entries = chainEntryRefs(chainDraft).map(r => r.node);
  const exits = chainExitRefs(chainDraft).map(r => r.node);
  const t = chainTest = { running: true, stage: '', done: 0, total: 0, pairs: [], showAll: false, view: chainTest ? chainTest.view : 'pairs', open: new Set() };
  const live = () => chainTest === t && !t.stopped;
  const step = stage => { t.stage = stage; renderChainTest(); };

  let fromCache = entries.every(n => pingAge(n) < PING_FRESH_MS);
  if (!fromCache) { step(`Pinging ${entries.length} entry nodes…`); await pingNodes(entries); }

  for (let attempt = 0; attempt < 2 && live(); attempt++) {
    const alive = entries.filter(isAlive).sort((a, b) => ping(a) - ping(b));
    t.pairs = []; t.done = 0; t.total = alive.length;
    let retry = false;
    for (let i = 0; i < alive.length && live(); i++) {
      const entry = alive[i];
      step(`Entry ${i + 1} of ${alive.length}: ${entry.flag} ${esc(entry.name)} → ${exits.length} exits`);
      const res = await Promise.all(exits.filter(exit => serverKey(exit) !== serverKey(entry)).map(exit => pingPair(entry, exit).then(ms => ({ entry, exit, ms }))));
      if (!live()) return;
      t.pairs.push(...res.filter(r => r.ms >= 0));
      t.pairs.sort((a, b) => a.ms - b.ms);
      t.done = i + 1;
      if (fromCache && i === 1 && !t.pairs.length) { retry = true; break; }
    }
    if (!retry) break;
    step('No pair through the first entries — re-pinging entry nodes…');
    fromCache = false;
    await pingNodes(entries);
  }
  if (chainTest !== t) return;
  t.running = false;
  renderChainTest();
}

function toggleRouteGroup(key) {
  if (chainTest.open.has(key)) chainTest.open.delete(key); else chainTest.open.add(key);
  renderChainTest();
}

function stopChainRoute() {
  if (!chainTest) return;
  chainTest.stopped = true;
  chainTest.running = false;
  renderChainTest();
}

function saveCreateChain() {
  if (chainProblems().length) return;
  if (chainDraft.inId === chainDraft.outId) { toast('Entry and exit must be different'); return; }
  const name = document.getElementById('cc-name').value.trim() || ('Chain ' + (++chainSeq));
  const { inId, outId, inOff, outOff, exitMode, exitOrder } = chainDraft;
  const fields = { inId, outId, inOff, outOff, exitMode, exitOrder,
                   inAuto: document.getElementById('cc-inauto').classList.contains('on') };
  if (editingChainId) {
    Object.assign(chainsData[editingChainId], { name }, fields);
  } else {
    const id = 'chain' + Date.now();
    chainsData[id] = Object.assign({ id, name }, fields);
    catalogOrder[chainMode].push(id);
  }
  editingChainId = null;
  chainTest = null;
  renderAll();
  closeSheet('createchain');
}

function deleteEditingChain() {
  if (!editingChainId) return;
  delete chainsData[editingChainId];   // syncCatalog drops it from the catalog and the routes
  editingChainId = null;
  renderAll();
  closeSheet('createchain');
}
