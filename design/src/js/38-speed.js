/* ══════════════════════ SPEED TEST ══════════════════════
   Nodes → a server's ⋮ → Speed test. sing-box's own network quality test through that
   server (core: runtime.dart speedTest, a throwaway sing-box; Apple's test servers):
   latency first, then download, then upload, the numbers growing as it measures. Closing
   the sheet stops it. SpeedCard in Flutter. */

const SPEED_PHASES = ['Latency', 'Download', 'Upload', 'Done'];
const fmtMbps = bps => bps > 0 ? (bps / 1e6 >= 100 ? Math.round(bps / 1e6) : (bps / 1e6).toFixed(1)) : '—';

function speedCardHtml(p) {
  const ph = p.error ? 'Failed' : SPEED_PHASES[p.phase] || '';
  const cell = (label, val, unit, on) => `<div class="speed-cell${on ? ' on' : ''}"><div class="speed-val">${val}<span class="speed-unit">${unit}</span></div><div class="speed-label">${label}</div></div>`;
  return `<div class="speed-card" id="speed-card">
      <div class="speed-grid">
        ${cell('Download', fmtMbps(p.down), 'Mbps', p.phase === 1)}
        ${cell('Upload', fmtMbps(p.up), 'Mbps', p.phase === 2)}
        ${cell('Latency', p.latency > 0 ? p.latency : '—', 'ms', p.phase === 0)}
        ${cell('Responsiveness', p.downRpm > 0 ? p.downRpm : '—', 'RPM', false)}
      </div>
      <div class="speed-status${p.error ? ' err' : ''}">${p.final ? (p.error ? esc(p.error) : 'Done') : ph + '…'}</div>
    </div>`;
}

function openSpeedTest(sid, nid) {
  const n = findNode(sid, nid);
  if (!n) return;
  const ctl = new AbortController();
  let p = { phase: 0 };
  const draw = () => {
    const card = document.getElementById('speed-card');
    if (!card) { ctl.abort(); return; }   // the sheet shows something else now
    card.outerHTML = speedCardHtml(p);
  };
  openActions(n.flag + '  ' + n.name + ' · Speed test', speedCardHtml(p) +
    menuRow(ICON.refresh, 'Run again', `closeSheet('actions');openSpeedTest('${sid}','${nid}')`));
  sheetCloseHooks.actions = () => { ctl.abort(); delete sheetCloseHooks.actions; };
  backend.speedTest(n, x => { p = x; draw(); }, ctl.signal)
    .catch(e => { if (!ctl.signal.aborted) { p = Object.assign({}, p, { final: true, error: e.message }); draw(); } });
}
