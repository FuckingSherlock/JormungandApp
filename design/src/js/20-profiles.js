/* ══════════════════════ RENDER: UNIFIED PROFILES + CHAINS LIST ══════════════════════
   Profiles and chains are peers in the SAME list: one shared drag-priority order
   (connectOrder) and one shared "active" radio, so auto-selection can span both
   types instead of being scoped to just profiles or just chains. */

function renderProfileRow(id, i) {
  const p = profilesData[id];
  const isOpen = !!expandState[id];
  const manualRow = !p.autoSelect ? `<div class="sub-item" style="padding-left:18px" onclick="event.stopPropagation();openPickManualNode('${id}')">
      <div style="flex:1">
        <div style="font-size:12px;color:var(--t3);text-transform:uppercase;letter-spacing:.5px;margin-bottom:2px">Manual node</div>
        <div style="font-size:14px;color:var(--t1);font-weight:600">${manualNodeLabel(p)}</div>
      </div>
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="var(--t3)" stroke-width="2" stroke-linecap="round"><polyline points="9 18 15 12 9 6"/></svg>
    </div><div class="sheet-divider" style="margin:4px 18px"></div>` : '';
  const subsHtml = manualRow + sourceOrder.map(sid => {
    const s = sourcesData[sid];
    const icon = subIcon(s.kind);
    const checked = p.sources.includes(sid);
    return `<div class="sub-item">
      <div class="sub-checkbox ${checked ? 'checked' : ''}" onclick="event.stopPropagation();toggleProfileSource('${id}','${sid}')"></div>
      <div class="sub-icon ${icon.cls}" onclick="event.stopPropagation();toggleProfileSource('${id}','${sid}')"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="${icon.color}" stroke-width="2.5" stroke-linecap="round">${icon.svg}</svg></div>
      <span class="sub-name" onclick="event.stopPropagation();toggleProfileSource('${id}','${sid}')">${s.name}</span>
      <span class="sub-count">${s.count} nodes</span>
    </div>`;
  }).join('') + `<div class="sub-item" style="padding-left:46px;padding-top:4px;padding-bottom:4px" onclick="event.stopPropagation();openSheet('addmenu')">
      <div style="font-size:13px;color:var(--accent);cursor:pointer">+ Add subscription or server</div>
    </div>`;

  return `<div class="profile-item" data-id="${id}">
    <div class="drag-handle" onpointerdown="startConnectDrag(event,'${id}')" title="Drag to reorder">
      <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>
    </div>
    <div class="profile-item-body">
      <div class="profile-item-head" onclick="selectConnect('${id}')">
        <div class="profile-radio ${id===activeConnectId?'active':''}"></div>
        <span class="profile-item-name">${p.name}</span>
        ${!p.autoSelect ? '<span style="font-size:11px;color:var(--warn);font-weight:700">MANUAL</span>' : ''}
        <span class="profile-item-count">${profileNodeCount(p)} nodes</span>
        <div class="profile-expand-btn" onclick="event.stopPropagation();openEditProfile('${id}')" title="Edit">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="var(--t2)" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>
        </div>
        <div title="Auto-select best node">${miniToggleHtml(id, 'toggleProfileAuto', p.autoSelect)}</div>
        <div class="profile-expand-btn ${isOpen?'open':''}" onclick="event.stopPropagation();toggleExpand('${id}')">
          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="var(--t2)" stroke-width="2.5" stroke-linecap="round"><polyline points="9 18 15 12 9 6"/></svg>
        </div>
      </div>
      <div class="profile-subs ${isOpen?'open':''}" id="subs-${id}">${subsHtml}</div>
    </div>
  </div>` + (i < connectOrder.length-1 ? '<div class="sheet-divider"></div>' : '');
}

function renderChainRow(id, i) {
  const c = chainsData[id];
  const isOpen = !!expandState[id];
  const inName = profilesData[c.inId] ? profilesData[c.inId].name : '—';
  const outName = profilesData[c.outId] ? profilesData[c.outId].name : '—';
  return `<div class="profile-item" data-id="${id}">
    <div class="drag-handle" onpointerdown="startConnectDrag(event,'${id}')" title="Drag to reorder">
      <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><circle cx="8" cy="6" r="1.6"/><circle cx="16" cy="6" r="1.6"/><circle cx="8" cy="12" r="1.6"/><circle cx="16" cy="12" r="1.6"/><circle cx="8" cy="18" r="1.6"/><circle cx="16" cy="18" r="1.6"/></svg>
    </div>
    <div class="profile-item-body">
      <div class="profile-item-head" onclick="selectConnect('${id}')">
        <div class="profile-radio ${id===activeConnectId?'active':''}"></div>
        <span class="profile-item-name ${!c.enabled?'dimmed':''}">${c.name}</span>
        <span style="font-size:11px;color:var(--accent);font-weight:700;background:rgba(var(--accent-rgb),.15);padding:1px 5px;border-radius:4px">CHAIN</span>
        <div class="profile-expand-btn" onclick="event.stopPropagation();openEditChain('${id}')" title="Edit">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="var(--t2)" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z"/></svg>
        </div>
        <div title="Eligible for auto-select">${miniToggleHtml(id, 'toggleChainEnabled', c.enabled)}</div>
        <div class="profile-expand-btn ${isOpen?'open':''}" onclick="event.stopPropagation();toggleExpand('${id}')">
          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="var(--t2)" stroke-width="2.5" stroke-linecap="round"><polyline points="9 18 15 12 9 6"/></svg>
        </div>
      </div>
      <div class="profile-subs ${isOpen?'open':''}">
        <div class="chain-inout">
          <span style="font-size:12px;color:var(--t3);font-weight:600;text-transform:uppercase;letter-spacing:.5px">IN</span>
          <span class="chain-badge in" onclick="event.stopPropagation();cycleChainSide('${id}','in')">${inName}</span>
          <span style="color:var(--t3);font-size:14px">→</span>
          <span style="font-size:12px;color:var(--t3);font-weight:600;text-transform:uppercase;letter-spacing:.5px">OUT</span>
          <span class="chain-badge out" onclick="event.stopPropagation();cycleChainSide('${id}','out')">${outName}</span>
        </div>
        <div class="sub-item" style="padding-left:46px;padding-top:6px;padding-bottom:4px">
          <div style="font-size:13px;color:var(--t2)">Tap badges to cycle profiles</div>
        </div>
      </div>
    </div>
  </div>` + (i < connectOrder.length-1 ? '<div class="sheet-divider"></div>' : '');
}

function renderConnects() {
  const el = document.getElementById('connects-list');
  el.innerHTML = connectOrder.map((id, i) => isChain(id) ? renderChainRow(id, i) : renderProfileRow(id, i)).join('');
}

function toggleExpand(id) {
  expandState[id] = !expandState[id];
  renderConnects();
}

function toggleProfileSource(pid, sid) {
  const p = profilesData[pid];
  const idx = p.sources.indexOf(sid);
  if (idx === -1) p.sources.push(sid); else p.sources.splice(idx, 1);
  expandState[pid] = true;
  renderConnects();
  if (pid === activeConnectId) updateMainConnectCard();
}

function selectConnect(id) {
  activeConnectId = id;
  updateMainConnectCard();
  renderConnects();
  closeSheet('profiles');
}

function toggleProfileAuto(id) {
  const p = profilesData[id];
  p.autoSelect = !p.autoSelect;
  if (!p.autoSelect && !p.manualNodeId) {
    const nodes = getProfileNodes(p);
    p.manualNodeId = nodes.length ? nodes[0].id : null;
  }
  renderConnects();
  if (id === activeConnectId) updateMainConnectCard();
}

let pickManualProfileId = null;
function openPickManualNode(pid) {
  pickManualProfileId = pid;
  const p = profilesData[pid];
  const nodes = getProfileNodes(p);
  const el = document.getElementById('pickmanualnode-list');
  el.innerHTML = nodes.length ? nodes.map(n => `<div class="pick-row" onclick="chooseManualNode('${n.id}')">
      <div class="profile-radio ${p.manualNodeId===n.id?'active':''}"></div>
      <span class="pick-row-name">${n.label}</span>
    </div>`).join('') : `<div class="form-group"><div style="font-size:14px;color:var(--t2)">No enabled subscriptions or servers in this profile yet.</div></div>`;
  openSheet('pickmanualnode');
}
function chooseManualNode(nodeId) {
  if (!pickManualProfileId) return;
  profilesData[pickManualProfileId].manualNodeId = nodeId;
  renderConnects();
  if (pickManualProfileId === activeConnectId) updateMainConnectCard();
  closeSheet('pickmanualnode');
}

function toggleChainEnabled(id) {
  chainsData[id].enabled = !chainsData[id].enabled;
  renderConnects();
}

function toggleRuleEnabled(id) {
  rulesData[id].enabled = !rulesData[id].enabled;
  renderRules();
}

function updateMainConnectCard() {
  const badge = document.getElementById('profModeBadge');
  const detail = document.getElementById('profModeDetail');

  if (isChain(activeConnectId)) {
    const c = chainsData[activeConnectId];
    const inName = profilesData[c.inId] ? profilesData[c.inId].name : '—';
    const outName = profilesData[c.outId] ? profilesData[c.outId].name : '—';
    document.getElementById('profCardName').textContent = c.name;
    document.getElementById('profMetaCount').textContent = '';
    document.getElementById('profMetaSrc').textContent = 'chain';
    badge.textContent = 'CHAIN';
    badge.style.color = 'var(--accent)';
    badge.style.background = 'rgba(var(--accent-rgb),.15)';
    detail.textContent = inName + ' → ' + outName;
    return;
  }

  const p = profilesData[activeConnectId];
  document.getElementById('profCardName').textContent = p.name;
  document.getElementById('profMetaCount').textContent = profileNodeCount(p);
  document.getElementById('profMetaSrc').textContent = 'nodes · ' + p.sources.length + ' src';
  if (p.autoSelect) {
    badge.textContent = 'AUTO';
    badge.style.color = 'var(--active)';
    badge.style.background = 'rgba(var(--active-rgb),.15)';
    detail.textContent = 'best latency · 38ms';
  } else {
    badge.textContent = 'MANUAL';
    badge.style.color = 'var(--warn)';
    badge.style.background = 'rgba(var(--warn-rgb),.15)';
    detail.textContent = manualNodeLabel(p);
  }
}

function cycleChainSide(chainId, side) {
  const c = chainsData[chainId];
  const key = side === 'in' ? 'inId' : 'outId';
  const ids = getProfileIds();
  const idx = ids.indexOf(c[key]);
  c[key] = ids[(idx + 1) % ids.length];
  renderConnects();
  if (chainId === activeConnectId) updateMainConnectCard();
}

