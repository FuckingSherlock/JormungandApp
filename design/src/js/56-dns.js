/* ══════════════════════ DNS (Settings → DNS sheet; the Home DNS card opens it over Home) ══════════════════════
   - Global DNS: a list of servers. Ticked = in use, order = priority: the first ticked one
     answers; if it stops answering, the next ticked one takes over (the core checks them
     and switches sing-box's clash mode itself — sing-box has no DNS fallback of its own),
     and back when a higher one recovers. "Switch automatically" (dnsCfg.auto, on by default)
     turns that off: then the first ticked server stays, whatever it does. While connected
     the list marks the server in use and the ones that do not answer (dnsHealth: the core's
     status.dns; the mockup derives it from the pings).
   - Each server: address (system | udp:// | tcp:// | tls:// | https:// | quic:// | bare IP)
     and "via": Direct or VPN (the server's detour).
   - Rules with DNS "Auto" use the first ticked server whose "via" matches the rule's
     action: Direct → a direct server, VPN → a server via VPN (see docs/rules.md).
   - Resolve for IP rules (dnsCfg.resolve: 'auto' | 'off' | a server id): through the proxy port a
     site arrives as a name, so IP conditions (IP / CIDR, local networks, GeoIP) see nothing unless
     the core resolves the name first. Auto = the first ticked server via VPN (no leak to the
     provider's DNS); a server that is unticked or deleted counts as Auto. TUN has the address
     already. A rule can opt out (rule form: "IP conditions only in TUN").
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
  hijack: true, fakeip: false, auto: true, resolve: 'auto',
  fakeipExclude: ['*.sberbank.ru', '*.tinkoff.ru', '*.gosuslugi.ru', '*.steamserver.net', '*.xboxlive.com', 'time.*.com'],
};
const dnsPing = {};   // id -> ms | -1 | 'testing'
let liveDns = null;   // status.dns while connected: { active, auto, servers: [{ id, ok, ms }] } (94-live-auto.js)
let dnsMockActive = null;

// The server in use and the ones that fail, while connected: the core's answer; the mockup
// takes the first server that does not fail its ping (the first ticked one when Switch
// automatically is off).
function dnsHealth() {
  if (window.JORMD) {
    if (!connected || !liveDns || !liveDns.active) return null;
    return { active: liveDns.active, failed: new Set((liveDns.servers || []).filter(s => s.ok === false).map(s => s.id)) };
  }
  const act = dnsActive();
  if (!connected || !act.length) return null;
  const failed = new Set(act.filter(id => dnsPing[id] === -1));
  return { active: (dnsCfg.auto && act.find(id => !failed.has(id))) || act[0], failed };
}
// The mockup's core writes the journal entry when the server in use changes.
function dnsMockSync() {
  const h = window.JORMD ? null : dnsHealth();
  if (!h) { dnsMockActive = null; return; }
  const from = dnsMockActive;
  dnsMockActive = h.active;
  if (!from || from === h.active || !dnsServers[from]) return;
  const reason = h.failed.has(from) ? 'failover' : dnsCfg.auto ? 'back' : 'off';
  mockEventAdd('dns', 'switched', 'info', { from, to: h.active, reason }, { own: reason === 'off', raw: 'dns: ' + from + ' → ' + h.active + ' (' + reason + ')' });
}

const DNS_ADDR_RE = /^(system|(udp|tcp|tls|https|quic):\/\/[^\s/]+(\/\S*)?|\d{1,3}(\.\d{1,3}){3}(:\d+)?)$/;
function dnsKind(addr) {
  if (addr === 'system') return 'System';
  const m = /^(\w+):\/\//.exec(addr);
  return { https: 'DoH', tls: 'DoT', quic: 'DoQ', tcp: 'TCP', udp: 'UDP' }[m ? m[1] : 'udp'];
}
const dnsActive = () => dnsOrder.filter(id => dnsServers[id].on);
// The server a rule's DNS "Auto" resolves to: first ticked one with the matching route.
const dnsAutoFor = via => dnsActive().map(id => dnsServers[id]).find(s => s.via === via);
// "Resolve for IP rules" as it works now: 'off', a ticked server's id, or 'auto'.
const dnsResolveEff = () => dnsCfg.resolve === 'off' ? 'off' : dnsActive().includes(dnsCfg.resolve) ? dnsCfg.resolve : 'auto';
// The server that resolves (null = off, or Auto with no server via VPN: the first one in use then).
const dnsResolveServer = () => { const e = dnsResolveEff(); return e === 'off' ? null : e === 'auto' ? dnsAutoFor('vpn') || null : dnsServers[e]; };
// For the rule form's hint: 'off' / 'via Cloudflare'.
const dnsResolveText = () => { const s = dnsResolveServer(); return dnsResolveEff() === 'off' ? 'off' : 'via ' + (s ? s.name : dnsServers[dnsActive()[0]].name); };

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
function setDnsCfg(key, val) {
  dnsCfg[key] = val;
  // Switch automatically: the core takes it at once while connected (POST /api/dns/auto), no reconnect
  if (key === 'auto' && connected) backend.dnsAuto(val).catch(e => toast(e.message));
  renderDns();
}
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
// focus = a row's data-key to scroll to and flash (the rule form's link to "Resolve for IP rules").
function openDnsSettings(focus) {
  openSheet('setdns');
  dnsOrder.filter(id => dnsServers[id].on && dnsPing[id] === undefined).forEach(pingDns);
  if (typeof focus !== 'string') return;
  requestAnimationFrame(() => {
    const row = document.querySelector('#dns-settings [data-key="' + focus + '"]');
    if (!row) return;
    row.scrollIntoView({ block: 'center' });
    row.classList.add('hit');
    setTimeout(() => row.classList.remove('hit'), 2600);
  });
}
function renderDns() {
  const el = document.getElementById('dns-settings');
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${click}"><div class="mini-toggle-thumb"></div></div>`;
  dnsMockSync();   // every change (a ping, a tick, the order, Switch automatically) passes here
  const health = dnsHealth();
  const rows = dnsOrder.map((id, i) => {
    const s = dnsServers[id], rank = s.on ? dnsActive().indexOf(id) + 1 : '';
    const state = !health || !s.on ? '' : health.failed.has(id) ? '<span class="dns-state fail">No answer</span>' : health.active === id ? '<span class="dns-state use">In use</span>' : '';
    return `<div class="set-row dns-row ${s.on ? '' : 'off'} ${state ? (health.failed.has(id) ? 'failed' : 'in-use') : ''}" data-id="${id}">
      <div class="drag-handle cc-grip" onpointerdown="startDnsDrag(event,'${id}')">${GRIP_SVG}</div>
      <span class="cc-rank">${rank}</span>
      <div class="sub-checkbox ${s.on ? 'checked' : ''}" onclick="toggleDnsOn('${id}')"></div>
      <div class="dns-main" onclick="openDnsForm('${id}')">
        <div class="dns-name">${esc(s.name)}<span class="via-tag ${s.via}">${s.via === 'vpn' ? 'VPN' : 'Direct'}</span>${state}</div>
        <div class="dns-addr">${esc(s.addr)}</div>
      </div>
      <span onclick="pingDns('${id}')">${latMsHtml(dnsPing[id])}</span>
    </div>`;
  }).join('');
  const tunOff = segState.mode !== 'tun';
  const resolveEff = dnsResolveEff(), autoServer = dnsAutoFor('vpn');
  const resolveOpts = [['off', 'Off'], ['auto', 'Auto · ' + (autoServer ? autoServer.name : 'no VPN server')],
    ...dnsActive().map(id => [id, dnsServers[id].name + (dnsServers[id].via === 'vpn' ? '' : ' · Direct')])];
  const resolveWarn = resolveEff === 'off' ? false : resolveEff === 'auto' ? !autoServer : dnsServers[resolveEff].via !== 'vpn';
  const resolveHint = resolveEff === 'off' ? 'IP conditions (IP, CIDR, local networks, GeoIP) match a site opened by name only in TUN'
    : resolveWarn ? 'This query leaves outside the tunnel' + (resolveEff === 'auto' ? ': no DNS server via VPN is on, the first one in use resolves' : ', through a direct server')
    : 'Sites opened by name are resolved here so IP conditions see the address. System proxy only, TUN has it already';
  el.innerHTML = `
    <div class="am-label">Global DNS<button class="help-btn" onclick="openHelp('dns')" title="What is this?">?</button>
      <button class="am-link" onclick="pingAllDns()">Ping all</button></div>
    <div class="set-group" id="dns-list">${rows}
      <div class="node-add" onclick="openDnsForm()"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>Add DNS server</div>
    </div>
    <div class="set-group">
      <div class="set-row" data-key="dnsAuto"><div class="set-label" style="flex:1">Switch automatically<div class="set-hint">${dnsCfg.auto ? 'A server that stops answering is replaced by the next one; the higher one takes over again when it recovers' : 'The first server stays in use even when it does not answer'}</div></div>
        ${toggle(dnsCfg.auto, "setDnsCfg('auto',!dnsCfg.auto)")}</div>
    </div>
    <div class="am-label">Through the proxy port</div>
    <div class="set-group">
      <div class="set-row" data-key="dnsResolve"><div class="set-label" style="flex:1">Resolve for IP rules<div class="set-hint ${resolveWarn ? 'warn' : ''}">${resolveHint}</div></div>
        <select class="set-select" id="dns-resolve" style="max-width:46%" onchange="setDnsCfg('resolve',this.value)">${resolveOpts.map(([v, l]) =>
          `<option value="${v}" ${resolveEff === v ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></div>
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
const killClosedOk = () => genCfg.launchAtStartup && genCfg.connectOnLaunch;
// The four kill switch settings as the core reads them (connect body and POST /api/killswitch): the sub-options only count with their conditions.
function killPlan() {
  const kill = connCfg.killSwitch;
  return { killSwitch: kill, killOnDisconnect: kill && connCfg.killOnDisconnect, killWhileClosed: kill && connCfg.killWhileClosed && !!killClosedOk(), downProxy: connCfg.downProxy };
}
// Any of them (or autostart / autoconnect, which gate killWhileClosed) changed while connected or down: the core takes it live.
let killSig;
function syncKillSettings() {
  const sig = JSON.stringify(killPlan());
  if (killSig === undefined) { killSig = sig; return; }
  if (sig === killSig) return;
  killSig = sig;
  // connected / down, or a block after disconnect / while closed: turning its setting off lifts it
  if (connected || vpn.blocking) backend.killSettings(killPlan()).catch(e => toast(e.message));
}
function offerClosedKill() {
  const close = "closeSheet('actions');";
  openActions('Also while the app is closed', `<div class="menu-note">Keeping the proxy while the app is closed only makes sense if the app starts with the computer and connects by itself: otherwise the internet stays blocked until you start it by hand. Turn on <b>Launch at startup</b> and <b>Connect on launch</b>?</div>`
    + menuRow(ICON.check, 'Turn them on', close + "genCfg.launchAtStartup=genCfg.connectOnLaunch=true;connCfg.killWhileClosed=true;renderConnSettings();renderGeneral()")
    + menuRow(ICON.close, 'Cancel', close));
}
/* Turning the kill switch off while it protects something (connected, down, or a block after
   disconnect) asks first; turning it on, or off while idle, does not. */
function toggleKillSwitch() {
  const flip = () => { connCfg.killSwitch = !connCfg.killSwitch; renderConnSettings(); };
  if (!connCfg.killSwitch || !(connected || vpn.blocking)) { flip(); return; }
  const close = "closeSheet('actions');";
  const what = vpn.blocking ? 'The internet is unblocked now: the system proxy is removed.'
    : vpn.down ? 'The VPN is down right now: ' + (connCfg.downProxy === 'keep' ? 'the proxy stays, but nothing guarantees it any more.' : 'the system proxy is removed and your traffic goes direct at once.')
    : 'The connection stays, but if the VPN goes down, ' + (connCfg.downProxy === 'keep' ? 'nothing guarantees the block any more.' : 'your traffic goes direct (If the VPN cannot recover: Remove proxy).');
  openActions('Turn the kill switch off?', `<div class="menu-note">${what}</div>`
    + menuRow(ICON.check, 'Turn it off', close + 'connCfg.killSwitch=false;renderConnSettings()')
    + menuRow(ICON.close, 'Keep it on', close));
}
/* Password on the proxy port. Off (default): open, any program on this PC can use it. On: a login
   and password are generated, both editable; the plan sends them as mixedAuth and, with the system
   proxy on, the core opens a second port without a password for it (Windows cannot send one). */
const PROXY_LOGIN_MAX = 64, PROXY_PASS_MIN = 4, PROXY_PASS_MAX = 128;
function randomToken(n, alphabet) {
  const a = new Uint32Array(n);
  crypto.getRandomValues(a);
  return Array.from(a, v => alphabet[v % alphabet.length]).join('');
}
const newProxyLogin = () => randomToken(8, 'abcdefghjkmnpqrstuvwxyz23456789');
const newProxySecret = () => randomToken(20, 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789');
function toggleProxyAuth() {
  connCfg.proxyAuth = !connCfg.proxyAuth;
  // turned on: fresh ones; off: nothing left behind in the snapshot / backups
  connCfg.proxyUser = connCfg.proxyAuth ? newProxyLogin() : '';
  connCfg.proxyPass = connCfg.proxyAuth ? newProxySecret() : '';
  renderConnSettings();
}
function newProxyPassword() {
  connCfg.proxyPass = newProxySecret();
  renderConnSettings();
  toast('New password set — programs using the old one need it');
}
// null = fine, else the reason
function proxyCredError(which, v) {
  if (!v) return (which === 'user' ? 'Login' : 'Password') + ' must not be empty';
  if (/\s/.test(v)) return (which === 'user' ? 'Login' : 'Password') + ' cannot contain spaces';
  if (which === 'user') {
    if (v.includes(':')) return "Login cannot contain ':'";
    if (v.length > PROXY_LOGIN_MAX) return 'Login is too long (max ' + PROXY_LOGIN_MAX + ')';
  } else {
    if (v.length < PROXY_PASS_MIN) return 'Password is too short (min ' + PROXY_PASS_MIN + ')';
    if (v.length > PROXY_PASS_MAX) return 'Password is too long (max ' + PROXY_PASS_MAX + ')';
  }
  return null;
}
function setProxyCred(which, input) {
  const v = input.value, err = proxyCredError(which, v);
  if (err) toast(err);
  else connCfg[which === 'user' ? 'proxyUser' : 'proxyPass'] = v;
  renderConnSettings();
}
// what a program is told to use: socks5://login:password@127.0.0.1:port or http://…; the login and password percent-encoded
const proxyUrl = scheme => scheme + '://' + encodeURIComponent(connCfg.proxyUser) + ':' + encodeURIComponent(connCfg.proxyPass) + '@127.0.0.1:' + connCfg.port;
const copyProxyUrl = scheme => copyText(proxyUrl(scheme), scheme === 'socks5' ? 'SOCKS5 address' : 'HTTP address');

function renderConnSettings() {
  const closedOk = killClosedOk();
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${click}"><div class="mini-toggle-thumb"></div></div>`;
  document.getElementById('conn-settings').innerHTML = `
    <div class="set-group">
      <div class="set-row"><div class="set-label" style="flex:1">System proxy<div class="set-hint">Apps that follow the OS proxy setting go through the core. Also on Home</div></div>
        ${toggle(connCfg.sysProxy, 'setSysProxy(!connCfg.sysProxy)')}</div>
      <div class="set-row"><div class="set-label" style="flex:1">Proxy port<div class="set-hint">HTTP + SOCKS5 on 127.0.0.1 — ${connCfg.proxyAuth ? 'set it by hand in other apps, with the login below' : 'the system proxy points here; set it by hand in other apps'}</div></div>
        <input class="set-input am-num port-num" id="conn-port" inputmode="numeric" value="${connCfg.port}" onchange="setProxyPort(this)"></div>
      <div class="set-row" data-key="proxyAuth"><div class="set-label" style="flex:1">Password<div class="set-hint">${connCfg.proxyAuth ? 'The port asks for this login' + (connCfg.sysProxy ? '. The system proxy uses its own port without one: Windows cannot send a password' : '') : 'Off: any program on this PC can use the port'}</div></div>
        ${toggle(connCfg.proxyAuth, 'toggleProxyAuth()')}</div>
      ${connCfg.proxyAuth ? `
      <div class="set-row set-sub" data-key="proxyUser"><div class="set-label" style="flex:0 0 auto">Login</div>
        <input class="set-input am-num auth-in" id="conn-user" spellcheck="false" autocomplete="off" autocapitalize="off" value="${esc(connCfg.proxyUser)}" onchange="setProxyCred('user',this)"></div>
      <div class="set-row set-sub" data-key="proxyPass"><div class="set-label" style="flex:0 0 auto">Password</div>
        <input class="set-input am-num auth-in" id="conn-pass" spellcheck="false" autocomplete="off" autocapitalize="off" value="${esc(connCfg.proxyPass)}" onchange="setProxyCred('pass',this)"></div>
      <div class="set-row set-sub stack" data-key="proxyCopy">
        <div class="chip-row">
          <div class="chip" id="conn-copy-socks" onclick="copyProxyUrl('socks5')">Copy SOCKS5</div>
          <div class="chip" id="conn-copy-http" onclick="copyProxyUrl('http')">Copy HTTP</div>
          <div class="chip" id="conn-newpass" onclick="newProxyPassword()">New password</div>
        </div>
        <div class="auth-url" id="conn-auth-url">${esc(proxyUrl('socks5'))}</div></div>` : ''}
      <div class="set-row" data-key="killSwitch"><div class="set-label" style="flex:1">Kill switch<div class="set-hint">Blocks traffic when the VPN is down. Works for apps that use the system proxy; full block needs TUN.</div></div>
        ${toggle(connCfg.killSwitch, 'toggleKillSwitch()')}</div>
      ${connCfg.killSwitch ? `
      <div class="set-row set-sub" data-key="killOnDisconnect"><div class="set-label" style="flex:1">Also after I disconnect<div class="set-hint">Internet stays blocked until you connect again or tap Remove on Home</div></div>
        ${toggle(connCfg.killOnDisconnect, 'connCfg.killOnDisconnect=!connCfg.killOnDisconnect;renderConnSettings()')}</div>
      <div class="set-row set-sub ${closedOk ? '' : 'dim'}" data-key="killWhileClosed"${closedOk ? '' : ' onclick="offerClosedKill()"'}><div class="set-label" style="flex:1">Also while the app is closed<div class="set-hint">${closedOk ? 'The proxy stays set when the app is closed, so nothing leaks before it starts again' : 'Needs Launch at startup and Connect on launch — tap to turn them on'}</div></div>
        ${toggle(closedOk && connCfg.killWhileClosed, closedOk ? 'connCfg.killWhileClosed=!connCfg.killWhileClosed;renderConnSettings()' : '')}</div>`
      : `
      <div class="set-row" data-key="downProxy" style="flex-direction:column;align-items:stretch;gap:10px">
        <div class="set-label">If the VPN cannot recover<div class="set-hint">${connCfg.downProxy === 'keep' ? 'Keep it: the proxy stays set, so apps that use it have no internet until the VPN is back' : 'Remove: traffic goes direct until the VPN is back'}</div></div>
        <div class="chip-row" style="padding:0">
          <div class="chip ${connCfg.downProxy !== 'keep' ? 'active' : ''}" onclick="connCfg.downProxy='remove';renderConnSettings()">Remove proxy</div>
          <div class="chip ${connCfg.downProxy === 'keep' ? 'active' : ''}" onclick="connCfg.downProxy='keep';renderConnSettings()">Keep it</div>
        </div></div>`}
    </div>
    <div class="set-group">
      <div class="set-row soon"><div class="set-label">TUN stack</div><span class="settings-value">gvisor</span><span class="soon-tag">soon</span></div>
      <div class="set-row"><div class="set-label" style="flex:1">Latency test URL<div class="set-hint">The address ping and Fastest time; pick one that answers fast from here</div></div>
        <button class="set-value" id="conn-testurl" onclick="openTestUrlPicker()">${testUrlLabel()}${CHEVRON_R}</button></div>
      <div class="set-row"><div class="set-label" style="flex:1">Backup checks<div class="set-hint">When the test URL does not answer through a server, these are tried; the server works if any answers</div></div>
        <button class="set-value" id="conn-checkers" onclick="openCheckersPicker()">${connCfg.checkers.length ? connCfg.checkers.length : 'Off'}${CHEVRON_R}</button></div>
    </div>`;
  syncKillSettings();
}
