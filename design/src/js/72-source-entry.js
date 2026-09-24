/* ══════════════════════ SOURCE ENTRY (simple mode ⋯ on a source row) ══════════════════════
   The simple-mode counterpart of the profile editor: which of the source's servers this
   entry may use (tick / untick, all / none), Auto participation, ping and update.
   Changes apply at once. Unticked servers are s.offNodes; new ones after an update are on.
   Servers switched off in Nodes (s.disabledNodes) are not listed; their ticks are kept.
   At least one server must stay ticked: with none, a warning shows and closing the sheet
   puts the selection back to what it was when opened. */

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
  document.getElementById('se-nodes').innerHTML = sortedNodes(live).map(n => {
    const off = isNodeOff(s, n.id);
    return `<div class="node-row ps-node pick ${off ? '' : 'on'}" onclick="toggleSourceEntryNode('${n.id}')">
      <span class="node-flag">${n.flag}</span>
      <span class="node-name">${esc(n.name)}</span>
      <span class="node-proto">${n.protocol}</span>
      <span onclick="event.stopPropagation();testLatency([['${seId}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
    </div>`;
  }).join('') || '<div class="route-empty">No servers yet</div>';
  document.getElementById('se-nodes').insertAdjacentHTML('beforeend', goneBlockHtml('se:' + seId, goneRefs(seId),
    r => !isNodeOff(s, r.node.id)));
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
