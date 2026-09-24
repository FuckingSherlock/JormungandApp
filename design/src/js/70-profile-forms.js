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
    const rows = open ? sortedNodes(s.nodes).map(n => {
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
   Entry and exit must be different profiles. "Check route" is informational only (it
   does not change the chain or Auto): it tells the user whether the chain can work
   and which entry -> exit pairs are fastest. See testChainRoute for the procedure. */

let chainDraft = { inId: null, outId: null };
let chainTest = null;   // { running, stage, done, total, pairs: [{entry, exit, ms}], showAll }
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
    chainDraft = { inId: c.inId, outId: c.outId };
    document.getElementById('cc-inauto').classList.toggle('on', c.inAuto);
  } else {
    document.getElementById('ccTitle').textContent = 'Create chain';
    document.getElementById('ccSaveBtn').textContent = 'Create chain';
    document.getElementById('ccDeleteBtn').style.display = 'none';
    document.getElementById('cc-name').value = '';
    chainDraft = { inId: ids[0], outId: ids[1] };
    document.getElementById('cc-inauto').classList.add('on');
  }
  chainTest = null;
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
  chainTest = null;   // ends changed: the old check no longer applies (a running one stops)
  renderChainEditor();
}

const ROUTE_TOP = 4;   // working pairs shown before "show all"

function renderChainTest() {
  const el = document.getElementById('cc-test');
  if (!el) return;
  const t = chainTest;
  const nEntry = profileNodeRefs(profilesData[chainDraft.inId]).length;
  const nExit = profileNodeRefs(profilesData[chainDraft.outId]).length;
  const btn = t && t.running
    ? `<button class="btn-secondary" onclick="stopChainRoute()">Stop</button>`
    : `<button class="btn-secondary" onclick="testChainRoute()" ${nEntry && nExit ? '' : 'disabled'}>${ICON.bolt}${t ? 'Check again' : 'Check route'}</button>`;
  let sum;
  if (!nEntry || !nExit) sum = `<div class="route-sum warn">${!nEntry ? 'Entry' : 'Exit'} profile has no enabled nodes.</div>`;
  else if (!t) sum = `<div class="route-sum">Tries every exit node through the entry nodes, fastest entries first.</div>`;
  else if (t.running) sum = `<div class="route-sum">${t.stage}<div class="route-progress"><div style="width:${t.total ? t.done / t.total * 100 : 0}%"></div></div></div>`;
  else if (t.pairs.length) sum = `<div class="route-sum good">${t.pairs.length} working pair${t.pairs.length === 1 ? '' : 's'}${t.stopped ? ' (stopped early)' : ''} · best ${t.pairs[0].ms} ms</div>`;
  else sum = `<div class="route-sum bad">${t.stopped ? 'Stopped — no working pair found yet.' : 'No exit node answers through any entry node — this chain will not connect.'}</div>`;

  let list = '';
  if (t && t.pairs.length) {
    const shown = t.showAll ? t.pairs : t.pairs.slice(0, ROUTE_TOP);
    list = `<div class="route-list">${shown.map(({ entry, exit, ms }) => `<div class="route-pair">
        <span class="route-end"><span class="node-flag">${entry.flag}</span><span class="node-name">${esc(entry.name)}</span></span>
        <span class="conn-arrow">→</span>
        <span class="route-end"><span class="node-flag">${exit.flag}</span><span class="node-name">${esc(exit.name)}</span></span>
        ${latMsHtml(ms)}
      </div>`).join('')}
      ${t.pairs.length > ROUTE_TOP ? `<div class="route-more" onclick="chainTest.showAll=!chainTest.showAll;renderChainTest()">${t.showAll ? 'Show top ' + ROUTE_TOP : 'Show all ' + t.pairs.length}
        <svg class="src-chevron" style="${t.showAll ? 'transform:rotate(180deg)' : ''}" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg></div>` : ''}
    </div>`;
  }
  el.innerHTML = `<div class="route-box">${sum}${btn}</div>${list}`;
}

/* Route check:
   1. Entry nodes: use cached pings if all are younger than 5 min, otherwise ping them all.
   2. Take alive entries fastest first; for each, ping every exit through it (exits in
      parallel, entries one after another) and collect the working pairs.
   3. If cached entry pings were used and the first 2 entries gave no working pair, the
      cache is probably stale: re-ping the entries once and start over.
   A server never pairs with itself (both profiles may share a subscription).
   Results: working pairs sorted by total latency. */
async function testChainRoute() {
  const entries = profileNodeRefs(profilesData[chainDraft.inId]).map(r => r.node);
  const exits = profileNodeRefs(profilesData[chainDraft.outId]).map(r => r.node);
  const t = chainTest = { running: true, stage: '', done: 0, total: 0, pairs: [], showAll: false };
  const live = () => chainTest === t && !t.stopped;
  const step = stage => { t.stage = stage; renderChainTest(); };

  let fromCache = entries.every(n => pingAge(n) < PING_FRESH_MS);
  if (!fromCache) { step(`Pinging ${entries.length} entry nodes…`); await pingNodes(entries); }

  for (let attempt = 0; attempt < 2 && live(); attempt++) {
    const alive = entries.filter(isAlive).sort((a, b) => ping(a) - ping(b));
    t.pairs = []; t.done = 0; t.total = alive.length;
    let retry = false;
    for (let i = 0; i < alive.length && live(); i++) {
      const entry = alive[i];
      step(`Entry ${i + 1} of ${alive.length}: ${entry.flag} ${esc(entry.name)} → ${exits.length} exits`);
      const res = await Promise.all(exits.filter(exit => serverKey(exit) !== serverKey(entry)).map(exit => pingPair(entry, exit).then(ms => ({ entry, exit, ms }))));
      if (!live()) return;
      t.pairs.push(...res.filter(r => r.ms >= 0));
      t.pairs.sort((a, b) => a.ms - b.ms);
      t.done = i + 1;
      if (fromCache && i === 1 && !t.pairs.length) { retry = true; break; }
    }
    if (!retry) break;
    step('No pair through the first entries — re-pinging entry nodes…');
    fromCache = false;
    await pingNodes(entries);
  }
  if (chainTest !== t) return;
  t.running = false;
  renderChainTest();
}

function stopChainRoute() {
  if (!chainTest) return;
  chainTest.stopped = true;
  chainTest.running = false;
  renderChainTest();
}

function saveCreateChain() {
  if (chainDraft.inId === chainDraft.outId) { toast('Entry and exit must be different profiles'); return; }
  const name = document.getElementById('cc-name').value.trim() || ('Chain ' + (++chainSeq));
  const fields = { inId: chainDraft.inId, outId: chainDraft.outId,
                   inAuto: document.getElementById('cc-inauto').classList.contains('on') };
  if (editingChainId) {
    Object.assign(chainsData[editingChainId], { name }, fields);
  } else {
    const id = 'chain' + Date.now();
    chainsData[id] = Object.assign({ id, name }, fields);
    connectOrder.push(id);
  }
  editingChainId = null;
  chainTest = null;
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
