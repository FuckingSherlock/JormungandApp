/* ══════════════════════ CREATE / EDIT PROFILE ══════════════════════ */

let createProfileSelected = new Set();
let editingProfileId = null;
let cpDraft = { autoSelect: true, manualNodeId: null };

function setCpMode(auto) {
  cpDraft.autoSelect = auto;
  renderCpNode();
  renderCreateProfileSources();
}
function renderCpNode() {
  document.querySelectorAll('#cp-mode .chip').forEach((c, i) => c.classList.toggle('active', i === (cpDraft.autoSelect ? 0 : 1)));
  document.getElementById('cp-fixed-row').style.display = cpDraft.autoSelect ? 'none' : '';
  const ref = profileNodeRefs({ sources: [...createProfileSelected] }).find(r => r.sid + '::' + r.node.id === cpDraft.manualNodeId);
  document.getElementById('cp-fixed-label').textContent = ref ? ref.node.flag + ' ' + ref.node.name : 'Choose…';
}
function pickCpNode() {
  openPickNode({ sources: [...createProfileSelected], current: cpDraft.manualNodeId,
    onPick: key => { cpDraft.manualNodeId = key; renderCpNode(); renderCreateProfileSources(); } });
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
    cpDraft = { autoSelect: p.autoSelect, manualNodeId: p.manualNodeId };
    document.getElementById('cp-inauto').classList.toggle('on', p.inAuto);
  } else {
    document.getElementById('cpTitle').textContent = 'Create profile';
    document.getElementById('cpSaveBtn').textContent = 'Create profile';
    document.getElementById('cpDeleteBtn').style.display = 'none';
    document.getElementById('cp-name').value = '';
    createProfileSelected = new Set();
    cpDraft = { autoSelect: true, manualNodeId: null };
    document.getElementById('cp-inauto').classList.add('on');
  }
  cpOpen.clear();
  renderCreateProfileSources();
  renderCpNode();
  openSheet('createprofile');
}

function openEditProfile(id) { openCreateProfile(id); }

// Each source is a collapsible card: tick = use it in the profile; tap the name to see
// its nodes; update / ping act on the whole source. In "Fixed node" mode, tapping a
// node of a ticked source makes it the fixed node.
const cpOpen = new Set();

function renderCreateProfileSources() {
  const el = document.getElementById('cp-source-list');
  el.innerHTML = sourceOrder.map(id => {
    const s = sourcesData[id];
    const checked = createProfileSelected.has(id);
    const open = cpOpen.has(id);
    const alive = s.nodes.filter(isAlive).length;
    const meta = [s.kind === 'sub' ? 'subscription' : 'manual', `${s.nodes.length} nodes`, `${alive} alive`]
      .concat(s.enabled ? [] : ['disabled']).join('<span class="dot">·</span>');
    const pickable = checked && !cpDraft.autoSelect && s.enabled;
    const rows = open ? s.nodes.map(n => {
      const key = id + '::' + n.id;
      const fixed = !cpDraft.autoSelect && cpDraft.manualNodeId === key;
      return `<div class="node-row ${fixed ? 'fixed' : ''} ${pickable ? '' : 'static'}" ${pickable ? `onclick="cpDraft.manualNodeId='${key}';renderCpNode();renderCreateProfileSources()"` : ''}>
        <span class="node-flag">${n.flag}</span>
        <span class="node-name">${esc(n.name)}</span>
        ${fixed ? '<span class="conn-tag warn">fixed</span>' : ''}
        <span class="node-proto">${n.protocol}</span>
        <span onclick="event.stopPropagation();testLatency([['${id}','${n.id}']])" title="Tap to ping">${latHtml(n)}</span>
      </div>`;
    }).join('') : '';
    return `<div class="ps-card ${open ? 'open' : ''} ${checked ? 'sel' : ''}" data-id="${id}">
      <div class="ps-head">
        <div class="ps-check" onclick="toggleCreateProfileSource('${id}')"><div class="sub-checkbox ${checked ? 'checked' : ''}"></div></div>
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

function toggleCpOpen(id) {
  if (cpOpen.has(id)) cpOpen.delete(id); else cpOpen.add(id);
  renderCreateProfileSources();
}

sourceViewHooks.push(() => {
  if (!document.getElementById('sh-createprofile').classList.contains('open')) return;
  renderCreateProfileSources();
  renderCpNode();
});

function toggleCreateProfileSource(id) {
  if (createProfileSelected.has(id)) createProfileSelected.delete(id); else createProfileSelected.add(id);
  renderCreateProfileSources();
  renderCpNode();
}

function saveCreateProfile() {
  const name = document.getElementById('cp-name').value.trim() || ('Profile ' + (++profileSeq));
  const fields = { autoSelect: cpDraft.autoSelect, manualNodeId: cpDraft.manualNodeId,
                   inAuto: document.getElementById('cp-inauto').classList.contains('on') };
  if (editingProfileId) {
    const p = profilesData[editingProfileId];
    p.name = name;
    p.sources = Array.from(createProfileSelected);
    Object.assign(p, fields);
  } else {
    const id = 'profile' + Date.now();
    profilesData[id] = Object.assign({ id, name, sources: Array.from(createProfileSelected) }, fields);
    connectOrder.push(id);
  }
  editingProfileId = null;
  renderConnects();
  updateMainConnectCard();
  closeSheet('createprofile');
}

function deleteEditingProfile() {
  if (!editingProfileId) return;
  if (getProfileIds().length <= 1) { editingProfileId = null; closeSheet('createprofile'); return; }
  connectOrder = connectOrder.filter(x => x !== editingProfileId);
  delete profilesData[editingProfileId];
  const fallback = getProfileIds()[0];
  if (activeConnectId === editingProfileId) activeConnectId = fallback;
  Object.values(chainsData).forEach(c => {
    if (c.inId === editingProfileId) c.inId = fallback;
    if (c.outId === editingProfileId) c.outId = fallback;
    if (c.inId === c.outId) {   // a chain through one profile is pointless: drop it
      delete chainsData[c.id];
      connectOrder = connectOrder.filter(x => x !== c.id);
      if (activeConnectId === c.id) activeConnectId = fallback;
    }
  });
  editingProfileId = null;
  renderConnects();
  updateMainConnectCard();
  closeSheet('createprofile');
}

/* ══════════════════════ CREATE / EDIT CHAIN ══════════════════════
   Entry and exit must be different profiles. "Check route" pings every exit node
   through the entry's current node, so a chain that cannot work is visible before
   it is saved; the result is kept on the chain (a chain with no reachable exit is
   not usable, so Auto skips it). */

let chainDraft = { inId: null, outId: null, test: null };
let editingChainId = null;

function openCreateChain(editId) {
  editingChainId = editId || null;
  const ids = getProfileIds();
  if (!editingChainId && ids.length < 2) { toast('A chain needs two profiles — create another profile first'); return; }
  if (editingChainId) {
    const c = chainsData[editingChainId];
    document.getElementById('ccTitle').textContent = 'Edit chain';
    document.getElementById('ccSaveBtn').textContent = 'Save changes';
    document.getElementById('ccDeleteBtn').style.display = '';
    document.getElementById('cc-name').value = c.name;
    chainDraft = { inId: c.inId, outId: c.outId, test: c.test || null };
    document.getElementById('cc-inauto').classList.toggle('on', c.inAuto);
  } else {
    document.getElementById('ccTitle').textContent = 'Create chain';
    document.getElementById('ccSaveBtn').textContent = 'Create chain';
    document.getElementById('ccDeleteBtn').style.display = 'none';
    document.getElementById('cc-name').value = '';
    chainDraft = { inId: ids[0], outId: ids[1], test: null };
    document.getElementById('cc-inauto').classList.add('on');
  }
  renderChainEditor();
  openSheet('createchain');
}

function openEditChain(id) { openCreateChain(id); }

function renderChainEditor() {
  renderChainPicker('cc-in-list', 'in');
  renderChainPicker('cc-out-list', 'out');
  renderChainTest();
}

function renderChainPicker(elId, side) {
  const el = document.getElementById(elId);
  const current = side === 'in' ? chainDraft.inId : chainDraft.outId;
  const other = side === 'in' ? chainDraft.outId : chainDraft.inId;
  el.innerHTML = getProfileIds().map(id => {
    const p = profilesData[id];
    const taken = id === other;
    const n = profileNode(p);
    return `<div class="pick-row ${taken ? 'disabled' : ''}" ${taken ? '' : `onclick="pickChainSide('${side}','${id}')"`}>
      <div class="profile-radio ${id===current?'active':''}"></div>
      <span class="pick-row-name">${esc(p.name)}</span>
      <span class="pick-row-sub">${taken ? (side === 'in' ? 'exit' : 'entry') : (n ? n.flag + ' ' : '') + profileNodeCount(p) + ' nodes'}</span>
    </div>`;
  }).join('');
}

function pickChainSide(side, id) {
  if (side === 'in') chainDraft.inId = id; else chainDraft.outId = id;
  chainDraft.test = null;   // ends changed: the old check no longer applies
  renderChainEditor();
}

function renderChainTest() {
  const el = document.getElementById('cc-test');
  const entry = profileNode(profilesData[chainDraft.inId]);
  const exits = profileNodeRefs(profilesData[chainDraft.outId]);
  const t = chainDraft.test;
  const btn = `<button class="btn-secondary" onclick="testChainRoute()" ${!entry || !isAlive(entry) || (t && t.running) ? 'disabled' : ''}>${ICON.bolt}${t ? 'Check again' : 'Check route'}</button>`;
  let head;
  if (!entry || !isAlive(entry)) head = `<div class="route-sum warn">Entry has no working node — ping its subscriptions first.</div>`;
  else if (!t) head = `<div class="route-sum">Pings every exit node through the entry node ${entry.flag} ${esc(entry.name)}.</div>`;
  else if (t.running) head = `<div class="route-sum">Checking ${exits.length} exit nodes via ${entry.flag} ${esc(entry.name)}…</div>`;
  else {
    const ok = Object.values(t.results).filter(v => v >= 0).length;
    head = ok
      ? `<div class="route-sum good">${ok} of ${exits.length} exit nodes reachable via ${entry.flag} ${esc(entry.name)}</div>`
      : `<div class="route-sum bad">No exit node is reachable through the entry — this chain will not connect.</div>`;
  }
  const rows = t ? exits.map(({ sid, node }) => {
    const v = t.results[sid + '::' + node.id];
    return `<div class="node-row static">
      <span class="node-flag">${node.flag}</span>
      <span class="node-name">${esc(node.name)}</span>
      ${latHtml({ latency: v === undefined ? 'testing' : v })}
    </div>`;
  }).join('') : '';
  el.innerHTML = `<div class="route-box">${head}${btn}</div>${rows ? `<div class="route-list">${rows}</div>` : ''}`;
}

function testChainRoute() {
  const entry = profileNode(profilesData[chainDraft.inId]);
  const exits = profileNodeRefs(profilesData[chainDraft.outId]);
  const t = chainDraft.test = { running: true, results: {} };
  renderChainTest();
  let left = exits.length;
  exits.forEach(({ sid, node }) => setTimeout(() => {
    if (chainDraft.test !== t) return;   // ends changed meanwhile
    // Mock: the exit answers through the entry unless it is down or blocks the entry's IP.
    t.results[sid + '::' + node.id] = !isAlive(node) || Math.random() < .25 ? -1 : entry.latency + node.latency + Math.round(Math.random() * 60);
    if (--left === 0) t.running = false;
    renderChainTest();
  }, 400 + Math.random() * 1200));
  if (!exits.length) { t.running = false; renderChainTest(); }
}

function saveCreateChain() {
  if (chainDraft.inId === chainDraft.outId) { toast('Entry and exit must be different profiles'); return; }
  const name = document.getElementById('cc-name').value.trim() || ('Chain ' + (++chainSeq));
  const t = chainDraft.test && !chainDraft.test.running ? chainDraft.test : null;
  const fields = { inId: chainDraft.inId, outId: chainDraft.outId,
                   inAuto: document.getElementById('cc-inauto').classList.contains('on'),
                   test: t ? { reachable: Object.values(t.results).filter(v => v >= 0).length, results: t.results } : null };
  if (editingChainId) {
    Object.assign(chainsData[editingChainId], { name }, fields);
  } else {
    const id = 'chain' + Date.now();
    chainsData[id] = Object.assign({ id, name }, fields);
    connectOrder.push(id);
  }
  editingChainId = null;
  renderConnects();
  updateMainConnectCard();
  closeSheet('createchain');
}

function deleteEditingChain() {
  if (!editingChainId) return;
  connectOrder = connectOrder.filter(x => x !== editingChainId);
  delete chainsData[editingChainId];
  if (activeConnectId === editingChainId) activeConnectId = getProfileIds()[0];
  editingChainId = null;
  renderConnects();
  updateMainConnectCard();
  closeSheet('createchain');
}
