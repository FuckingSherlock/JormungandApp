/* ══════════════════════ TARGET PICKER (rules, apps) ══════════════════════
   One sheet above everything that lists what traffic can go through: Main flow, then the
   whole Nodes catalog whatever the route's mode — subscriptions / server groups, profiles,
   chains. Cards carry the same details as in Nodes: what it is made of, traffic / expiry,
   the server it would use now with its ping. A card with servers (subscription, profile)
   unfolds on a tap; AUTO in its header (as on Route) marks the whole item, the unfolded body
   shows how it picks (Fastest / Priority, the item's own setting, read-only) and its servers,
   a tap on one marks it. Main flow and chains are marked by a tap. A tap on the marked item
   unmarks it (→ main flow). Marks don't close the sheet: a Save bar slides in while the
   selection differs from the opening one; ×, swipe and Back apply nothing. Off / empty ones
   stay pickable, marked unavailable (the rule then follows its "If unavailable"). */

let tpCurrent = '', tpOrig = '', tpApply = null;   // tpCurrent = the selection so far, tpOrig = what the picker opened with
const tpOpen = new Set();   // unfolded cards, by target id ('src:<id>', 'profile:<id>')

function openTargetPicker(t, apply) {
  tpCurrent = tpOrig = t || '';
  tpApply = apply;
  tpOpen.clear();
  if (tpCurrent.startsWith('node:')) tpOpen.add('src:' + tpCurrent.slice(5).split('::')[0]);
  document.getElementById('tp-search').value = '';
  renderTargetPicker();
  openSheet('target');
}

/* A pick only marks the selection; the Save bar slides in while it differs from the opening
   target, Save applies and closes, closing any other way applies nothing. Tapping the
   selected item again deselects it: the target is then '' = the main flow. */
function pickTarget(t) {
  tpCurrent = t === tpCurrent ? '' : t;
  renderTargetPicker();
}
function saveTarget() {
  closeSheet('target');
  if (tpApply) tpApply(tpCurrent);
}

function tpToggle(t) {
  if (tpOpen.has(t)) tpOpen.delete(t); else tpOpen.add(t);
  renderTargetPicker();
}

const TP_CHECK = '<svg class="tp-check" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"/></svg>';
const TP_CHEVRON = open => `<svg class="src-chevron tp-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" style="${open ? 'transform:rotate(180deg)' : ''}"><polyline points="6 9 12 15 18 9"/></svg>`;

// opts.rows (a list of {sid, node}) makes the card unfoldable; opts.id = its source / profile id.
function tpCardHtml(t, name, meta, below, opts = {}) {
  const i = targetInfo(t), picked = t === tpCurrent, fold = opts.rows !== undefined, open = fold && opts.open;
  return `<div class="src-card tp-card ${picked ? 'picked' : ''} ${i.ok ? '' : 'down'} ${open ? 'open' : ''}" data-t="${t}">
    <div class="src-head" onclick="${fold ? `tpToggle('${t}')` : `pickTarget('${t}')`}">
      <div class="src-main">
        <div class="src-name">${fold ? `<button class="conn-state ${picked ? 'on' : ''}" onclick="event.stopPropagation();pickTarget('${t}')" title="Use the whole item as the target">auto</button>` : ''}${name}${i.ok ? '' : '<span class="conn-tag off">off</span>'}</div>
        <div class="src-meta">${meta}</div>
      </div>
      ${picked && !fold ? TP_CHECK : ''}${fold ? TP_CHEVRON(open) : ''}
    </div>
    ${below}${open ? tpBodyHtml(t, opts.id, opts.rows) : ''}
  </div>`;
}

// Route's routeRowBodyHtml, without grips / edit / ping taps: the mode is read-only, a server row picks.
function tpBodyHtml(t, id, refs) {
  const priority = unitPriority(id);
  let rank = 0;
  const rows = refs.map(r => {
    const nt = 'node:' + r.sid + '::' + r.node.id, off = isNodeDisabled(sourcesData[r.sid], r.node.id);
    return `<div class="node-row ps-node on ${nt === tpCurrent ? 'picked' : ''} ${off ? 'disabled' : ''}" data-t="${nt}" onclick="pickTarget('${nt}')">
      ${priority ? `<span class="cc-rank">${++rank}</span>` : ''}
      <span class="node-name"><span class="node-flag">${r.node.flag}</span>${esc(r.node.name)}</span>
      <span class="node-proto">${protoLabel(r.node)}</span>${latHtml(r.node)}${nt === tpCurrent ? TP_CHECK : ''}</div>`;
  }).join('');
  const hint = priority ? 'Priority: the first working one from the top.' : 'Fastest: the quickest working one.';
  return `<div class="conn-body"><div class="seg-row"><div class="set-hint conn-hint conn-pick-hint">${hint}</div></div>
    <div class="se-nodes">${rows || '<div class="route-empty">No servers</div>'}</div></div>`;
}

function renderTargetPicker() {
  const q = document.getElementById('tp-search').value.trim().toLowerCase();
  const hit = s => !q || s.toLowerCase().includes(q);
  const label = (text, n) => n ? `<div class="tp-label">${text}</div>` : '';
  const nodeHit = n => hit(n.name + ' ' + n.protocol);
  // Servers of an unfolded card: all, or (the search hit servers, not the card) the matching ones; as on Route.
  const listed = (id, refs, nameHit) => {
    const rs = nameHit ? refs : refs.filter(r => nodeHit(r.node));
    return unitPriority(id) ? orderRefs(rs, unitOwner(id).pickOrder) : byPing(rs, r => r.node);
  };

  const cur = effectiveConnectId(), ce = connectEntry(cur);
  const main = hit('main flow') ? tpCardHtml('', 'Main flow', '<span>What Home connects through · follows Route</span>',
    `<div class="entry-now"><span class="conn-tag muted">now</span><span class="conn-node">${ce ? esc(ce.name) : '—'}</span></div>`) : '';

  const srcs = sourceOrder.map(sid => {
    const s = sourcesData[sid], t = 'src:' + sid, refs = s.nodes.map(node => ({ sid, node }));
    if (!hit(s.name) && !refs.some(r => nodeHit(r.node))) return '';
    const best = bestAlive(liveNodes(s));
    return tpCardHtml(t, esc(s.name), srcMetaHtml(s),
      usageHtml(s) + `<div class="entry-now"><span class="conn-tag muted">${unitPriority(sid) ? 'priority' : 'fastest'}</span>${nodeSummaryHtml(best, false)}</div>`,
      { id: sid, open: tpOpen.has(t) || (!!q && !hit(s.name)), rows: listed(sid, refs, hit(s.name)) });
  }).join('');

  const profs = getProfileIds().map(id => {
    const p = profilesData[id], t = 'profile:' + id, refs = unitRefs(id, true);
    if (!hit(p.name) && !refs.some(r => nodeHit(r.node))) return '';
    return tpCardHtml(t, esc(p.name), entryMetaHtml(id), entryNowHtml(id),
      { id, open: tpOpen.has(t) || (!!q && !hit(p.name)), rows: listed(id, refs, hit(p.name)) });
  }).join('');
  const chains = catalogOrder.simple.concat(catalogOrder.profiles).filter(id => chainsData[id] && hit(chainsData[id].name))
    .map(id => tpCardHtml('chain:' + id, esc(chainsData[id].name), entryMetaHtml(id), entryNowHtml(id))).join('');

  document.getElementById('tp-body').innerHTML = main
    + label('Subscriptions & servers', srcs) + srcs
    + label('Profiles', profs) + profs
    + label('Chains', chains) + chains
    || `<div class="nodes-empty">Nothing matches “${esc(q)}”.</div>`;
  const dirty = tpCurrent !== tpOrig;
  const bar = document.getElementById('tp-save');
  bar.classList.toggle('show', dirty);
  bar.classList.toggle('reset', dirty && tpCurrent === '');
  document.getElementById('tp-body').classList.toggle('saving', dirty);
}
