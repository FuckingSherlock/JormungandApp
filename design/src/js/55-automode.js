/* ══════════════════════ AUTO MODE (Settings → Auto mode; Home card = a link to it) ══════════════════════
   How Auto picks and keeps a connection, in one place:
   - threshold: a server takes over from the current one only if it is this much faster
     (hysteresis, so Auto does not hop between servers with close pings); typed in ms;
   - checkEvery: how often the current route is re-pinged;
   - standby: how many next entries by priority are pinged together with the current
     one ("kept warm", 1–3), so a failover goes straight to a server known to work;
   - failAfter: timeouts in a row (1–4) before Auto leaves the current server;
   - pauseScreenOff: no checks while the screen is off (mobile battery);
   - subsEvery: the global subscription update period; a subscription's own period
     (Nodes → Edit subscription) wins, its default 'auto' follows this one.
   Auto itself is switched on / off by the Auto badge of the Servers / Profiles list.
   Flutter: AutoService (timer + PingService), settings in one AutoConfig. */

const autoCfg = { threshold: 50, checkEvery: 60, failAfter: 2, standby: 2, pauseScreenOff: true, subsEvery: 12 };
const AUTO_CHECK_EVERY = [30, 60, 120, 300, 600];
const AUTO_THRESHOLD_MAX = 1000;
const AUTO_FAIL_AFTER = [1, 4];

const fmtEvery = s => s < 60 ? s + ' s' : s < 3600 ? s / 60 + ' min' : s / 3600 + ' h';
const subsEveryText = h => h ? h + ' h' : 'off';

function setAutoCfg(key, val) {
  autoCfg[key] = val;
  renderAutoMode();
}
// The ms field: whole numbers 0…1000; anything else puts the old value back.
function setAutoThreshold(input) {
  const v = Number(input.value.trim());
  if (input.value.trim() !== '' && Number.isInteger(v) && v >= 0 && v <= AUTO_THRESHOLD_MAX) autoCfg.threshold = v;
  else toast('Enter 0–' + AUTO_THRESHOLD_MAX + ' ms');
  renderAutoMode();
}
const stepAutoFailAfter = d => setAutoCfg('failAfter', Math.min(AUTO_FAIL_AFTER[1], Math.max(AUTO_FAIL_AFTER[0], autoCfg.failAfter + d)));

// The Home card is a link: it opens Settings at the Auto mode section.
function openAutoMode() {
  switchTab('settings');
  const sc = document.querySelector('#view-settings > .scroll');
  sc.scrollTop += document.getElementById('auto-caption').getBoundingClientRect().top - sc.getBoundingClientRect().top;
}

function renderAutoMode() {
  const el = document.getElementById('auto-settings');
  const chips = (key, opts, fmt) => `<div class="chip-row">${opts.map(v =>
    `<div class="chip ${autoCfg[key] === v ? 'active' : ''}" onclick="setAutoCfg('${key}',${JSON.stringify(v)})">${fmt(v)}</div>`).join('')}</div>`;
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${click}"><div class="mini-toggle-thumb"></div></div>`;
  const [lo, hi] = AUTO_FAIL_AFTER, fa = autoCfg.failAfter;

  el.innerHTML = `
    <div class="set-group">
      <div class="set-row"><div class="set-label" style="flex:1">Switch to a faster server<div class="set-hint">Only if it is faster than the current one by at least this</div></div>
        <input class="set-input am-num" id="am-threshold" inputmode="numeric" value="${autoCfg.threshold}" onchange="setAutoThreshold(this)"><span class="am-unit">ms</span></div>
      <div class="set-row"><div class="set-label" style="flex:1">Check the connection every<div class="set-hint">Pings the current server and the kept-warm ones</div></div>
        <select class="set-select" id="am-every" onchange="setAutoCfg('checkEvery',Number(this.value))">${AUTO_CHECK_EVERY.map(v =>
          `<option value="${v}" ${autoCfg.checkEvery === v ? 'selected' : ''}>${fmtEvery(v)}</option>`).join('')}</select></div>
      <div class="set-row stack"><div><div class="set-label">Keep warm</div><div class="set-hint">Next entries by priority pinged with the current one — failover goes straight to a working one</div></div>
        ${chips('standby', [1, 2, 3], v => 'next ' + v)}</div>
      <div class="set-row"><div class="set-label" style="flex:1">Leave a server after<div class="set-hint">Timeouts in a row before Auto moves on</div></div>
        <div class="stepper" id="am-failafter">
          <button class="stepper-btn" onclick="stepAutoFailAfter(-1)" ${fa <= lo ? 'disabled' : ''}>‹</button>
          <span class="stepper-val">${fa}</span>
          <button class="stepper-btn" onclick="stepAutoFailAfter(1)" ${fa >= hi ? 'disabled' : ''}>›</button>
        </div></div>
      <div class="set-row"><div class="set-label" style="flex:1">Pause checks with the screen off<div class="set-hint">Saves battery; checks again on wake</div></div>${toggle(autoCfg.pauseScreenOff, "setAutoCfg('pauseScreenOff',!autoCfg.pauseScreenOff)")}</div>
    </div>

    <div class="am-label">Subscriptions<button class="help-btn" onclick="openHelp('subsupdate')" title="What is this?">?</button></div>
    <div class="set-group">
      <div class="set-row stack"><div class="set-label">Update all subscriptions every</div>
        ${chips('subsEvery', [6, 12, 24, 0], v => v ? v + ' h' : 'Off')}</div>
    </div>`;
}
