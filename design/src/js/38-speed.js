/* ══════════════════════ SPEED TEST ══════════════════════
   Nodes → a server's ⋮ → Speed test. sing-box's own network quality test through that
   server (core: runtime.dart speedTest, a throwaway sing-box; Apple's test servers):
   idle latency first, then download and upload together (sing-box runs them at once, the
   progress steps interleave), the numbers growing as it measures; ~20 s. Closing the sheet
   stops it. SpeedCard in Flutter: a two-ring gauge (outer download, inner upload, log scale
   up to 1 Gbps), upload / latency / responsiveness under it, a progress line, Stop / Run again. */

const SPEED_SECONDS = 20;   // sing-box's default runtime; the progress line fills over it
const fmtMbps = bps => bps > 0 ? (bps / 1e6 >= 100 ? Math.round(bps / 1e6) : (bps / 1e6).toFixed(1)) : '—';
const speedFrac = bps => bps > 0 ? Math.min(1, Math.log10(1 + bps / 1e6) / 3) : 0;   // 1 → 1000 Mbps
// RPM = round trips a minute while the line is loaded (Apple's scale).
const rpmWord = rpm => rpm >= 1000 ? ['High', 'good'] : rpm >= 300 ? ['Medium', ''] : ['Low', 'bad'];
// sing-box / Go errors in plain words; the raw text stays under it.
function speedErrText(msg) {
  const m = String(msg || '');
  return /timeout|timed out|deadline/i.test(m) ? 'The server did not answer in time'
    : /refused/i.test(m) ? 'The server refused the connection'
    : /no such host|lookup/i.test(m) ? 'The server address does not resolve'
    : /reset|EOF|closed/i.test(m) ? 'The server dropped the connection'
    : /cannot be tested/i.test(m) ? m : 'The test could not finish';
}

// A 240° arc around (110,110), pathLength 100 so a fraction is a dash length.
const speedArc = r => `M${110 - r * .866} ${110 + r * .5}A${r} ${r} 0 1 1 ${110 + r * .866} ${110 + r * .5}`;

function speedShellHtml(n) {
  const ring = (cls, r) => `<path class="sg-track" d="${speedArc(r)}" pathLength="100"/><path class="sg-fill ${cls}" d="${speedArc(r)}" pathLength="100" stroke-dasharray="0 100"/>`;
  const stat = (key, label, unit) => `<div class="speed-stat" data-k="${key}"><div class="speed-stat-val"><b>—</b><span>${unit}</span></div><div class="speed-stat-label">${label}</div></div>`;
  return `<div class="speed-card" id="speed-card">
      <div class="speed-node"><span class="node-flag">${n.flag}</span><span class="speed-node-name">${esc(n.name)}</span><span class="node-proto">${protoLabel(n)}</span></div>
      <div class="speed-gauge">
        <svg viewBox="0 0 220 168">${ring('down', 96)}${ring('up', 80)}</svg>
        <div class="speed-center"><div class="speed-big">—</div><div class="speed-big-unit">Mbps</div><div class="speed-big-label"><i class="dot down"></i>Download</div></div>
      </div>
      <div class="speed-stats">${stat('up', '<i class="dot up"></i>Upload', 'Mbps')}${stat('lat', 'Latency', 'ms')}${stat('rpm', 'Responsiveness', 'RPM')}</div>
      <div class="speed-foot">
        <div class="speed-status"><span class="speed-status-text"></span><span class="speed-time"></span></div>
        <div class="speed-prog"><i></i></div>
        <div class="speed-err"></div>
      </div>
      <button class="btn-secondary speed-btn" onclick="speedButton()"></button>
    </div>`;
}

let speedRun = null;   // {sid, nid, ctl, p, t0}: the run the open SpeedCard shows

function openSpeedTest(sid, nid) {
  const n = findNode(sid, nid);
  if (!n) return;
  openActions('Speed test', speedShellHtml(n));
  sheetCloseHooks.actions = () => { stopSpeedTest(); delete sheetCloseHooks.actions; };
  runSpeedTest(sid, nid);
}

function runSpeedTest(sid, nid) {
  const n = findNode(sid, nid);
  stopSpeedTest();
  const run = speedRun = { sid, nid, ctl: new AbortController(), p: { phase: 0 }, t0: Date.now() };
  const show = p => { if (speedRun === run) { run.p = p; paintSpeed(run); } };
  show(run.p);
  backend.speedTest(n, show, run.ctl.signal)
    .then(() => { if (!run.p.final) show(Object.assign({}, run.p, { final: true, error: run.ctl.signal.aborted ? '' : 'The test ended without a result' })); })
    .catch(e => { if (!run.ctl.signal.aborted) show(Object.assign({}, run.p, { final: true, error: e.message })); });
}

// Stop the running test; [keep] leaves its numbers on the card as "Stopped".
function stopSpeedTest(keep) {
  const run = speedRun;
  if (!run || run.p.final) return;
  run.ctl.abort();
  if (keep) { run.p = Object.assign({}, run.p, { final: true, stopped: true }); paintSpeed(run); }
  else speedRun = null;
}
const speedButton = () => speedRun && !speedRun.p.final ? stopSpeedTest(true) : speedRun && runSpeedTest(speedRun.sid, speedRun.nid);

function paintSpeed(run) {
  const card = document.getElementById('speed-card');
  if (!card) { stopSpeedTest(); return; }   // the sheet shows something else now
  const p = run.p, err = p.final && p.error, done = p.final && !p.error && !p.stopped;
  const secs = Math.round((p.elapsed || Date.now() - run.t0) / 1000);
  card.classList.toggle('failed', !!err);
  card.classList.toggle('running', !p.final);
  const fill = (cls, bps) => {   // an empty ring hides: a round cap would draw a dot
    const el = card.querySelector('.sg-fill.' + cls);
    el.setAttribute('stroke-dasharray', `${speedFrac(bps) * 100} 100`);
    el.style.visibility = bps > 0 ? '' : 'hidden';
  };
  fill('down', p.down);
  fill('up', p.up);
  card.querySelector('.speed-big').textContent = fmtMbps(p.down);
  const stat = (k, val, extra) => {
    const el = card.querySelector(`.speed-stat[data-k="${k}"]`);
    el.querySelector('b').textContent = val;
    el.querySelector('.speed-stat-label').dataset.word = extra ? extra[0] : '';
    el.dataset.q = extra ? extra[1] : '';
  };
  stat('up', fmtMbps(p.up));
  stat('lat', p.latency > 0 ? p.latency : '—');
  stat('rpm', p.downRpm > 0 ? p.downRpm : '—', p.downRpm > 0 ? rpmWord(p.downRpm) : null);
  card.querySelector('.speed-status-text').textContent = err ? 'Test failed' : p.stopped ? 'Stopped'
    : done ? 'Done' : p.phase === 0 ? 'Measuring latency…' : 'Measuring speed…';
  card.querySelector('.speed-time').textContent = secs > 0 ? secs + ' s' : '';
  card.querySelector('.speed-prog i').style.width = (p.final ? (done ? 100 : Math.min(100, secs / SPEED_SECONDS * 100)) : Math.min(97, secs / SPEED_SECONDS * 100)) + '%';
  const why = err ? speedErrText(p.error) : '';
  card.querySelector('.speed-err').innerHTML = err ? `<b>${esc(why)}</b>${why !== p.error ? `<code>${esc(p.error)}</code>` : ''}<span>The server may be down right now. Ping it or try again later.</span>` : '';
  const btn = card.querySelector('.speed-btn');
  btn.innerHTML = p.final ? ICON.refresh + 'Run again' : ICON.close + 'Stop';
}
