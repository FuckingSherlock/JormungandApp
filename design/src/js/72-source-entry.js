/* ══════════════════════ SOURCE ENTRY (simple mode ⋯ on a source row) ══════════════════════
   The simple-mode counterpart of the profile editor: which of the source's servers this
   entry may use (tick / untick, all / none), Auto participation, ping and update.
   Changes apply at once. Unticked servers are s.offNodes; new ones after an update are on.
   Servers switched off in Nodes (s.disabledNodes) are not listed; their ticks are kept.
   At least one server must stay ticked: with none, a warning shows and closing the sheet
   puts the selection back to what it was when opened.
   Fastest / Priority (s.pickMode, s.pickOrder): which selected server it connects through. */

let seId = null;
let seSnapshot = null;

function openSourceEntry(sid) {
  seId = sid;
  seSnapshot = (sourcesData[sid].offNodes || []).slice();
  renderSourceEntry();
  openSheet('sourceentry');
}

function renderSourceEntry() {
  const s = sourcesData[seId];
  if (!s) return;
  const live = liveNodes(s), on = live.length - offCount(s), hidden = s.nodes.length - live.length;
  document.getElementById('seTitle').textContent = s.name;
  document.getElementById('se-inauto').classList.toggle('on', s.inAuto);
  document.getElementById('se-count').innerHTML = `${on} of ${live.length} on` + (hidden ? ` <span class="dis-meta">· ${hidden} off in Nodes</span>` : '');
  const none = !on && live.length > 0;
  document.getElementById('se-warn').hidden = !none;
  document.getElementById('se-done').disabled = none;
  const upd = document.getElementById('se-update');
  upd.style.display = s.kind === 'sub' ? '' : 'none';
  upd.innerHTML = `<span class="${s.updating ? 'spin' : ''}" style="display:inline-flex">${ICON.refresh}</span>`;
  upd.nextElementSibling.innerHTML = ICON.bolt;
  document.getElementById('se-all').textContent = on === live.length ? 'None' : 'All';
  const priority = s.pickMode === 'priority';
  document.getElementById('se-mode').innerHTML = pickModeSwitch('se:' + seId, priority, 'setSourceEntryMode');
  document.getElementById('se-hint').textContent = pickModeHint(priority);
  let rank = 0;
  const list = priority ? seOrderRefs().map(r => r.node) : byPing(live);
  document.getElementById('se-nodes').innerHTML = list.map(n => {
    const off = isNodeOff(s, n.id);
    return `<div class="node-row ps-node pick ${off ? '' : 'on'}" data-id="${seId}::${n.id}" onclick="toggleSourceEntryNode('${n.id}')">
      ${priority ? `<div class="drag-handle cc-grip" onclick="event.stopPropagation()" onpointerdown="startSourceEntryDrag(event,'${seId}::${n.id}')">${GRIP_SVG}</div><span class="cc-rank">${off ? '' : ++rank}</span>` : ''}
      <span class="node-flag">${n.flag}</span>
      <span class="node-name">${esc(n.name)}</span>
      <span class="node-proto">${protoLabel(n)}</span>
      <span class="lat-hit" onclick="event.stopPropagation();testLatency([['${seId}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
    </div>`;
  }).join('') || '<div class="route-empty">No servers yet</div>';
  document.getElementById('se-nodes').insertAdjacentHTML('beforeend', goneBlockHtml('se:' + seId, goneRefs(seId),
    r => !isNodeOff(s, r.node.id)));
}

// PickModeSwitch — the Fastest / Priority switch of the source entry, profile and chain exit
// editors. Like the Simple / Profiles switch in Route: tap or swipe it, the pill slides across.
// `key` names the thing being edited, so a re-render after a change slides from the old side.
const pickSwitchWas = {};
function pickModeSwitch(key, priority, fn) {
  const to = priority ? 'priority' : 'fastest', from = pickSwitchWas[key] || to;
  pickSwitchWas[key] = to;
  if (from !== to) requestAnimationFrame(() => requestAnimationFrame(() =>
    document.querySelectorAll(`.seg-switch[data-key="${key}"]`).forEach(el => { el.dataset.mode = to; })));
  return `<div class="seg-switch" data-key="${key}" data-mode="${from}" onpointerdown="segSwipeStart(event,'${fn}')">`
    + `<span class="seg-ink"></span><button data-m="fastest" onclick="${fn}('fastest')">Fastest</button>`
    + `<button data-m="priority" onclick="${fn}('priority')">Priority</button></div>`;
}
// A horizontal swipe over the switch flips it (and swallows the click it would end with).
function segSwipeStart(e, fn) {
  const x0 = e.clientX;
  const up = ev => {
    window.removeEventListener('pointerup', up);
    const dx = ev.clientX - x0;
    if (Math.abs(dx) < 24) return;
    const stop = c => { c.stopPropagation(); c.preventDefault(); };
    window.addEventListener('click', stop, { capture: true, once: true });
    setTimeout(() => window.removeEventListener('click', stop, true), 0);
    window[fn](dx > 0 ? 'priority' : 'fastest');
  };
  window.addEventListener('pointerup', up);
}
const pingAllBtn = (onclick, title) => `<button class="icon-btn ghost seg-ping" onclick="${onclick}" title="${title}">${ICON.bolt}</button>`;
const pickModeHint = priority => priority
  ? 'Framed servers are used, the first working one from the top. Drag ⋮⋮ to order, tap a server to leave it out.'
  : 'Framed servers are used — tap to leave one out. It connects through the fastest of them; servers added by an update start selected.';

function setSourceEntryMode(mode) {
  sourcesData[seId].pickMode = mode;
  sourceEntryChanged();
}

// Every listed server in priority order, left-out ones included (like a chain's exit).
const seOrderRefs = () => orderRefs(liveNodes(sourcesData[seId]).map(node => ({ sid: seId, node })), sourcesData[seId].pickOrder);
// Servers off in Nodes or dropped by the provider keep their slots.
function startSourceEntryDrag(e, key) {
  const s = sourcesData[seId];
  const shown = seOrderRefs().map(refKey), cur = s.pickOrder || [];
  const full = cur.concat(shown.filter(k => !cur.includes(k)));
  const [order, done] = dragShown(full, shown, o => { s.pickOrder = o; });
  const rowEl = document.querySelector(`#se-nodes .node-row[data-id="${key}"]`);
  startRowDrag(e, rowEl, '.node-row', order, () => { done(); sourceEntryChanged(); });
}

function sourceEntryChanged() {
  renderSourceEntry();
  renderConnects();
  updateMainConnectCard();
}

function toggleSourceEntryNode(nid) {
  const s = sourcesData[seId];
  s.offNodes = isNodeOff(s, nid) ? s.offNodes.filter(x => x !== nid) : (s.offNodes || []).concat(nid);
  sourceEntryChanged();
}

function setSourceEntryAll() {
  const s = sourcesData[seId];
  const ids = liveNodes(s).map(n => n.id), kept = (s.offNodes || []).filter(id => !ids.includes(id));   // dropped / disabled servers keep theirs
  s.offNodes = offCount(s) ? kept : kept.concat(ids);
  sourceEntryChanged();
}

function toggleSourceEntryAuto() {
  sourcesData[seId].inAuto = !sourcesData[seId].inAuto;
  sourceEntryChanged();
}

sheetCloseHooks.sourceentry = () => {
  const s = sourcesData[seId];
  if (s && liveNodes(s).length && !(liveNodes(s).length - offCount(s))) {
    s.offNodes = seSnapshot;
    toast('At least 1 server is needed — previous selection kept');
    renderConnects();
    updateMainConnectCard();
  }
};

sourceViewHooks.push(() => {
  if (document.getElementById('sh-sourceentry').classList.contains('open')) renderSourceEntry();
});
