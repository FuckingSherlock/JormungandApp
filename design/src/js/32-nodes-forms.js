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
    // auto = the provider's period (profile-update-interval) if it sent one, else the global one
    const autoSecs = autoCfg.subsEvery && s.providerInterval ? Math.max(1, s.providerInterval) * 3600 : autoCfg.subsEvery;
    document.getElementById('sf-interval').placeholder = 'auto · ' + subsEveryText(autoSecs);
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

  // The core applies the filter to server names (flag included); JS and Dart agree on plain regexes.
  if (fields.filter) {
    try { new RegExp(fields.filter, 'u'); } catch (e) { toast('Filter is not a valid regular expression'); return; }
  }
  if (editingSourceId) {
    const s = sourcesData[editingSourceId];
    if (name) s.name = name;
    if (s.kind === 'sub') {
      if (!fields.url) { toast('The subscription URL is empty'); return; }
      // Another address, User-Agent or HWID can mean another server list: forget the UA
      // strategy and its ETags, ask again with every UA. A new filter needs a full read
      // (the core sends no ETag for it). Either way the list is fetched now.
      const rediscover = s.url !== fields.url || s.userAgent !== fields.userAgent || !!s.hwid !== fields.hwid;
      const refetch = rediscover || (s.filter || '') !== fields.filter;
      Object.assign(s, fields);
      if (rediscover) { s.uaStrategy = []; s.discoveredAt = 0; }
      if (refetch) setTimeout(() => updateSource(s.id, { rediscover }), 0);
    }
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
    // The first fetch: nodes appear after the discovery request.
    s.updating = true;
    backend.fetchSource(s).then(() => { delete s.lastError; },
      e => { s.lastError = { msg: e.message, at: Date.now() }; toast('Could not load ' + s.name + ': ' + e.message); }).then(() => {
      s.count = s.nodes.length;
      s.updating = false;
      renderAll();
    });
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
  document.getElementById('nfDeleteBtn').style.display = n ? '' : 'none';
  document.getElementById('nf-link').value = '';
  document.getElementById('nf-link').placeholder = n ? 'vless://… — replaces this server, keeps its place'
    : 'vless://… — fills the fields below; one link per line adds them all';
  document.getElementById('nf-name').value = n ? n.name : '';
  document.getElementById('nf-addr').value = n ? n.address : '';
  document.getElementById('nf-port').value = n ? n.port : '';
  document.getElementById('nf-secret').value = n ? nodeSecret(n) : '';
  nfNameTouched = false;
  setChip('nf-proto', n ? PROTO_CHIP[n.protocol] || 'VLESS' : 'VLESS');
  nfProtoChanged();
  nfShowMany(0);

  // Group picker only when adding; existing groups + "New group".
  const groups = manualGroups();
  const target = sid || groups[0] || '__new';
  document.getElementById('nf-group-wrap').style.display = n ? 'none' : '';
  document.getElementById('nf-group').innerHTML =
    groups.map(g => `<div class="chip ${g === target ? 'active' : ''}" data-gid="${g}" onclick="pickChip(this,'nf-group')">${esc(sourcesData[g].name)}</div>`).join('') +
    `<div class="chip ${target === '__new' ? 'active' : ''}" data-gid="__new" onclick="pickChip(this,'nf-group')">+ New group</div>`;
  openSheet('nodeform');
}

const PROTO_CHIP = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', ss: 'SS', hy2: 'HY2', tuic: 'TUIC', anytls: 'AnyTLS', socks: 'SOCKS' };
// What the secret field holds, per protocol (the core reads it the same way: manual.dart).
const SECRET_FIELD = {
  vless: ['UUID', '8c1f3a52-7d0e-4e2b-9d71-…'], vmess: ['UUID', '8c1f3a52-7d0e-4e2b-9d71-…'],
  trojan: ['Password', '••••••••••••'], hy2: ['Password', '••••••••••••'], anytls: ['Password', '••••••••••••'],
  ss: ['Method:password', 'aes-256-gcm:secret'], tuic: ['UUID:password', 'uuid:password'],
  socks: ['User:password (optional)', 'user:password'],
};
let nfNameTouched = false;   // a name typed by hand wins over the link's #name

function nfProtocol() {
  const chip = chipValue('nf-proto', 'VLESS');
  return Object.keys(PROTO_CHIP).find(k => PROTO_CHIP[k] === chip) || 'vless';
}
function nfProtoChanged() {
  const [label, ph] = SECRET_FIELD[nfProtocol()];
  document.getElementById('nf-secret-label').textContent = label;
  document.getElementById('nf-secret').placeholder = ph;
}

// The secret as the form shows it: from the core's outbound, or the mock's field.
function nodeSecret(n) {
  const o = n.outbound;
  if (!o) return n.secret || '';
  if (o.type === 'shadowsocks') return o.method + ':' + o.password;
  if (o.type === 'tuic') return o.uuid + ':' + (o.password || '');
  if (o.type === 'socks') return o.username ? o.username + ':' + (o.password || '') : '';
  return o.uuid || o.password || '';
}

// Links in the pasted text: one per line (or separated by spaces).
const splitLinks = text => (text || '').split(/\s*[\r\n]+\s*|\s+(?=[a-z][a-z0-9+.-]*:\/\/)/i).map(s => s.trim()).filter(Boolean);

function nfShowMany(count) {
  const many = count > 1 && !editingNode.nid;
  const note = document.getElementById('nf-many');
  note.style.display = many ? '' : 'none';
  note.textContent = many ? count + ' servers — each is added with the name from its link' : '';
  document.getElementById('nf-fields').style.display = many ? 'none' : '';
  document.getElementById('nfSaveBtn').textContent = editingNode.nid ? 'Save' : many ? 'Add ' + count + ' servers' : 'Add server';
}

// A pasted link fills the fields (several: a note instead of the fields).
function parseNodeLink() {
  const got = splitLinks(document.getElementById('nf-link').value).map(parseShareLinkLite).filter(Boolean);
  nfShowMany(got.length);
  const p = got[0];
  if (!p || got.length > 1) return;
  setChip('nf-proto', PROTO_CHIP[p.protocol]);
  nfProtoChanged();
  document.getElementById('nf-addr').value = p.address;
  document.getElementById('nf-port').value = p.port;
  document.getElementById('nf-secret').value = p.secret;
  if (p.name && !nfNameTouched) document.getElementById('nf-name').value = p.name;
}

function saveNodeForm() {
  const address = document.getElementById('nf-addr').value.trim().replace(/^\[|\]$/g, '');
  const link = document.getElementById('nf-link').value.trim();
  const f = {
    protocol: nfProtocol(), address, port: document.getElementById('nf-port').value.trim() || '443',
    secret: document.getElementById('nf-secret').value.trim(),
    name: document.getElementById('nf-name').value.trim(), nameTouched: nfNameTouched, link,
    edit: editingNode.nid ? sourcesData[editingNode.sid].nodes.find(x => x.id === editingNode.nid) : null,
  };
  // a link carries its own address (vmess base64, legacy ss, IPv6: the core reads them)
  if (!link && !address) { toast('Address is required'); return; }
  const chip = document.querySelector('#nf-group .chip.active');
  const pick = chip ? chip.dataset.gid : '__new';
  const btn = document.getElementById('nfSaveBtn');
  btn.disabled = true;
  backend.manualNodes(f).then(nodes => {
    if (f.edit) {
      // the id stays: profiles, chains and pins that name the server keep it
      Object.keys(f.edit).filter(k => k !== 'id').forEach(k => delete f.edit[k]);
      Object.assign(f.edit, nodes[0], { id: editingNode.nid });   // its ping: by the new address (serverKey)
      closeSheet('nodeform');
      renderAll();
      return;
    }
    // the same server twice gets the same id: once per group
    const have = new Set(pick === '__new' ? [] : sourcesData[pick].nodes.map(n => n.id));
    const fresh = nodes.filter(n => !have.has(n.id) && have.add(n.id));
    const dup = nodes.length - fresh.length;
    if (!fresh.length) { toast(nodes.length > 1 ? 'These servers are already in the group' : 'This server is already in the group'); return; }
    let gid = pick;
    if (gid === '__new') {
      gid = 'src' + (sourceSeq++);
      sourcesData[gid] = { id:gid, kind:'node', name:'Manual ' + (manualGroups().length + 1), enabled:true, inAuto:true, offNodes:[], nodes:[] };
      sourceOrder.push(gid);
      sourceAdded(gid);
    }
    const g = sourcesData[gid];
    g.nodes.push(...fresh);
    g.count = g.nodes.length;
    expandState[gid] = true;
    closeSheet('nodeform');
    renderAll();
    if (nodes.length > 1 || dup) toast('Added ' + fresh.length + (fresh.length === 1 ? ' server' : ' servers') + (dup ? ', ' + dup + ' already there' : ''));
  }, e => toast(e.message)).then(() => { btn.disabled = false; });
}

