/* ══════════════════════ MAIN TOGGLE ══════════════════════ */

let connected = true;
let connecting = false;
function renderConnState() {
  const btn = document.getElementById('powerBtn');
  btn.classList.toggle('on', connected && !connecting);
  btn.classList.toggle('busy', connecting);
  document.getElementById('mainToggle').classList.toggle('off', !connected || connecting);
  document.getElementById('connLabel').textContent = connecting ? 'Connecting…' : connected ? 'Connected' : 'Tap to connect';
  renderExitIp();
  renderTraffic();
}

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
    exitInfo = null;
    renderConnState();
    backend.disconnect().then(refreshExitIp, e => toast(e.message));
    return;
  }
  if (nothingInAuto()) { alertNothingInAuto(); return; }
  if (catalogEmpty()) { toast(simpleMode() ? 'Add a subscription or a server first' : 'Create a profile first'); dockTap(); return; }
  connecting = true;
  renderConnState();
  backend.connect().then(() => { connected = true; }, e => toast(e.message))
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

const segState = { mode: 'tun', route: 'rules', sys: 'off' };
const SEG_OPTS = { mode: ['tun', 'proxy'], route: ['global', 'rules'], sys: ['on', 'off'] };
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
const connCfg = { sysProxy: false, killSwitch: false, port: 2080, testUrl: '' };
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
// LiveConnRow: host:port + TCP/UDP; the route (entry → exit) and rule; app, speed, bytes, age. Newest first.
// The filter matches host, app, rule and the servers a connection goes through; × closes one
// (sing-box drops it, the app usually opens a new one).
const connMatches = (c, q) => !q || [c.host, c.process, c.rule, trafficVia(c.out)].some(v => (v || '').toLowerCase().includes(q));
function renderLiveConns() {
  const all = connected && traffic ? traffic.conns.slice().sort((a, b) => Date.parse(b.start) - Date.parse(a.start)) : [];
  const q = document.getElementById('connFilter').value.trim().toLowerCase(), list = all.filter(c => connMatches(c, q));
  document.getElementById('connCloseAll').disabled = !all.length;
  document.getElementById('liveConnList').innerHTML = list.length ? list.map(c => `
    <div class="live-conn-row">
      <div class="live-conn-top"><span class="live-conn-host">${esc(c.host)}${c.port ? ':' + esc(c.port) : ''}</span><span class="live-conn-proto ${c.net === 'udp' ? 'udp' : 'tcp'}">${esc(c.net.toUpperCase())}</span><button class="live-conn-close" title="Close connection" data-id="${esc(c.id)}" onclick="closeLiveConn(this.dataset.id)">×</button></div>
      <div class="live-conn-meta">${trafficVia(c.out)}${c.rule ? ' · ' + esc(c.rule) : ''}</div>
      <div class="live-conn-meta dim">${c.process ? esc(c.process.split(/[\\/]/).pop()) + ' · ' : ''}↓ ${fmtRate(c.downRate).join(' ')} ↑ ${fmtRate(c.upRate).join(' ')} · ${fmtBytes(c.down + c.up)} · ${trafficAge(c.start)}</div>
    </div>`).join('') : `<div class="live-conn-empty">${!connected ? 'Not connected' : all.length ? 'Nothing matches' : 'No open connections'}</div>`;
}
function closeLiveConn(id) {
  backend.closeConn(id).then(() => {
    if (traffic) traffic.conns = id ? traffic.conns.filter(c => c.id !== id) : [];
    renderLiveConns();
    if (!id) toast('All connections closed');
  }, e => toast('Not closed: ' + e.message));
}
setInterval(() => {
  if (!connected || connecting || document.hidden || trafficBusy) return;
  trafficBusy = true;
  backend.traffic().then(t => { traffic = t; renderTraffic(); }, () => {}).finally(() => { trafficBusy = false; });
}, 1000);
