/* ── Subscription / group form ── */

let editingSourceId = null;

function setChip(groupId, value) {
  document.querySelectorAll('#' + groupId + ' .chip').forEach(c => c.classList.toggle('active', c.textContent === value));
}
function chipValue(groupId, fallback) {
  const c = document.querySelector('#' + groupId + ' .chip.active');
  return c ? c.textContent : fallback;
}

function toggleSrcAdvanced(force) {
  const box = document.getElementById('sf-adv');
  const open = force !== undefined ? force : box.style.display === 'none';
  box.style.display = open ? '' : 'none';
  document.getElementById('sf-adv-toggle').classList.toggle('open', open);
}

function openSrcForm(id, prefillUrl) {
  editingSourceId = id || null;
  const s = id ? sourcesData[id] : mkSub('draft', '', 0);
  const isGroup = s.kind === 'node';
  document.getElementById('sfTitle').textContent = !id ? 'Add subscription' : isGroup ? 'Rename group' : 'Edit subscription';
  document.getElementById('sfSaveBtn').textContent = id ? 'Save' : 'Add';
  document.getElementById('sfDeleteBtn').style.display = id ? '' : 'none';
  document.getElementById('sf-sub-only-top').style.display = isGroup ? 'none' : '';
  document.getElementById('sf-sub-only').style.display = isGroup ? 'none' : '';

  document.getElementById('sf-url').value = prefillUrl || (id && !isGroup ? s.url : '');
  document.getElementById('sf-name').value = id ? s.name : '';
  if (!isGroup) {
    // Empty = 'auto': follows the global period from the Auto mode sheet.
    document.getElementById('sf-interval').value = s.updateInterval === 'auto' ? '' : s.updateInterval;
    document.getElementById('sf-interval').placeholder = 'auto · ' + subsEveryText(autoCfg.subsEvery);
    document.getElementById('sf-reload').classList.toggle('on', !!s.reloadAfterUpdate);
    document.getElementById('sf-testafter').classList.toggle('on', !!s.testAfterUpdate);
    document.getElementById('sf-hwid').classList.toggle('on', !!s.hwid);
    document.getElementById('sf-keeprules').classList.toggle('on', !!s.keepRules);
    document.getElementById('sf-filter').value = s.filter;
    document.getElementById('sf-password').value = s.password;
    document.getElementById('sf-website').value = s.website;
    setChip('sf-ua', s.userAgent);
    setChip('sf-channel', s.channel);
  }
  toggleSrcAdvanced(false);
  openSheet('srcform');
}

function saveSrcForm() {
  const name = document.getElementById('sf-name').value.trim();
  const fields = {
    url: document.getElementById('sf-url').value.trim(),
    updateInterval: document.getElementById('sf-interval').value.trim() === '' ? 'auto' : Math.max(0, parseInt(document.getElementById('sf-interval').value, 10) || 0),
    reloadAfterUpdate: document.getElementById('sf-reload').classList.contains('on'),
    testAfterUpdate: document.getElementById('sf-testafter').classList.contains('on'),
    hwid: document.getElementById('sf-hwid').classList.contains('on'),
    keepRules: document.getElementById('sf-keeprules').classList.contains('on'),
    filter: document.getElementById('sf-filter').value.trim(),
    password: document.getElementById('sf-password').value,
    website: document.getElementById('sf-website').value.trim(),
    userAgent: chipValue('sf-ua', 'Auto'),
    channel: chipValue('sf-channel', 'Direct first'),
  };

  if (editingSourceId) {
    const s = sourcesData[editingSourceId];
    if (name) s.name = name;
    if (s.kind === 'sub') Object.assign(s, fields);
  } else {
    if (!fields.url) { toast('Paste a subscription URL first'); return; }
    const id = 'src' + (sourceSeq++);
    let host = 'New subscription';
    try { host = new URL(fields.url).hostname; } catch (e) {}
    const s = mkSub(id, name || host, 0, fields);
    s.nodes = [];
    s.count = 0;
    s.updatedAt = Date.now();
    sourcesData[id] = s;
    sourceOrder.push(id);
    sourceAdded(id);
    expandState[id] = true;
    // Simulate the first fetch: nodes appear after the discovery request.
    s.updating = true;
    setTimeout(() => {
      s.nodes = genNodes(8 + Math.floor(Math.random() * 20), 'sub');
      s.count = s.nodes.length;
      s.usage = { used: 0, total: 0 };
      s.updating = false;
      renderAll();
    }, 1200);
  }
  editingSourceId = null;
  closeSheet('srcform');
  renderAll();
}

function pasteFromClipboard() {
  // Mockup: pretend the clipboard held a subscription URL.
  openSrcForm(null, 'https://sub.example.net/api/sub/LvRxk-PCg04NKVzp');
  toast('Subscription URL found in clipboard');
}

/* ── Manual server form ── */

let editingNode = { sid: null, nid: null };

function manualGroups() { return sourceOrder.filter(id => sourcesData[id].kind === 'node'); }

function openNodeForm(sid, nid) {
  editingNode = { sid: sid || null, nid: nid || null };
  const n = sid && nid ? sourcesData[sid].nodes.find(x => x.id === nid) : null;
  document.getElementById('nfTitle').textContent = n ? 'Edit server' : 'Add server';
  document.getElementById('nfSaveBtn').textContent = n ? 'Save' : 'Add server';
  document.getElementById('nfDeleteBtn').style.display = n ? '' : 'none';
  document.getElementById('nf-link').value = '';
  document.getElementById('nf-name').value = n ? n.name : '';
  document.getElementById('nf-addr').value = n ? n.address : '';
  document.getElementById('nf-port').value = n ? n.port : '';
  document.getElementById('nf-secret').value = n ? (n.secret || '') : '';
  setChip('nf-proto', n ? n.protocol.toUpperCase().replace('VMESS','VMess') : 'VLESS');

  // Group picker only when adding; existing groups + "New group".
  const groups = manualGroups();
  const target = sid || groups[0] || '__new';
  document.getElementById('nf-group-wrap').style.display = n ? 'none' : '';
  document.getElementById('nf-group').innerHTML =
    groups.map(g => `<div class="chip ${g === target ? 'active' : ''}" data-gid="${g}" onclick="pickChip(this,'nf-group')">${esc(sourcesData[g].name)}</div>`).join('') +
    `<div class="chip ${target === '__new' ? 'active' : ''}" data-gid="__new" onclick="pickChip(this,'nf-group')">+ New group</div>`;
  openSheet('nodeform');
}

function parseNodeLink() {
  const link = document.getElementById('nf-link').value.trim();
  const m = link.match(/^(vless|vmess|trojan|ss|hy2|hysteria2|tuic|socks5?):\/\/(?:[^@]*@)?([^:/?#]+):(\d+)[^#]*(?:#(.*))?$/i);
  if (!m) return;
  const proto = m[1].toLowerCase().replace('hysteria2','hy2').replace(/^socks5?$/,'socks');
  const map = { vless:'VLESS', vmess:'VMess', trojan:'Trojan', ss:'SS', hy2:'HY2', tuic:'TUIC', socks:'SOCKS' };
  setChip('nf-proto', map[proto]);
  document.getElementById('nf-addr').value = m[2];
  document.getElementById('nf-port').value = m[3];
  if (m[4]) document.getElementById('nf-name').value = decodeURIComponent(m[4]);
}

function saveNodeForm() {
  const protocol = chipValue('nf-proto', 'VLESS').toLowerCase();
  const address = document.getElementById('nf-addr').value.trim();
  const port = document.getElementById('nf-port').value.trim() || '443';
  const secret = document.getElementById('nf-secret').value.trim();
  const name = document.getElementById('nf-name').value.trim() || address || 'Server';

  if (editingNode.nid) {
    const n = sourcesData[editingNode.sid].nodes.find(x => x.id === editingNode.nid);
    Object.assign(n, { name, protocol, address, port, secret });
  } else {
    if (!address) { toast('Address is required'); return; }
    const chip = document.querySelector('#nf-group .chip.active');
    let gid = chip ? chip.dataset.gid : '__new';
    if (gid === '__new') {
      gid = 'src' + (sourceSeq++);
      sourcesData[gid] = { id:gid, kind:'node', name:'Manual ' + (manualGroups().length + 1), enabled:true, inAuto:true, offNodes:[], nodes:[] };
      sourceOrder.push(gid);
      sourceAdded(gid);
    }
    const g = sourcesData[gid];
    g.nodes.push({ id:'n' + Date.now(), flag:'🌐', name, protocol, address, port, secret });
    g.count = g.nodes.length;
    expandState[gid] = true;
  }
  closeSheet('nodeform');
  renderAll();
}

