/* ══════════════════════ DNS (Settings → DNS sheet; the Home DNS card opens it over Home) ══════════════════════
   - Global DNS: a list of servers. Ticked = in use, order = priority: the first ticked one
     answers; if it stops answering, the next ticked one takes over (the app pings them
     and swaps sing-box's main server itself — sing-box has no DNS fallback of its own).
   - Each server: address (system | udp:// | tcp:// | tls:// | https:// | quic:// | bare IP)
     and "via": Direct or VPN (the server's detour).
   - Rules with DNS "Auto" use the first ticked server whose "via" matches the rule's
     action: Direct → a direct server, VPN → a server via VPN (see docs/rules.md).
   - Hijack DNS: every DNS query, even to a hard-coded 8.8.8.8, is sent to the core's DNS.
     TUN only, but switchable any time (a note says when TUN is off).
   - FakeIP: answer with fake addresses (198.18.0.0/15) and route by domain; off by default;
     exclusions get real answers.
   Flutter: DnsService (server list + health pings), settings in one DnsConfig. */

const dnsServers = {
  remote: { id: 'remote', name: 'Cloudflare', addr: 'https://1.1.1.1/dns-query', via: 'vpn', on: true },
  local:  { id: 'local',  name: 'Local',      addr: 'system',                    via: 'direct', on: true },
  google: { id: 'google', name: 'Google',     addr: 'tls://8.8.8.8',              via: 'vpn', on: false },
};
let dnsOrder = ['remote', 'local', 'google'];
let dnsSeq = 1;
const dnsCfg = {
  hijack: true, fakeip: false,
  fakeipExclude: ['*.sberbank.ru', '*.tinkoff.ru', '*.gosuslugi.ru', '*.steamserver.net', '*.xboxlive.com', 'time.*.com'],
};
const dnsPing = {};   // id -> ms | -1 | 'testing'

const DNS_ADDR_RE = /^(system|(udp|tcp|tls|https|quic):\/\/[^\s/]+(\/\S*)?|\d{1,3}(\.\d{1,3}){3}(:\d+)?)$/;
function dnsKind(addr) {
  if (addr === 'system') return 'System';
  const m = /^(\w+):\/\//.exec(addr);
  return { https: 'DoH', tls: 'DoT', quic: 'DoQ', tcp: 'TCP', udp: 'UDP' }[m ? m[1] : 'udp'];
}
const dnsActive = () => dnsOrder.filter(id => dnsServers[id].on);
// The server a rule's DNS "Auto" resolves to: first ticked one with the matching route.
const dnsAutoFor = via => dnsActive().map(id => dnsServers[id]).find(s => s.via === via);

async function pingDns(id) {
  const s = dnsServers[id];
  dnsPing[id] = 'testing'; renderDns();
  await wait(300 + Math.random() * 500);
  const base = s.addr === 'system' ? 12 : s.via === 'vpn' ? 70 : 25;
  dnsPing[id] = hash(s.addr) % 9 === 4 ? -1 : Math.round(base * (.8 + Math.random() * .6));
  renderDns();
}
const pingAllDns = () => dnsOrder.forEach(pingDns);

function toggleDnsOn(id) {
  const s = dnsServers[id];
  if (s.on && dnsActive().length === 1) { toast('At least one DNS server must stay on'); return; }
  s.on = !s.on;
  renderDns();
}
function setDnsCfg(key, val) { dnsCfg[key] = val; renderDns(); }
function addFakeipExclude(input) {
  const v = input.value.trim();
  if (v && !dnsCfg.fakeipExclude.includes(v)) dnsCfg.fakeipExclude.push(v);
  renderDns();
  document.getElementById('fx-input').focus();
}
function removeFakeipExclude(i) { dnsCfg.fakeipExclude.splice(i, 1); renderDns(); }

function startDnsDrag(e, id) {
  const rowEl = document.querySelector('#dns-list .dns-row[data-id="' + id + '"]');
  startRowDrag(e, rowEl, '.dns-row', () => dnsOrder, renderDns);
}

// Opened over the current view from the Home card or the Settings row; servers never pinged get a ping at once.
function openDnsSettings() {
  openSheet('setdns');
  dnsOrder.filter(id => dnsServers[id].on && dnsPing[id] === undefined).forEach(pingDns);
}

function renderDns() {
  const el = document.getElementById('dns-settings');
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${click}"><div class="mini-toggle-thumb"></div></div>`;
  const rows = dnsOrder.map((id, i) => {
    const s = dnsServers[id], rank = s.on ? dnsActive().indexOf(id) + 1 : '';
    return `<div class="set-row dns-row ${s.on ? '' : 'off'}" data-id="${id}">
      <div class="drag-handle cc-grip" onpointerdown="startDnsDrag(event,'${id}')">${GRIP_SVG}</div>
      <span class="cc-rank">${rank}</span>
      <div class="sub-checkbox ${s.on ? 'checked' : ''}" onclick="toggleDnsOn('${id}')"></div>
      <div class="dns-main" onclick="openDnsForm('${id}')">
        <div class="dns-name">${esc(s.name)}<span class="via-tag ${s.via}">${s.via === 'vpn' ? 'VPN' : 'Direct'}</span></div>
        <div class="dns-addr">${esc(s.addr)}</div>
      </div>
      <span onclick="pingDns('${id}')">${latMsHtml(dnsPing[id])}</span>
    </div>`;
  }).join('');
  const tunOff = segState.mode !== 'tun';
  el.innerHTML = `
    <div class="am-label">Global DNS<button class="help-btn" onclick="openHelp('dns')" title="What is this?">?</button>
      <button class="am-link" onclick="pingAllDns()">Ping all</button></div>
    <div class="set-group" id="dns-list">${rows}
      <div class="node-add" onclick="openDnsForm()"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>Add DNS server</div>
    </div>
    <div class="am-label">In TUN mode</div>
    <div class="set-group">
      <div class="set-row"><div class="set-label" style="flex:1">Hijack DNS<div class="set-hint ${tunOff && dnsCfg.hijack ? 'warn' : ''}">${tunOff ? 'Works only in TUN — TUN is off now' : 'All DNS queries go to the servers above, even hard-coded ones'}</div></div>
        ${toggle(dnsCfg.hijack, "setDnsCfg('hijack',!dnsCfg.hijack)")}</div>
      <div class="set-row ${dnsCfg.fakeip ? 'stack' : ''}"><div class="am-head"><div class="set-label" style="flex:1">FakeIP<div class="set-hint">Faster, no DNS leaks; some apps (banks, games) break — add them below</div></div>
        ${toggle(dnsCfg.fakeip, "setDnsCfg('fakeip',!dnsCfg.fakeip)")}</div>
        ${dnsCfg.fakeip ? `<div class="set-hint">Real answers for</div>
        <div class="chip-input" id="fx-list">${dnsCfg.fakeipExclude.map((v, i) => `<span class="vchip">${esc(v)}<b onclick="removeFakeipExclude(${i})">×</b></span>`).join('')}
          <input id="fx-input" placeholder="*.example.com" onkeydown="if (event.key === 'Enter') addFakeipExclude(this)"></div>` : ''}</div>
    </div>`;
  const first = dnsServers[dnsActive()[0]];
  document.getElementById('dnsCardSub').textContent = first.name + ' · ' + dnsKind(first.addr) + (dnsCfg.fakeip ? ' · FakeIP' : '');
  document.getElementById('setDnsSub').textContent = dnsActive().length + ' on · ' + (dnsCfg.hijack ? 'hijack' : 'no hijack') + (dnsCfg.fakeip ? ' · FakeIP' : '');
}

/* ── Add / edit a DNS server (level 2 sheet) ── */
let dnsEditing = null, dnsDraftVia = 'vpn', dnsDraftPing = null;
function openDnsForm(id) {
  dnsEditing = id || null;
  const s = id ? dnsServers[id] : { name: '', addr: '', via: 'vpn' };
  document.getElementById('dfTitle').textContent = id ? 'Edit DNS server' : 'Add DNS server';
  document.getElementById('df-name').value = s.name;
  document.getElementById('df-addr').value = s.addr;
  document.getElementById('df-delete').style.display = id ? '' : 'none';
  dnsDraftPing = id ? dnsPing[id] : null;
  setDnsDraftVia(s.via);
  openSheet('dnsform');
}
function setDnsDraftVia(v) {
  dnsDraftVia = v;
  document.querySelectorAll('#df-via .chip').forEach(c => c.classList.toggle('active', c.dataset.v === v));
  renderDnsDraftPing();
}
function renderDnsDraftPing() { document.getElementById('df-ping').innerHTML = latMsHtml(dnsDraftPing); }
async function pingDnsDraft() {
  const addr = document.getElementById('df-addr').value.trim();
  if (!DNS_ADDR_RE.test(addr)) { toast('Enter a valid address first'); return; }
  dnsDraftPing = 'testing'; renderDnsDraftPing();
  await wait(400 + Math.random() * 400);
  dnsDraftPing = Math.round((addr === 'system' ? 12 : dnsDraftVia === 'vpn' ? 70 : 25) * (.8 + Math.random() * .6));
  renderDnsDraftPing();
}
function saveDnsForm() {
  const addr = document.getElementById('df-addr').value.trim();
  if (!DNS_ADDR_RE.test(addr)) { toast('Address: https://…, tls://…, quic://…, udp://…, an IP or system'); return; }
  const name = document.getElementById('df-name').value.trim() || addr.replace(/^\w+:\/\//, '').split('/')[0];
  if (dnsEditing) Object.assign(dnsServers[dnsEditing], { name, addr, via: dnsDraftVia });
  else {
    const id = 'dns' + (dnsSeq++);
    dnsServers[id] = { id, name, addr, via: dnsDraftVia, on: true };
    dnsOrder.push(id);
    if (dnsDraftPing != null) dnsPing[id] = dnsDraftPing;
  }
  closeSheet('dnsform');
  renderDns();
}
function deleteDnsServer() {
  const id = dnsEditing;
  if (dnsServers[id].on && dnsActive().length === 1) { toast('At least one DNS server must stay on'); return; }
  delete dnsServers[id]; delete dnsPing[id];
  dnsOrder = dnsOrder.filter(x => x !== id);
  closeSheet('dnsform');
  renderDns();
}

/* ══════════════════════ SETTINGS → CONNECTION ══════════════════════
   System proxy (also a switch on Home — to be dropped from Home on mobile) and the
   kill switch: while the VPN is down or reconnecting, all traffic is blocked. */
function renderConnSettings() {
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${click}"><div class="mini-toggle-thumb"></div></div>`;
  document.getElementById('conn-settings').innerHTML = `
    <div class="set-group">
      <div class="set-row"><div class="set-label" style="flex:1">System proxy<div class="set-hint">Apps that follow the OS proxy setting go through the core. Also on Home</div></div>
        ${toggle(connCfg.sysProxy, 'setSysProxy(!connCfg.sysProxy)')}</div>
      <div class="set-row"><div class="set-label" style="flex:1">Kill switch<div class="set-hint">While the VPN is down or reconnecting, block all traffic — nothing leaks out directly</div></div>
        ${toggle(connCfg.killSwitch, 'connCfg.killSwitch=!connCfg.killSwitch;renderConnSettings()')}</div>
    </div>
    <div class="set-group">
      <div class="set-row soon"><div class="set-label">TUN stack</div><span class="settings-value">gvisor</span><span class="soon-tag">soon</span></div>
      <div class="set-row soon"><div class="set-label">Latency test URL</div><span class="settings-value">auto</span><span class="soon-tag">soon</span></div>
    </div>`;
}
