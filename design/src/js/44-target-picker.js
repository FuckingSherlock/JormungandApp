/* ══════════════════════ TARGET PICKER (rules, apps) ══════════════════════
   One sheet above everything that lists what traffic can go through: Main flow, then the
   whole Nodes catalog whatever the route's mode — subscriptions / server groups (tap the
   card = all its servers, ⌄ opens its servers to pick one), profiles, chains. Cards carry
   the same details as in Nodes: what it is made of, traffic / expiry, the server it would
   use now with its ping. Off / empty ones stay pickable, marked unavailable (the rule then
   follows its "If unavailable"). */

let tpCurrent = '', tpApply = null;
const tpOpen = new Set();

function openTargetPicker(t, apply) {
  tpCurrent = t || '';
  tpApply = apply;
  tpOpen.clear();
  if (tpCurrent.startsWith('node:')) tpOpen.add(tpCurrent.slice(5).split('::')[0]);
  document.getElementById('tp-search').value = '';
  renderTargetPicker();
  openSheet('target');
}

function pickTarget(t) {
  closeSheet('target');
  if (tpApply) tpApply(t);
}

function tpToggle(sid) {
  if (tpOpen.has(sid)) tpOpen.delete(sid); else tpOpen.add(sid);
  renderTargetPicker();
}

const TP_CHECK = '<svg class="tp-check" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>';

function tpCardHtml(t, name, meta, below, extra = '', body = '') {
  const i = targetInfo(t), picked = t === tpCurrent;
  return `<div class="src-card tp-card ${picked ? 'picked' : ''} ${i.ok ? '' : 'down'}" data-t="${t}">
    <div class="src-head" onclick="pickTarget('${t}')">
      <div class="src-main">
        <div class="src-name">${name}${i.ok ? '' : '<span class="conn-tag off">off</span>'}</div>
        <div class="src-meta">${meta}</div>
      </div>
      ${picked ? TP_CHECK : ''}${extra}
    </div>
    ${below}${body}
  </div>`;
}

function renderTargetPicker() {
  const q = document.getElementById('tp-search').value.trim().toLowerCase();
  const hit = s => !q || s.toLowerCase().includes(q);
  const label = (text, n) => n ? `<div class="tp-label">${text}</div>` : '';

  const cur = effectiveConnectId(), ce = connectEntry(cur);
  const main = hit('main flow') ? tpCardHtml('', 'Main flow', '<span>What Home connects through · follows Route</span>',
    `<div class="entry-now"><span class="conn-tag muted">now</span><span class="conn-node">${ce ? esc(ce.name) : '—'}</span></div>`) : '';

  const srcs = sourceOrder.map(sid => {
    const s = sourcesData[sid];
    const nodes = s.nodes.filter(n => hit(n.name + ' ' + n.protocol));
    if (!hit(s.name) && !nodes.length) return '';
    const open = tpOpen.has(sid) || (q && !hit(s.name));
    const rows = open ? (hit(s.name) ? s.nodes : nodes).map(n => {
      const t = 'node:' + sid + '::' + n.id, off = isNodeDisabled(s, n.id);
      return `<div class="node-row tap ${t === tpCurrent ? 'picked' : ''} ${off ? 'disabled' : ''}" onclick="pickTarget('${t}')">
        <span class="node-name"><span class="node-flag">${n.flag}</span>${esc(n.name)}</span><span class="node-proto">${protoLabel(n)}</span>${latHtml(n)}${t === tpCurrent ? TP_CHECK : ''}</div>`;
    }).join('') : '';
    const chevron = `<button class="icon-btn ghost" onclick="event.stopPropagation();tpToggle('${sid}')" title="Pick one server">
      <svg class="src-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" style="${open ? 'transform:rotate(180deg)' : ''}"><polyline points="6 9 12 15 18 9"/></svg></button>`;
    const best = bestAlive(liveNodes(s));
    return tpCardHtml('src:' + sid, esc(s.name), srcMetaHtml(s),
      usageHtml(s) + `<div class="entry-now"><span class="conn-tag muted">fastest</span>${nodeSummaryHtml(best, false)}</div>`,
      chevron, open ? `<div class="src-body tp-nodes">${rows}</div>` : '');
  }).join('');

  const profs = getProfileIds().filter(id => hit(profilesData[id].name))
    .map(id => tpCardHtml('profile:' + id, esc(profilesData[id].name), entryMetaHtml(id), entryNowHtml(id))).join('');
  const chains = catalogOrder.simple.concat(catalogOrder.profiles).filter(id => chainsData[id] && hit(chainsData[id].name))
    .map(id => tpCardHtml('chain:' + id, esc(chainsData[id].name), entryMetaHtml(id), entryNowHtml(id))).join('');

  document.getElementById('tp-body').innerHTML = main
    + label('Subscriptions & servers', srcs) + srcs
    + label('Profiles', profs) + profs
    + label('Chains', chains) + chains
    || `<div class="nodes-empty">Nothing matches “${esc(q)}”.</div>`;
}
