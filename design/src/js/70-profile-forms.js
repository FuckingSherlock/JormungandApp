/* ══════════════════════ CREATE / EDIT PROFILE ══════════════════════ */

let createProfileSelected = new Set();
let editingProfileId = null;
let cpDraft = { autoSelect: true, manualNodeId: null };

function setCpMode(auto) {
  cpDraft.autoSelect = auto;
  renderCpNode();
}
function renderCpNode() {
  document.querySelectorAll('#cp-mode .chip').forEach((c, i) => c.classList.toggle('active', i === (cpDraft.autoSelect ? 0 : 1)));
  document.getElementById('cp-fixed-row').style.display = cpDraft.autoSelect ? 'none' : '';
  const ref = profileNodeRefs({ sources: [...createProfileSelected] }).find(r => r.sid + '::' + r.node.id === cpDraft.manualNodeId);
  document.getElementById('cp-fixed-label').textContent = ref ? ref.node.flag + ' ' + ref.node.name : 'Choose…';
}
function pickCpNode() {
  openPickNode({ sources: [...createProfileSelected], current: cpDraft.manualNodeId,
    onPick: key => { cpDraft.manualNodeId = key; renderCpNode(); } });
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
  renderCreateProfileSources();
  renderCpNode();
  openSheet('createprofile');
}

function openEditProfile(id) { openCreateProfile(id); }

function renderCreateProfileSources() {
  const el = document.getElementById('cp-source-list');
  el.innerHTML = sourceOrder.map(id => {
    const s = sourcesData[id];
    const icon = subIcon(s.kind);
    const checked = createProfileSelected.has(id);
    return `<div class="sub-item" style="padding-left:18px" onclick="toggleCreateProfileSource('${id}')">
      <div class="sub-checkbox ${checked?'checked':''}"></div>
      <div class="sub-icon ${icon.cls}"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="${icon.color}" stroke-width="2.5" stroke-linecap="round">${icon.svg}</svg></div>
      <span class="sub-name">${s.name}</span>
      <span class="sub-count">${s.count} nodes</span>
    </div>`;
  }).join('');
}

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
  });
  editingProfileId = null;
  renderConnects();
  updateMainConnectCard();
  closeSheet('createprofile');
}

/* ══════════════════════ CREATE / EDIT CHAIN ══════════════════════ */

let chainDraft = { inId: null, outId: null };
let editingChainId = null;

function openCreateChain(editId) {
  editingChainId = editId || null;
  if (editingChainId) {
    const c = chainsData[editingChainId];
    document.getElementById('ccTitle').textContent = 'Edit chain';
    document.getElementById('ccSaveBtn').textContent = 'Save changes';
    document.getElementById('ccDeleteBtn').style.display = '';
    document.getElementById('cc-name').value = c.name;
    chainDraft = { inId: c.inId, outId: c.outId };
    document.getElementById('cc-inauto').classList.toggle('on', c.inAuto);
  } else {
    document.getElementById('ccTitle').textContent = 'Create chain';
    document.getElementById('ccSaveBtn').textContent = 'Create chain';
    document.getElementById('ccDeleteBtn').style.display = 'none';
    document.getElementById('cc-name').value = '';
    const ids = getProfileIds();
    chainDraft = { inId: ids[0], outId: ids[0] };
    document.getElementById('cc-inauto').classList.add('on');
  }
  renderChainPicker('cc-in-list', 'in');
  renderChainPicker('cc-out-list', 'out');
  openSheet('createchain');
}

function openEditChain(id) { openCreateChain(id); }

function renderChainPicker(elId, side) {
  const el = document.getElementById(elId);
  const current = side === 'in' ? chainDraft.inId : chainDraft.outId;
  el.innerHTML = getProfileIds().map(id => {
    const p = profilesData[id];
    return `<div class="pick-row" onclick="pickChainSide('${side}','${id}')">
      <div class="profile-radio ${id===current?'active':''}"></div>
      <span class="pick-row-name">${p.name}</span>
      <span class="pick-row-sub">${profileNodeCount(p)} nodes</span>
    </div>`;
  }).join('');
}

function pickChainSide(side, id) {
  if (side === 'in') chainDraft.inId = id; else chainDraft.outId = id;
  renderChainPicker('cc-in-list', 'in');
  renderChainPicker('cc-out-list', 'out');
}

function saveCreateChain() {
  const name = document.getElementById('cc-name').value.trim() || ('Chain ' + (++chainSeq));
  const wasEditing = editingChainId;
  if (editingChainId) {
    const c = chainsData[editingChainId];
    c.name = name;
    c.inId = chainDraft.inId;
    c.outId = chainDraft.outId;
    c.inAuto = document.getElementById('cc-inauto').classList.contains('on');
  } else {
    const id = 'chain' + Date.now();
    chainsData[id] = { id, name, inId: chainDraft.inId, outId: chainDraft.outId,
                     inAuto: document.getElementById('cc-inauto').classList.contains('on') };
    connectOrder.push(id);
  }
  editingChainId = null;
  renderConnects();
  if (wasEditing === activeConnectId) updateMainConnectCard();
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

