/* ══════════════════════ SOURCE ENTRY (simple mode ⋯ on a source row) ══════════════════════
   The simple-mode counterpart of the profile editor: which of the source's servers this
   entry may use (tick / untick, all / none), Auto participation, ping and update.
   Changes apply at once. Unticked servers are s.offNodes; new ones after an update are on. */

let seId = null;

function openSourceEntry(sid) {
  seId = sid;
  renderSourceEntry();
  openSheet('sourceentry');
}

function renderSourceEntry() {
  const s = sourcesData[seId];
  if (!s) return;
  const on = s.nodes.length - offCount(s);
  document.getElementById('seTitle').textContent = s.name;
  document.getElementById('se-inauto').classList.toggle('on', s.inAuto);
  document.getElementById('se-count').textContent = `${on} of ${s.nodes.length} on` + (s.enabled ? '' : ' · source disabled in Nodes');
  const upd = document.getElementById('se-update');
  upd.style.display = s.kind === 'sub' ? '' : 'none';
  upd.innerHTML = `<span class="${s.updating ? 'spin' : ''}" style="display:inline-flex">${ICON.refresh}</span>`;
  upd.nextElementSibling.innerHTML = ICON.bolt;
  document.getElementById('se-all').textContent = on === s.nodes.length ? 'None' : 'All';
  document.getElementById('se-nodes').innerHTML = sortedNodes(s.nodes).map(n => {
    const off = isNodeOff(s, n.id);
    return `<div class="node-row ps-node ${off ? '' : 'on'}" onclick="toggleSourceEntryNode('${n.id}')">
      <div class="sub-checkbox ${off ? '' : 'checked'}"></div>
      <span class="node-flag">${n.flag}</span>
      <span class="node-name">${esc(n.name)}</span>
      <span class="node-proto">${n.protocol}</span>
      <span onclick="event.stopPropagation();testLatency([['${seId}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
    </div>`;
  }).join('') || '<div class="route-empty">No servers yet</div>';
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
  s.offNodes = offCount(s) ? [] : s.nodes.map(n => n.id);
  sourceEntryChanged();
}

function toggleSourceEntryAuto() {
  sourcesData[seId].inAuto = !sourcesData[seId].inAuto;
  sourceEntryChanged();
}

sourceViewHooks.push(() => {
  if (document.getElementById('sh-sourceentry').classList.contains('open')) renderSourceEntry();
});
