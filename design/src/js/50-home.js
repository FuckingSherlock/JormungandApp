/* ══════════════════════ MAIN TOGGLE ══════════════════════ */

let connected = true;
let connecting = false;
/* What the core reports beyond connected / not (status.recovering / down / blocking, see
   connect-model.md → dock states). recovering = sing-box restarts in the background: the dock
   looks exactly as Connected, nothing is shown. down = it did not come back in 30 s: the power
   button stays on (a tap disconnects = stop trying), the dock and an alert on Home say so.
   blocking = disconnected but Kill switch still holds the system proxy: a plaque on Home. */
const vpn = { recovering: null, down: null, blocking: null };
function renderConnState() {
  const btn = document.getElementById('powerBtn'), down = connected && !connecting && vpn.down;
  btn.classList.toggle('on', connected && !connecting);
  btn.classList.toggle('busy', connecting);
  btn.classList.toggle('down', !!down);
  const badge = document.getElementById('mainToggle');
  badge.classList.toggle('off', !connected || connecting);
  badge.classList.toggle('down', !!down);
  document.getElementById('connLabel').textContent = connecting ? 'Connecting…' : down ? 'VPN is down' : connected ? 'Connected' : 'Tap to connect';
  renderVpnAlert();
  renderExitIp();
  renderTraffic();
}
// The alert strip on Home and the red line in the dock. Buttons: Retry (try a restart now), and
// while our system proxy is still set, Disable sys proxy / Remove (POST /api/sysproxy/release).
// Never a Disconnect here — that is the power button.
function renderVpnAlert() {
  const el = document.getElementById('vpnAlert'), dd = document.getElementById('dockDown');
  const down = connected && !connecting ? vpn.down : null;
  const block = !connected && !connecting && vpn.blocking && vpn.blocking.proxy !== 'released' ? vpn.blocking : null;
  document.getElementById('dock').classList.toggle('down', !!down);
  dd.textContent = down ? 'VPN is down · ' + evDuration(Date.now() - down.since) + ' · retrying' : '';
  const svg = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>';
  const btn = (label, fn) => `<button class="src-error-retry" onclick="${fn}">${label}</button>`;
  if (down) {
    const held = down.proxy === 'kept';
    el.innerHTML = `<div class="src-error vpn-alert" data-kind="down">${svg}
      <div class="src-error-text"><div class="src-error-title">${held ? 'VPN is down — internet is blocked' : 'VPN is down — traffic goes direct'}</div>
      <div class="src-error-msg">${held ? 'The system proxy is kept so nothing leaks. ' : ''}Trying again in the background</div></div>
      <div class="vpn-alert-btns">${btn('Retry', 'vpnRetry()')}${held ? btn('Disable sys proxy', 'vpnReleaseProxy()') : ''}</div></div>`;
  } else if (block) {
    el.innerHTML = `<div class="src-error vpn-alert" data-kind="blocking">${svg}
      <div class="src-error-text"><div class="src-error-title">Kill switch: internet is blocked until you connect</div></div>
      <div class="vpn-alert-btns">${btn('Remove', 'vpnReleaseProxy()')}</div></div>`;
  } else el.innerHTML = '';
}
function vpnRetry() { backend.retry().then(() => renderConnState(), e => toast(e.message)); }
function vpnReleaseProxy() {
  backend.releaseSysProxy().then(() => {
    if (vpn.down) vpn.down.proxy = 'released';
    if (vpn.blocking) vpn.blocking.proxy = 'released';
    renderConnState();
  }, e => toast(e.message));
}
setInterval(() => { if (vpn.down) renderVpnAlert(); }, 15000);

/* ExitIpCard: where traffic leaves. Connected: the tunnel's exit, checked by the core
   through the tunnel after every (re)connect. Not connected: the device's own IP (label
   "Direct IP"), checked directly at launch and after a disconnect. A tap checks again.
   exitInfo: null = checking, {ip, country, city?} or {error}. The mock keeps fixed answers. */
let exitInfo = { ip: '91.108.4.12', country: 'DE', city: 'Frankfurt' };
const flagOf = cc => /^[A-Z]{2}$/i.test(cc || '') ? String.fromCodePoint(...[...cc.toUpperCase()].map(c => 0x1F1E6 + c.charCodeAt(0) - 65)) : '🌐';
function renderExitIp() {
  const e = connecting ? null : exitInfo;
  document.getElementById('exitLabel').textContent = connected && !connecting ? 'Exit IP' : 'Direct IP';
  const [flag, ip, loc] = e === null ? ['🌐', '…', 'Checking…']
    : e.error ? ['🌐', 'No answer', 'Tap to retry']
    : [flagOf(e.country), e.ip, [e.city, e.country].filter(Boolean).join(', ') || 'Location unknown'];
  document.getElementById('exitFlag').textContent = flag;
  document.getElementById('exitIp').textContent = ip;
  document.getElementById('exitLoc').textContent = loc;
}
function refreshExitIp() {
  if (connecting) return;
  exitInfo = null;
  renderExitIp();
  backend.exitIp().then(e => { exitInfo = e; renderExitIp(); });
}
function toggleMain() {
  if (connecting) return;
  if (connected) {
    connected = false;
    vpn.down = vpn.recovering = null;
    exitInfo = null;
    renderConnState();
    journal('user', 'disconnect', { action: 'disconnect' });
    backend.disconnect().then(refreshExitIp, e => toast(e.message));
    return;
  }
  if (nothingInAuto()) { alertNothingInAuto(); return; }
  if (catalogEmpty()) { toast(simpleMode() ? 'Add a subscription or a server first' : 'Create a profile first'); dockTap(); return; }
  connecting = true;
  renderConnState();
  backend.connect().then(() => { connected = true; vpn.blocking = null; journal('user', 'connect', { action: 'connect', entry: effectiveConnectId() }); }, e => toast(e.message))
    .then(() => { connecting = false; renderConnState(); if (!connected) refreshExitIp(); });
}

// First run (or everything deleted): nothing in this mode to connect. The dock says so and a
// tap goes to Nodes → + (with no sources a profile has nothing to use: the Simple tab).
const catalogEmpty = () => !connectOrder.some(entryVisible);
function dockTap() {
  if (!catalogEmpty()) { toggleRoute(); return; }
  switchTab('nodes');
  setNodesTab(simpleMode() || !sourceOrder.length ? 'simple' : 'profiles');
  openNodesAdd();
}

/* ══════════════════════ SEGMENTED CONTROLS ══════════════════════ */

const segState = { mode: 'proxy', route: 'rules', sys: 'off' };
const SEG_OPTS = { mode: ['tun', 'proxy'], route: ['global', 'rules'], sys: ['on', 'off'] };
// Two options only, so a tap anywhere on the control flips it.
function toggleSegment(group) {
  const next = SEG_OPTS[group].find(o => o !== segState[group]);
  if (group === 'sys') setSysProxy(next === 'on');
  else { setSegment(group, next); journal('user', group, { action: group, value: next }); }
}
function setSegment(group, value) {
  segState[group] = value;
  const index = SEG_OPTS[group].indexOf(value);
  SEG_OPTS[group].forEach(o => document.getElementById('seg-'+group+'-'+o).classList.toggle('active', o === value));
  // the Sys proxy pill moves sideways (On | Off under its name), the others up and down
  document.getElementById('pill-'+group).style.transform = (group === 'sys' ? 'translateX(' : 'translateY(') + (index === 1 ? '100%)' : '0)');
  document.getElementById('seg-sys').classList.toggle('sys-on', segState.sys === 'on');
  if (group === 'sys' && connCfg.sysProxy !== (value === 'on')) { connCfg.sysProxy = value === 'on'; renderConnSettings(); }
  if (group === 'mode') renderDns();   // the Hijack DNS note depends on TUN
}

/* Connection switches (Settings → Connection). System proxy is also the third switch on
   Home; on mobile it will leave Home (Android apps mostly ignore the system proxy). */
// port: the core's local HTTP + SOCKS5 proxy (127.0.0.1), where the system proxy points.
// testUrl: the latency test URL ('' = the core's default, gstatic), see 59-data.js.
// checkers: backup checks — tried when the test URL does not answer through a server; it
// passes traffic when any answers (the core's defaultCheckers).
// proxyAuth / proxyUser / proxyPass: an optional password on the port (default off = open, like Karing);
// the plan carries it as mixedAuth (95-live.js), the login and password sit in the UI snapshot, so
// backups hold them. Handling: 56-dns.js → Connection.
const DEFAULT_CHECKERS = ['https://cp.cloudflare.com/generate_204', 'https://www.gstatic.com/generate_204',
  'http://www.msftconnecttest.com/connecttest.txt', 'http://captive.apple.com/hotspot-detect.html'];
// Kill switch (rules.md §7): killOnDisconnect / killWhileClosed only count with killSwitch on (the latter also
// needs genCfg.launchAtStartup + connectOnLaunch); downProxy only with it off: the proxy when the VPN cannot recover.
const connCfg = { sysProxy: false, killSwitch: false, killOnDisconnect: false, killWhileClosed: false, downProxy: 'remove', port: 2080, proxyAuth: false, proxyUser: '', proxyPass: '', testUrl: '', checkers: DEFAULT_CHECKERS.slice(), tunStack: 'mixed', ipv6: false };
// tunStack: sing-box's TUN network stack ('mixed' | 'system' | 'gvisor'); the plan carries it (95-live.js), only TUN reads it.
// ipv6: off (default) = the TUN has no IPv6 address and the core's DNS answers no AAAA (TUN and proxy port alike); on = dual stack.
const PORT_RESERVED = [7788, 9090];   // jormd, the core's Clash API
function setProxyPort(input) {
  const v = Number(input.value.trim());
  if (/^\d+$/.test(input.value.trim()) && v >= 1024 && v <= 65535 && !PORT_RESERVED.includes(v)) connCfg.port = v;
  else toast(PORT_RESERVED.includes(v) ? 'Port ' + v + ' is taken by the app' : 'Enter a port 1024–65535');
  renderConnSettings();
}
function setSysProxy(on) {
  connCfg.sysProxy = on;
  setSegment('sys', on ? 'on' : 'off');
  renderConnSettings();
  journal('user', 'sysProxy', { action: 'sysProxy', on });
}


/* Live traffic: StatCards (speed, this session, connections) and the Live connections
   sheet, from backend.traffic() once a second while connected and the page is visible.
   Speeds are the core's counter deltas; each connection names the servers it really
   goes through, exit first ('proxy/<sid::nid>' / 'entry/<sid::nid>' tags, or 'direct').
   Not connected: speeds and connections are 0, the last session's totals stay. */
let traffic = null, trafficBusy = false;
function fmtRate(b) {
  const u = ['B/s', 'KB/s', 'MB/s', 'GB/s']; let i = 0;
  while (b >= 1000 && i < 3) { b /= 1024; i++; }
  return [i && b < 10 ? b.toFixed(1) : String(Math.round(b)), u[i]];
}
function fmtBytes(b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0;
  while (b >= 1000 && i < 4) { b /= 1024; i++; }
  return (i && b < 10 ? b.toFixed(2) : i && b < 100 ? b.toFixed(1) : Math.round(b)) + ' ' + u[i];
}
function renderTraffic() {
  const t = traffic, set = (id, v) => { document.getElementById(id).textContent = v; };
  if (!connected || t) {
    const [dv, du] = fmtRate(connected ? t.down : 0), [uv, uu] = fmtRate(connected ? t.up : 0);
    set('speedDown', dv); set('speedDownUnit', du); set('speedUp', uv); set('speedUpUnit', uu);
    set('connTotal', connected ? t.tcp + t.udp : 0); set('connTcp', connected ? t.tcp : 0); set('connUdp', connected ? t.udp : 0);
  }
  if (t && connected) { set('trafficDown', fmtBytes(t.downTotal)); set('trafficUp', fmtBytes(t.upTotal)); }
  if (document.getElementById('sh-connections').classList.contains('open')) renderLiveConns();
}
const trafficNode = t => {
  if (t && typeof t === 'object') return t;
  // the core's tags: route<i>/<sid>::<nid>, route<i>-entry/<sid>::<nid> (a chain's entry)
  const m = /^[^/]+\/(.+?)::(.+)$/.exec(t), s = m && sourcesData[m[1]];
  return s ? s.nodes.find(n => n.id === m[2]) : null;
};
const trafficVia = out => out.slice().reverse().map(t => {
  if (t === 'direct') return 'direct';
  const n = trafficNode(t);
  return n ? n.flag + ' ' + esc(n.name) : esc(t);
}).join(' → ') || '—';
const trafficAge = iso => { const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000 | 0); return s < 60 ? s + 's' : s < 3600 ? (s / 60 | 0) + 'm' : (s / 3600 | 0) + 'h'; };
// The Live connections sheet (list, filter, sort, pause, details): 76-conns.js.
setInterval(() => {
  if (!connected || connecting || document.hidden || trafficBusy) return;
  trafficBusy = true;
  backend.traffic().then(t => { traffic = t; renderTraffic(); }, () => {}).finally(() => { trafficBusy = false; });
}, 1000);
