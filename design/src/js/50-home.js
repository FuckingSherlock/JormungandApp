/* ══════════════════════ MAIN TOGGLE ══════════════════════ */

let connected = true;
let connecting = false;
function renderConnState() {
  const btn = document.getElementById('powerBtn');
  btn.classList.toggle('on', connected && !connecting);
  btn.classList.toggle('busy', connecting);
  document.getElementById('mainToggle').classList.toggle('off', !connected || connecting);
  document.getElementById('connLabel').textContent = connecting ? 'Connecting…' : connected ? 'Connected' : 'Tap to connect';
}
function toggleMain() {
  if (connecting) return;
  if (connected) {
    connected = false;
    renderConnState();
    return;
  }
  connecting = true;
  renderConnState();
  setTimeout(() => { connecting = false; connected = true; renderConnState(); }, 1100);
}

/* ══════════════════════ SEGMENTED CONTROLS ══════════════════════ */

const segState = { mode: 'tun', route: 'rules', sys: 'off' };
const SEG_OPTS = { mode: ['tun', 'proxy'], route: ['global', 'rules'], sys: ['on', 'off'] };
function setSegment(group, value) {
  segState[group] = value;
  const index = SEG_OPTS[group].indexOf(value);
  SEG_OPTS[group].forEach(o => document.getElementById('seg-'+group+'-'+o).classList.toggle('active', o === value));
  document.getElementById('pill-'+group).style.transform = index === 1 ? 'translateY(100%)' : 'translateY(0)';
  document.getElementById('seg-sys').classList.toggle('sys-on', segState.sys === 'on');
  if (group === 'sys' && connCfg.sysProxy !== (value === 'on')) { connCfg.sysProxy = value === 'on'; renderConnSettings(); }
  if (group === 'mode') renderDns();   // the Hijack DNS note depends on TUN
}

/* Connection switches (Settings → Connection). System proxy is also the third switch on
   Home; on mobile it will leave Home (Android apps mostly ignore the system proxy). */
const connCfg = { sysProxy: false, killSwitch: false };
function setSysProxy(on) {
  connCfg.sysProxy = on;
  setSegment('sys', on ? 'on' : 'off');
  renderConnSettings();
}

