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

const segState = { mode: 'tun', route: 'rules' };
function setSegment(group, value, index) {
  segState[group] = value;
  const opts = group === 'mode' ? ['tun','proxy'] : ['global','rules'];
  opts.forEach(o => document.getElementById('seg-'+group+'-'+o).classList.toggle('active', o === value));
  document.getElementById('pill-'+group).style.transform = index === 1 ? 'translateY(100%)' : 'translateY(0)';
}
setSegment('mode', 'tun', 0);
setSegment('route', 'rules', 1);

