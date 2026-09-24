/* ══════════════════════ NODES SCREEN (subscriptions + manual servers) ══════════════════════
   Replaces the old "All configs" sheet. A source is either a subscription (kind 'sub')
   or a group of manual servers (kind 'node'); both render as one collapsible group. */

let nodeSort = 'order';   // 'order' | 'latency' | 'name'

const ICON = {
  refresh: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 11-2.12-9.36L23 10"/></svg>',
  bolt:    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>',
  edit:    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>',
  copy:    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>',
  qr:      '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM20 14v.01M14 20h.01M17 20h4v-3"/></svg>',
  web:     '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/></svg>',
  trash:   '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg>',
  plus:    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>',
  collapse:'<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="17 11 12 6 7 11"/><polyline points="17 18 12 13 7 18"/></svg>',
  expand:  '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="7 13 12 18 17 13"/><polyline points="7 6 12 11 17 6"/></svg>',
};

function esc(str) {
  return String(str).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function timeAgo(ts) {
  const m = Math.round((Date.now() - ts) / 60000);
  if (m < 1) return 'just now';
  if (m < 60) return m + ' min ago';
  const h = Math.round(m / 60);
  if (h < 24) return h + ' h ago';
  return Math.round(h / 24) + ' d ago';
}

function fmtDate(iso) {
  const [y, mo, d] = iso.split('-');
  return d + '.' + mo + '.' + y;
}

function latHtml(n) {
  if (n.latency === 'testing') return '<span class="lat testing">testing</span>';
  if (n.latency == null) return '<span class="lat none">—</span>';
  if (n.latency < 0) return '<span class="lat bad">timeout</span>';
  const cls = n.latency < 150 ? 'good' : n.latency < 400 ? 'mid' : 'bad';
  return `<span class="lat ${cls}">${n.latency} ms</span>`;
}

function sortedNodes(nodes) {
  const list = nodes.slice();
  if (nodeSort === 'name') list.sort((a, b) => a.name.localeCompare(b.name));
  if (nodeSort === 'latency') {
    const key = n => (typeof n.latency === 'number' && n.latency >= 0) ? n.latency : 1e9;
    list.sort((a, b) => key(a) - key(b));
  }
  return list;
}

function srcMetaHtml(s) {
  const parts = [];
  if (s.kind === 'sub') {
    parts.push(`<span class="fmt-tag">${s.format}</span>`);
    parts.push(`${s.nodes.length} nodes`);
    parts.push(timeAgo(s.updatedAt));
  } else {
    parts.push(`<span class="fmt-tag">manual</span>`);
    parts.push(`${s.nodes.length} server${s.nodes.length === 1 ? '' : 's'}`);
  }
  return parts.join('<span class="dot">·</span>');
}

function usageHtml(s) {
  if (s.kind !== 'sub') return '';
  const u = s.usage || { used:0, total:0 };
  const left = u.total ? `${u.used} / ${u.total} GB` : `${u.used} GB · unlimited`;
  const right = s.expire ? `until ${fmtDate(s.expire)}` : 'no expiry';
  const pct = u.total ? Math.min(100, u.used / u.total * 100) : 0;
  const bar = u.total ? `<div class="usage-bar"><div class="usage-fill ${pct > 80 ? 'hi' : ''}" style="width:${pct}%"></div></div>` : '';
  return `<div class="src-usage">${bar}<div class="usage-text" style="${u.total ? '' : 'margin-top:0'}"><span>${left}</span><span>${right}</span></div></div>`;
}

function renderSourceCard(id, q) {
  const s = sourcesData[id];
  let nodes = s.nodes;
  if (q) {
    nodes = nodes.filter(n => (n.name + ' ' + n.protocol).toLowerCase().includes(q));
    if (!nodes.length && !s.name.toLowerCase().includes(q)) return '';
    if (s.name.toLowerCase().includes(q) && !nodes.length) nodes = s.nodes;
  }
  const isOpen = q ? true : !!expandState[id];
  const nodeRows = sortedNodes(nodes).map(n => `<div class="node-row" onclick="openNodeActions('${id}','${n.id}')">
      <span class="node-flag">${n.flag}</span>
      <span class="node-name">${esc(n.name)}</span>
      <span class="node-proto">${n.protocol}</span>
      <span onclick="event.stopPropagation();testLatency([['${id}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
    </div>`).join('');
  const addRow = s.kind === 'node'
    ? `<div class="node-add" onclick="openNodeForm('${id}')">${ICON.plus}Add server</div>` : '';

  const grip = q ? '<div class="drag-handle" style="visibility:hidden"></div>' : `<div class="drag-handle" onpointerdown="startSourceDrag(event,'${id}')" onclick="event.stopPropagation()" title="Drag to reorder">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>
      </div>`;
  const updateBtn = s.kind === 'sub'
    ? `<button class="icon-btn ghost" onclick="event.stopPropagation();updateSource('${id}')" title="Update"><span class="${s.updating ? 'spin' : ''}" style="display:inline-flex">${ICON.refresh}</span></button>` : '';

  return `<div class="src-card ${isOpen ? 'open' : ''} ${s.enabled ? '' : 'off'}" data-id="${id}">
    <div class="src-top">
    ${grip}
    <div class="src-top-main">
    <div class="src-head" onclick="toggleSourceOpen('${id}')">
      <div class="src-main">
        <div class="src-name">${esc(s.name)}<svg class="src-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg></div>
        <div class="src-meta">${srcMetaHtml(s)}</div>
      </div>
      ${updateBtn}
      <button class="icon-btn ghost" onclick="event.stopPropagation();testSourceLatency('${id}')" title="Test latency">${ICON.bolt}</button>
      <div title="Use this source">${miniToggleHtml(id, 'toggleSourceEnabled', s.enabled)}</div>
      <button class="icon-btn ghost" onclick="event.stopPropagation();openSourceActions('${id}')" title="More">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg>
      </button>
    </div>
    ${usageHtml(s)}
    </div>
    </div>
    <div class="src-body">${nodeRows}${addRow}</div>
  </div>`;
}

function renderNodes() {
  const input = document.getElementById('nodeSearch');
  const q = input.value.trim().toLowerCase();
  const html = sourceOrder.map(id => renderSourceCard(id, q)).join('');
  document.getElementById('nodes-list').innerHTML = html ||
    (q ? `<div class="nodes-empty">Nothing matches “${esc(q)}”.</div>`
       : `<div class="nodes-empty">No subscriptions or servers yet.<br>Tap <b>+</b> to add one.</div>`);

  const total = sourceOrder.reduce((sum, id) => sum + sourcesData[id].nodes.length, 0);
  const summary = sourceOrder.length + ' source' + (sourceOrder.length === 1 ? '' : 's') + ' · ' + total + ' nodes';
  document.getElementById('nodesSummary').textContent = summary;
  document.getElementById('configsCardSub').textContent = summary;
}

function toggleNodeSearch(force) {
  const bar = document.getElementById('nodeSearchBar');
  const input = document.getElementById('nodeSearch');
  const open = force !== undefined ? force : bar.style.display === 'none';
  bar.style.display = open ? '' : 'none';
  document.getElementById('nodeSearchBtn').classList.toggle('on', open);
  if (open) {
    input.focus();
  } else if (input.value) {
    input.value = '';
    renderNodes();
  }
}

function toggleSourceOpen(id) {
  expandState[id] = !expandState[id];
  renderNodes();
}

function setAllOpen(open) {
  sourceOrder.forEach(id => expandState[id] = open);
  renderNodes();
  closeSheet('nodesmore');
}

function toggleSourceEnabled(id) {
  sourcesData[id].enabled = !sourcesData[id].enabled;
  renderAll();
}

function renderAll() {
  renderNodes();
  renderConnects();
  updateMainConnectCard();
}

/* ── Latency ── */

function testLatency(pairs) {
  pairs.forEach(([sid, nid]) => {
    const n = sourcesData[sid] && sourcesData[sid].nodes.find(x => x.id === nid);
    if (n) n.latency = 'testing';
  });
  renderNodes();
  pairs.forEach(([sid, nid]) => {
    setTimeout(() => {
      const n = sourcesData[sid] && sourcesData[sid].nodes.find(x => x.id === nid);
      if (!n) return;
      n.latency = randLatency();
      renderNodes();
      updateMainConnectCard();
    }, 300 + Math.random() * 1400);
  });
}
function testSourceLatency(sid) {
  const s = sourcesData[sid];
  expandState[sid] = true;
  testLatency(s.nodes.map(n => [sid, n.id]));
}
function testAllLatency() {
  const pairs = [];
  sourceOrder.forEach(sid => {
    if (sourcesData[sid].enabled) sourcesData[sid].nodes.forEach(n => pairs.push([sid, n.id]));
  });
  testLatency(pairs);
  closeSheet('nodesmore');
}

/* ── Update subscriptions ── */

function updateSource(sid) {
  const s = sourcesData[sid];
  if (s.kind !== 'sub' || s.updating) return;
  s.updating = true;
  renderNodes();
  setTimeout(() => {
    s.updating = false;
    s.updatedAt = Date.now();
    renderNodes();
    if (s.testAfterUpdate) testSourceLatency(sid);
  }, 900 + Math.random() * 600);
}
function updateAllSources() {
  sourceOrder.forEach(sid => { if (sourcesData[sid].enabled) updateSource(sid); });
  closeSheet('nodesmore');
}

/* ── Menus ── */

function menuRow(icon, label, onclick, extraCls) {
  return `<div class="menu-row ${extraCls || ''}" onclick="${onclick}">${icon}<div class="menu-label">${label}</div></div>`;
}

function openNodesMore() {
  const sortChip = (key, label) => `<div class="chip ${nodeSort === key ? 'active' : ''}" onclick="setNodeSort('${key}')">${label}</div>`;
  const anyOpen = sourceOrder.some(id => expandState[id]);
  document.getElementById('nodesmore-body').innerHTML =
    menuRow(ICON.refresh, 'Update all subscriptions', 'updateAllSources()') +
    (anyOpen ? menuRow(ICON.collapse, 'Collapse all', 'setAllOpen(false)')
             : menuRow(ICON.expand, 'Expand all', 'setAllOpen(true)')) +
    `<div class="menu-caption">Sort nodes</div>
     <div class="chip-row" style="padding:0 20px 6px">${sortChip('order','As in source')}${sortChip('latency','By latency')}${sortChip('name','By name')}</div>`;
  openSheet('nodesmore');
}

function setNodeSort(key) {
  nodeSort = key;
  renderNodes();
  openNodesMore();
}

function openActions(title, rowsHtml) {
  document.getElementById('actionsTitle').textContent = title;
  document.getElementById('actions-body').innerHTML = rowsHtml;
  openSheet('actions');
}

function openSourceActions(sid) {
  const s = sourcesData[sid];
  const close = "closeSheet('actions');";
  let rows = menuRow(ICON.edit, s.kind === 'sub' ? 'Edit subscription' : 'Rename group', close + `openSrcForm('${sid}')`);
  if (s.kind === 'sub') {
    rows += menuRow(ICON.copy, 'Copy URL', close + `toast('Subscription URL copied')`);
    rows += menuRow(ICON.qr, 'Show QR code', close + `toast('QR code is not drawn in the mockup')`);
    if (s.website) rows += menuRow(ICON.web, 'Open website', close + `toast('Opens ${esc(s.website)}')`);
  }
  rows += menuRow(ICON.trash, 'Delete', close + `deleteSource('${sid}')`, 'danger');
  openActions(s.name, rows);
}

function openNodeActions(sid, nid) {
  const s = sourcesData[sid];
  const n = s.nodes.find(x => x.id === nid);
  const close = "closeSheet('actions');";
  let rows = menuRow(ICON.copy, 'Copy share link', close + `toast('${n.protocol}:// link copied')`);
  rows += menuRow(ICON.qr, 'Show QR code', close + `toast('QR code is not drawn in the mockup')`);
  if (s.kind === 'node') {
    rows += menuRow(ICON.edit, 'Edit server', close + `openNodeForm('${sid}','${nid}')`);
    rows += menuRow(ICON.trash, 'Delete', close + `deleteNode('${sid}','${nid}')`, 'danger');
  }
  openActions(n.flag + '  ' + n.name, rows);
}

/* ── Delete ── */

function deleteSource(id) {
  if (!id || !sourcesData[id]) return;
  sourceOrder = sourceOrder.filter(x => x !== id);
  delete sourcesData[id];
  Object.values(profilesData).forEach(p => {
    p.sources = p.sources.filter(x => x !== id);
    if (p.manualNodeId && p.manualNodeId.startsWith(id + '::')) p.manualNodeId = null;
  });
  renderAll();
}

function deleteNode(sid, nid) {
  const s = sourcesData[sid];
  if (!s) return;
  s.nodes = s.nodes.filter(n => n.id !== nid);
  s.count = s.nodes.length;
  Object.values(profilesData).forEach(p => { if (p.manualNodeId === sid + '::' + nid) p.manualNodeId = null; });
  renderAll();
}

