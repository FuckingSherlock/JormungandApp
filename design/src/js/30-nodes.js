/* ══════════════════════ NODES SCREEN (subscriptions + manual servers) ══════════════════════
   Replaces the old "All configs" sheet. A source is either a subscription (kind 'sub')
   or a group of manual servers (kind 'node'); both render as one collapsible group. */

let nodeSort = 'order';   // 'order' | 'latency' | 'name'
// Edit mode: ⋮⋮ grips, source switches and framed servers (tap = on/off) appear only here,
// so the everyday view has nothing to knock by accident (tap a server = its menu).
let nodesEdit = false;
function setNodesEdit(on) {
  nodesEdit = on;
  document.getElementById('view-nodes').classList.toggle('editing', on);
  const b = document.getElementById('nodesEditBtn');
  b.classList.toggle('on', on);
  b.title = on ? 'Done' : 'Edit: reorder, switch sources and servers on / off';
  b.innerHTML = on ? ICON.check : ICON.edit;
  renderNodes();
}

const ICON = {
  refresh: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 11-2.12-9.36L23 10"/></svg>',
  check: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>',
  bolt:    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z"/></svg>',
  edit:    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>',
  copy:    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>',
  qr:      '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM20 14v.01M14 20h.01M17 20h4v-3"/></svg>',
  web:     '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z"/></svg>',
  trash:   '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg>',
  power:   '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18.36 6.64a9 9 0 11-12.73 0"/><line x1="12" y1="2" x2="12" y2="12"/></svg>',
  close:   '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="6" y1="6" x2="18" y2="18"/><line x1="18" y1="6" x2="6" y2="18"/></svg>',
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

function latMsHtml(v) {
  if (v === 'testing') return '<span class="lat testing">testing</span>';
  if (v == null) return '<span class="lat none">—</span>';
  // no answer: a red warning sign (an SVG: the ⚠️ emoji is yellow and ignores color)
  if (v < 0) return '<span class="lat bad dead" title="No answer (timeout)"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18.2A2 2 0 0 0 3.5 21h17a2 2 0 0 0 1.7-2.8L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg></span>';
  const cls = v < 150 ? 'good' : v < 400 ? 'mid' : 'bad';
  return `<span class="lat ${cls}">${v} ms</span>`;
}
const latHtml = n => latMsHtml(ping(n));

// The sort chosen on Nodes applies to every node list in the app. `nodeOf` lets it
// sort {sid, node} refs as well as bare nodes.
function sortedNodes(list, nodeOf = x => x) {
  list = list.slice();
  if (nodeSort === 'name') list.sort((a, b) => nodeOf(a).name.localeCompare(nodeOf(b).name));
  if (nodeSort === 'latency') list.sort((a, b) => pingRank(nodeOf(a)) - pingRank(nodeOf(b)));
  return list;
}

// Fastest lists (profile / chain / route entry in Fastest mode) always read by ping: quickest
// on top, dead ones last — the top row is the one that connects. While a ping runs, each
// answer moves its row at once: up by its ms, a timeout straight to the bottom; rows still
// waiting keep their place in between (pingRank).
function byPing(list, nodeOf = x => x) {
  return list.slice().sort((a, b) => pingRank(nodeOf(a)) - pingRank(nodeOf(b)));
}

/* ── Servers the provider dropped (s.gone) ──
   One collapsible "Unavailable · N" block, used by Nodes and by every node picker. The
   rows are read-only; `isOn(ref)` = the kept selection (framed like a picked row);
   `rowClick(ref)` (Nodes only) opens the server's own menu. `ctx` names the block
   so each view remembers its own open state.
   Each dropped server is kept GONE_KEEP_DAYS from its own goneAt, then forgotten with
   its settings (purgeExpiredGone: on start and after every update). The list lives in
   the source, so deleting the source deletes it too. */
const GONE_KEEP_DAYS = 15;
const goneLeftDays = n => Math.ceil((n.goneAt + GONE_KEEP_DAYS * 864e5 - Date.now()) / 864e5);
const goneOpen = new Set();
function goneBlockHtml(ctx, refs, isOn = null, action = '', rowClick = null) {
  if (!refs.length) return '';
  const open = goneOpen.has(ctx);
  const rows = open ? refs.map(r => `<div class="node-row gone ${isOn ? 'pick' : ''} ${isOn && isOn(r) ? 'on' : ''} ${rowClick ? 'tap' : ''}" ${rowClick ? `onclick="${rowClick(r)}"` : ''}>
      
      <span class="node-name"><span class="node-flag">${r.node.flag}</span>${esc(r.node.name)}</span>
      <span class="node-proto">${protoLabel(r.node)}</span>
      <span class="lat none gone-left ${goneLeftDays(r.node) <= 3 ? 'soon' : ''}" title="Removed ${timeAgo(r.node.goneAt)}">${goneLeftDays(r.node)} d left</span>
    </div>`).join('') : '';
  return `<div class="gone-block ${open ? 'open' : ''}">
    <div class="gone-head" onclick="event.stopPropagation();toggleGone('${ctx}')">
      <svg class="src-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg>
      <span class="gone-title">Unavailable · ${refs.length}</span>
      <span class="gone-hint">removed by the provider, settings kept</span>${action}
    </div>${rows}
  </div>`;
}
function toggleGone(ctx) {
  if (goneOpen.has(ctx)) goneOpen.delete(ctx); else goneOpen.add(ctx);
  refreshSourceViews();
}
const goneRefs = sid => (sourcesData[sid].gone || []).map(node => ({ sid, node }));

// Every setting that names these servers of a source, gone for good.
function purgeNodeSettings(sid, ids) {
  const s = sourcesData[sid], keys = new Set([...ids].map(nid => sid + '::' + nid));
  s.offNodes = (s.offNodes || []).filter(nid => !ids.has(nid));
  s.disabledNodes = (s.disabledNodes || []).filter(nid => !ids.has(nid));
  s.pickOrder = (s.pickOrder || []).filter(k => !keys.has(k));
  Object.values(profilesData).forEach(p => { p.nodes = p.nodes.filter(k => !keys.has(k)); p.pickOrder = (p.pickOrder || []).filter(k => !keys.has(k)); });
  Object.values(chainsData).forEach(c => ['inOff', 'outOff', 'exitOrder'].forEach(f => { if (c[f]) c[f] = c[f].filter(k => !keys.has(k)); }));
}
// Forget dropped servers (all of a source, or the given ids) with their settings.
function forgetGone(sid, only) {
  const s = sourcesData[sid];
  const ids = new Set((s.gone || []).map(n => n.id).filter(nid => !only || only.includes(nid)));
  s.gone = (s.gone || []).filter(n => !ids.has(n.id));
  purgeNodeSettings(sid, ids);
  toast(`Forgot ${ids.size} unavailable server${ids.size === 1 ? '' : 's'}`);
  refreshSourceViews();
}
function purgeExpiredGone() {
  sourceOrder.forEach(sid => {
    const s = sourcesData[sid], ids = new Set((s.gone || []).filter(n => goneLeftDays(n) <= 0).map(n => n.id));
    if (!ids.size) return;
    s.gone = s.gone.filter(n => !ids.has(n.id));
    purgeNodeSettings(sid, ids);
  });
}
function openGoneActions(sid, nid) {
  const n = sourcesData[sid].gone.find(x => x.id === nid), days = goneLeftDays(n);
  openActions(n.flag + '  ' + n.name,
    `<div class="menu-note">Removed by the provider ${timeAgo(n.goneAt)}. If a subscription update brings it back within <b>${days} day${days === 1 ? '' : 's'}</b>, its settings in profiles and chains come back with it; after that it is forgotten.</div>`
    + menuRow(ICON.trash, 'Forget now<div class="menu-sub">Drops it and its settings everywhere</div>', `closeSheet('actions');forgetGone('${sid}',['${nid}'])`, 'danger'));
}

// Kept short so the line rarely wraps: "sing-box · 16/18 nodes · 1d" (working / all, where
// not working = switched off or gone from the subscription); when it wraps, it breaks between items.
function srcMetaHtml(s) {
  const parts = [], live = liveNodes(s).length, off = s.nodes.length - live, gone = (s.gone || []).length;
  const total = s.nodes.length + gone, word = s.kind === 'sub' ? 'node' : 'server';
  const why = [off && off + ' off', gone && gone + ' gone from the subscription'].filter(Boolean).join(', ');
  parts.push(`<span class="fmt-tag">${s.kind === 'sub' ? s.format : 'manual'}</span>`);
  parts.push(live < total ? `<span class="${gone ? 'gone-meta' : 'dis-meta'}" title="${why}">${live}/${total} ${word}s</span>`
    : `${total} ${word}${total === 1 ? '' : 's'}`);
  if (s.kind === 'sub') parts.push(`<span title="Updated ${timeAgo(s.updatedAt)}">${shortAgo(s.updatedAt)}</span>`);
  return parts.map((p, i) => `<span class="meta-part">${p}${i < parts.length - 1 ? '<span class="dot">·</span>' : ''}</span>`).join('');
}
function shortAgo(ts) {
  const m = Math.round((Date.now() - ts) / 60000);
  if (m < 1) return 'now';
  if (m < 60) return m + 'm';
  const h = Math.round(m / 60);
  return h < 24 ? h + 'h' : Math.round(h / 24) + 'd';
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
  // View: tap a server = its menu, off ones dimmed. Edit: framed = in use, tap = on / off.
  const nodeRows = sortedNodes(nodes).map(n => { const on = !isNodeDisabled(s, n.id); return `<div class="node-row ${nodesEdit ? 'pick ' + (on ? 'on' : 'disabled') : on ? 'tap' : 'disabled tap'}" data-nid="${n.id}"
      onclick="${nodesEdit ? 'toggleNodeEnabled' : 'openNodeActions'}('${id}','${n.id}')" title="${nodesEdit ? 'Tap: on / off' : 'Tap: menu'}">
      
      <span class="node-name"><span class="node-flag">${n.flag}</span>${esc(n.name)}</span>
      <span class="node-proto">${protoLabel(n)}</span>
      <span class="lat-hit" onclick="event.stopPropagation();testLatency([['${id}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
    </div>`; }).join('');
  const addRow = s.kind === 'node'
    ? `<div class="node-add" onclick="openNodeForm('${id}')">${ICON.plus}Add server</div>` : '';

  const grip = !nodesEdit ? '' : q ? '<div class="drag-handle" style="visibility:hidden"></div>' : `<div class="drag-handle" onpointerdown="startSourceDrag(event,'${id}')" onclick="event.stopPropagation()" title="Drag to reorder">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>
      </div>`;
  const updateBtn = s.kind === 'sub' && !nodesEdit
    ? `<button class="icon-btn ghost" onclick="event.stopPropagation();updateSource('${id}')" title="Update"><span class="${s.updating ? 'spin' : ''}" style="display:inline-flex">${ICON.refresh}</span></button>` : '';

  return `<div class="src-card ${isOpen ? 'open' : ''} ${s.enabled ? '' : 'off'}" data-id="${id}">
    <div class="src-top">
    ${grip}
    <div class="src-top-main">
    <div class="src-head" onclick="toggleSourceOpen('${id}')">
      <div class="src-main">
        <div class="src-name">${esc(s.name)}${s.enabled || nodesEdit ? '' : '<span class="conn-tag off">off</span>'}<svg class="src-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg></div>
        <div class="src-meta wrap">${srcMetaHtml(s)}</div>
      </div>
      ${updateBtn}
      ${nodesEdit ? `<div title="Use this source">${miniToggleHtml(id, 'toggleSourceEnabled', s.enabled)}</div>`
        : `<button class="icon-btn ghost" onclick="event.stopPropagation();testSourceLatency('${id}')" title="Test latency">${ICON.bolt}</button>`}
      <button class="icon-btn ghost" onclick="event.stopPropagation();openSourceActions('${id}')" title="More">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="5" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="12" cy="19" r="1.8"/></svg>
      </button>
    </div>
    ${usageHtml(s)}${s.announce ? `<div class="src-announce" title="${esc(s.announce)}">${esc(s.announce)}</div>` : ''}
    </div>
    </div>
    <div class="src-body">${nodeRows}${addRow}${q ? '' : goneBlockHtml('nodes:' + id, goneRefs(id), null,
      `<div class="chip gone-forget" onclick="event.stopPropagation();forgetGone('${id}')">Forget all</div>`, r => `openGoneActions('${id}','${r.node.id}')`)}</div>
  </div>`;
}

// Both tabs render at once (the pager slides between them, see 31-catalog.js).
function renderNodes() {
  syncCatalog();
  const input = document.getElementById('nodeSearch');
  const q = input.value.trim().toLowerCase();
  const none = `<div class="nodes-empty">Nothing matches “${esc(q)}”.</div>`;
  const html = catalogOrder.simple.map(id => sourcesData[id] ? renderSourceCard(id, q) : renderEntryCard(id, q)).join('');
  document.getElementById('nodes-list').innerHTML = html ||
    (q ? none : `<div class="nodes-empty">No subscriptions or servers yet.<br>Tap <b>+</b> to add one.</div>`);
  document.getElementById('nodes-profiles').innerHTML = catalogOrder.profiles.map(id => renderEntryCard(id, q)).join('') ||
    (q ? none : `<div class="nodes-empty">No profiles yet.<br>Tap <b>+</b> to group servers into one.</div>`);
  renderNodesSummary();
  renderNodesTabs();
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
  catalogOrder[nodesTab].forEach(id => expandState[id] = open);
  renderNodes();
  closeSheet('nodesmore');
}

function toggleSourceEnabled(id) {
  sourcesData[id].enabled = !sourcesData[id].enabled;
  renderAll();
}
function toggleNodeEnabled(sid, nid) {
  const s = sourcesData[sid];
  s.disabledNodes = isNodeDisabled(s, nid) ? s.disabledNodes.filter(x => x !== nid) : (s.disabledNodes || []).concat(nid);
  refreshSourceViews();
}

// Other screens that show node latency / update state (the profile editor) register
// a re-render here, so ping and update results reach every open view.
const sourceViewHooks = [];
function refreshSourceViews() {
  renderNodes();
  renderConnects();
  updateMainConnectCard();
  sourceViewHooks.forEach(fn => fn());
}

function renderAll() {
  renderNodes();
  renderConnects();
  updateMainConnectCard();
}

/* ── Latency ── */

function testLatency(pairs) {
  return pingNodes(pairs.map(([sid, nid]) => sourcesData[sid] && sourcesData[sid].nodes.find(x => x.id === nid)).filter(Boolean));
}
function testSourceLatency(sid) {
  const s = sourcesData[sid];
  expandState[sid] = true;
  return testLatency(liveNodes(s).map(n => [sid, n.id]));
}
// Every source at once: servers taken in turn from each source (1st of each, 2nd of each…),
// so all sets fill in together instead of one after another (the core runs 32 in parallel).
function testAllLatency() {
  const lists = sourceOrder.filter(sid => sourcesData[sid].enabled).map(sid => liveNodes(sourcesData[sid]).map(n => [sid, n.id]));
  const pairs = [];
  for (let i = 0; lists.some(l => i < l.length); i++) lists.forEach(l => { if (i < l.length) pairs.push(l[i]); });
  testLatency(pairs);
  closeSheet('nodesmore');
}

/* ── Update subscriptions ── */

// opts.rediscover: ask the provider with every User-Agent again (⋮ → Update with all user
// agents). The backend sets s.updatedAt (the core's clock in live mode).
function updateSource(sid, opts) {
  const s = sourcesData[sid];
  if (s.kind !== 'sub' || s.updating) return;
  s.updating = true;
  refreshSourceViews();
  backend.updateSource(s, opts && typeof opts === 'object' ? opts : {}).then(() => {
    s.count = s.nodes.length;
    return true;
  }, e => { toast('Update of ' + s.name + ' failed: ' + e.message); return false; }).then(ok => {
    s.updating = false;
    purgeExpiredGone();
    refreshSourceViews();
    if (ok && s.testAfterUpdate) testSourceLatency(sid);
  });
}
// Mockup only: an update of a demo subscription alternates between the provider dropping
// two servers and bringing the dropped ones back (with their old settings).
function demoProviderChurn(s) {
  if ((s.gone || []).length) {
    const back = s.gone;
    s.nodes = s.nodes.concat(back.map(n => { const m = Object.assign({}, n); delete m.goneAt; return m; }))
      .sort((a, b) => +a.id.slice(1) - +b.id.slice(1));
    s.gone = [];
    back.forEach(n => { if (!pingCache.has(serverKey(n))) setPing(n, truthOf(n)); });
    toast(`${back.length} server${back.length === 1 ? ' is' : 's are'} back — previous settings restored`);
  } else {
    const drop = s.nodes.filter((n, i) => i === 1 || i === 3);
    s.nodes = s.nodes.filter(n => !drop.includes(n));
    s.gone = drop.map(n => Object.assign({}, n, { goneAt: Date.now() }));
    toast(`The provider removed ${drop.length} servers — see Unavailable, settings kept`);
  }
  s.count = s.nodes.length;
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
  const anyOpen = catalogOrder[nodesTab].some(id => expandState[id]);
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
  let rows = menuRow(ICON.edit, s.kind === 'sub' ? 'Edit subscription' : 'Rename group', close + `openSrcForm('${sid}')`)
    + menuRow(ICON.bolt, 'Route settings<div class="menu-sub">Servers it uses as a route entry, Fastest / Priority, in Auto</div>', close + `openSourceEntry('${sid}')`);
  if (s.kind === 'sub') {
    if ((s.userAgent || 'Auto') === 'Auto') rows += menuRow(ICON.refresh, 'Update with all user agents<div class="menu-sub">Asks as sing-box, mihomo and Clash again and merges what each gives</div>', close + `updateSource('${sid}',{rediscover:true})`);
    rows += menuRow(ICON.copy, 'Copy URL', close + `toast('Subscription URL copied')`);
    rows += menuRow(ICON.qr, 'Show QR code', close + `toast('QR code is not drawn in the mockup')`);
    // the user's own website first, else the page the provider sends (profile-web-page-url)
    const site = s.website || s.webPage;
    // links from the provider go into onclick as a JSON string, never raw
    const opens = u => close + `toast(${esc(JSON.stringify('Opens ' + u))})`;
    if (site) rows += menuRow(ICON.web, 'Open website', opens(site));
    if (s.supportUrl) rows += menuRow(ICON.web, 'Support', opens(s.supportUrl));
  }
  rows += menuRow(ICON.trash, 'Delete', close + `confirmDeleteSource('${sid}')`, 'danger');
  openActions(s.name, rows);
}

function openNodeActions(sid, nid) {
  const s = sourcesData[sid];
  const n = s.nodes.find(x => x.id === nid);
  const close = "closeSheet('actions');";
  const on = !isNodeDisabled(s, nid);
  let rows = menuRow(ICON.power, on ? 'Switch off<div class="menu-sub">Hidden everywhere, its settings kept</div>' : 'Switch on', close + `toggleNodeEnabled('${sid}','${nid}')`);
  rows += menuRow(ICON.copy, 'Copy share link', close + `toast('${n.protocol}:// link copied')`);
  rows += menuRow(ICON.qr, 'Show QR code', close + `toast('QR code is not drawn in the mockup')`);
  if (s.kind === 'node') {
    rows += menuRow(ICON.edit, 'Edit server', close + `openNodeForm('${sid}','${nid}')`);
    rows += menuRow(ICON.trash, 'Delete', close + `confirmDeleteNode('${sid}','${nid}')`, 'danger');
  }
  openActions(n.flag + '  ' + n.name, rows);
}

/* ── Delete ──
   Always asks first. The confirmation lists what the deletion does to everything that
   uses the source / server, found by previewing the lists without it (simExclude):
   chains ending on a deleted source are deleted; an entry, profile or chain end left
   with no server won't connect; others lose servers (a priority exit drops them from
   its order). Settings naming the deleted servers are removed for good. */

function deleteImpact(excl, sid) {
  const lines = [];
  const both = f => { simExclude = null; const a = f(); simExclude = excl; const b = f(); simExclude = null; return [a, b]; };
  const srv = k => k + ' server' + (k === 1 ? '' : 's');
  // The connection right now.
  const id0 = effectiveConnectId(), c0 = chainsData[id0];
  const using = (c0 ? [chainEntryRefs(c0).find(r => r.node === chainEntryNode(c0)), chainExitRefs(c0).find(r => r.node === chainExitNode(c0))]
    : [unitRefs(id0).find(r => r.node === unitNode(id0))]).filter(Boolean);
  if (using.some(excl)) lines.push(['Current connection', '', 'goes through it — will reconnect through the next working server', 'warn']);
  ['simple', 'profiles'].forEach(mode => catalogOrder[mode].forEach(id => {
    const e = connectEntry(id);
    if (!e || id === sid) return;
    if (chainsData[id]) {
      const c = chainsData[id];
      if (sid && (c.inId === sid || c.outId === sid)) { lines.push([e.name, 'chain', 'is deleted with it', 'bad']); return; }
      const [ei, eo] = both(() => chainEntryRefs(c).length), [xi, xo] = both(() => chainExitRefs(c).length);
      if ((ei && !eo) || (xi && !xo)) lines.push([e.name, 'chain', `its ${ei && !eo ? 'entry' : 'exit'} is left with no servers — won't connect until you select another`, 'bad']);
      else if (eo < ei || xo < xi) lines.push([e.name, 'chain', [eo < ei ? `entry loses ${srv(ei - eo)}` : '',
        xo < xi ? `exit loses ${srv(xi - xo)}${c.exitMode === 'priority' ? ' (out of its priority order)' : ''}` : ''].filter(Boolean).join(', '), 'warn']);
      return;
    }
    const [a, b] = both(() => unitRefs(id).length), kind = profilesData[id] ? 'profile' : 'entry';
    if (a && !b) lines.push([e.name, kind, "is left with no servers — won't connect until you select another", 'bad']);
    else if (b < a && profilesData[id]) lines.push([e.name, kind, `loses ${srv(a - b)} of ${a}`, 'warn']);
  }));
  return lines;
}

function confirmDeleteHtml(note, lines, doIt, label) {
  const close = "closeSheet('actions');";
  const list = lines.length ? `<div class="menu-caption">This will affect</div><div class="impact-list">${lines.map(([name, kind, what, cls]) =>
    `<div class="impact-row ${cls}"><div class="impact-name">${esc(name)}${kind ? `<span class="conn-tag">${kind}</span>` : ''}</div><div class="impact-what">${what}</div></div>`).join('')}</div>`
    : '<div class="menu-note">Not used in any profile, chain, rule or app.</div>';
  return `<div class="menu-note">${note}</div>${list}`
    + menuRow(ICON.trash, label, close + doIt, 'danger')
    + menuRow(ICON.close, 'Cancel', close);
}

function confirmDeleteSource(sid) {
  const s = sourcesData[sid];
  if (!s) return;
  const n = s.nodes.length, g = (s.gone || []).length;
  const note = (s.kind === 'sub' ? `The subscription and its ${n} server${n === 1 ? '' : 's'}` : `The group and its ${n} server${n === 1 ? '' : 's'}`)
    + ' are removed' + (g ? `, with ${g} unavailable one${g === 1 ? '' : 's'} kept for their settings` : '') + '. This can’t be undone.';
  const dead = new Set(Object.values(chainsData).filter(c => c.inId === sid || c.outId === sid).map(c => 'chain:' + c.id));
  const impact = deleteImpact(r => r.sid === sid, sid).concat(targetImpact(t => t === 'src:' + sid || t.startsWith('node:' + sid + '::') || dead.has(t)));
  openActions('Delete ' + s.name + '?', confirmDeleteHtml(note, impact, `deleteSource('${sid}')`, 'Delete ' + (s.kind === 'sub' ? 'subscription' : 'group')));
}

function confirmDeleteNode(sid, nid) {
  const s = sourcesData[sid], n = s && s.nodes.find(x => x.id === nid);
  if (!n) return;
  openActions('Delete ' + n.name + '?', confirmDeleteHtml(`${n.flag} ${esc(n.name)} is removed from ${esc(s.name)}, with its place in every profile and chain. This can’t be undone.`,
    deleteImpact(r => r.sid === sid && r.node.id === nid).concat(targetImpact(t => t === 'node:' + sid + '::' + nid)), `deleteNode('${sid}','${nid}')`, 'Delete server'));
}

function deleteSource(id) {
  if (!id || !sourcesData[id]) return;
  sourceOrder = sourceOrder.filter(x => x !== id);
  delete sourcesData[id];
  Object.values(profilesData).forEach(p => {
    p.sources = p.sources.filter(x => x !== id);
    p.nodes = p.nodes.filter(k => !k.startsWith(id + '::'));
    p.pickOrder = (p.pickOrder || []).filter(k => !k.startsWith(id + '::'));
  });
  Object.values(chainsData).forEach(c => ['inOff', 'outOff', 'exitOrder'].forEach(f => { if (c[f]) c[f] = c[f].filter(k => !k.startsWith(id + '::')); }));
  dropConnectEntry(id);
  renderAll();
}

function deleteNode(sid, nid) {
  const s = sourcesData[sid];
  if (!s) return;
  s.nodes = s.nodes.filter(n => n.id !== nid);
  s.count = s.nodes.length;
  purgeNodeSettings(sid, new Set([nid]));
  renderAll();
}
