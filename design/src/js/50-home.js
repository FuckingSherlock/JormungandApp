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
  connecting = true;
  renderConnState();
  backend.connect().then(() => { connected = true; }, e => toast(e.message))
    .then(() => { connecting = false; renderConnState(); if (!connected) refreshExitIp(); });
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
const connCfg = { sysProxy: false, killSwitch: false, port: 2080 };
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

