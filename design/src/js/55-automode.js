/* ══════════════════════ AUTO MODE (Home card + Settings → Auto mode) ══════════════════════
   Everything about how Auto picks and keeps a connection, in one place:
   - threshold: a server takes over from the current one only if it is this much faster
     (hysteresis, so Auto does not hop between servers with close pings);
   - checkEvery: how often the current route is re-pinged;
   - failAfter: timeouts in a row before Auto leaves the current server;
   - standby: how many next entries by priority are pinged together with the current
     one ("kept warm"), so a failover goes straight to a server known to work;
   - pauseScreenOff: no checks while the screen is off (mobile battery);
   - subsEvery: the global subscription update period; a subscription's own period
     (Nodes → Edit subscription) wins, its default 'auto' follows this one.
   Flutter: AutoService (timer + PingService), settings in one AutoConfig. */

const autoCfg = { threshold: 50, checkEvery: 60, failAfter: 2, standby: 2, pauseScreenOff: true, subsEvery: 12 };
let autoLastCheck = Date.now() - 40e3;

const fmtEvery = s => s < 60 ? s + ' s' : s < 3600 ? s / 60 + ' min' : s / 3600 + ' h';
const subsEveryText = h => h ? h + ' h' : 'off';

// The servers an entry connects through right now (a chain: entry + exit), and their ping.
function routeNodes(id) {
  if (chainsData[id]) { const c = chainsData[id]; return [chainEntryNode(c), chainExitNode(c)]; }
  return [unitNode(id)];
}
function routeMs(id) {
  const ns = routeNodes(id);
  return ns.every(n => n && isAlive(n)) ? ns.reduce((sum, n) => sum + ping(n), 0) : null;
}
// Next entries Auto would fall back to (in priority order), kept warm by the checks.
function standbyIds() {
  const cur = effectiveConnectId();
  return visibleOrder().filter(id => id !== cur && connectEntry(id).inAuto).slice(0, autoCfg.standby);
}

function autoCheckNow() {
  const ids = [effectiveConnectId()].concat(autoConnect ? standbyIds() : []);
  autoLastCheck = Date.now();
  pingNodes(ids.flatMap(routeNodes).filter(Boolean));
}

function renderAutoCard() {
  const id = effectiveConnectId(), ms = routeMs(id);
  document.getElementById('autoCardToggle').classList.toggle('on', autoConnect);
  document.getElementById('autoCardSub').textContent = autoConnect
    ? `First working in ${simpleMode() ? 'Servers' : 'Profiles'} order`
    : `Manual — pinned to ${connectEntry(id) ? connectEntry(id).name : '—'}`;
  const stat = (label, val, cls = '') => `<div class="auto-stat"><div class="auto-stat-val ${cls}">${val}</div><div class="auto-stat-label">${label}</div></div>`;
  document.getElementById('autoCardStats').innerHTML =
    stat('now', ms == null ? '—' : ms + ' ms', ms == null ? 'bad' : ms < 150 ? 'good' : ms < 400 ? 'mid' : 'bad')
    + stat('switch at', '−' + autoCfg.threshold + ' ms')
    + stat('check', fmtEvery(autoCfg.checkEvery))
    + stat('subs', subsEveryText(autoCfg.subsEvery));
}

// The Home card is a shortcut: it opens Settings at the Auto mode section.
function openAutoMode() {
  renderAutoMode();
  switchTab('settings');
  const sc = document.querySelector('#view-settings > .scroll');
  sc.scrollTop += document.getElementById('auto-caption').getBoundingClientRect().top - sc.getBoundingClientRect().top;
}

function setAutoCfg(key, val) {
  autoCfg[key] = val;
  renderAutoMode();
  renderAutoCard();
}

function renderAutoMode() {
  const el = document.getElementById('auto-settings');
  const id = effectiveConnectId(), e = connectEntry(id);
  const chips = (key, opts, fmt) => `<div class="chip-row">${opts.map(v =>
    `<div class="chip ${autoCfg[key] === v ? 'active' : ''}" onclick="setAutoCfg('${key}',${JSON.stringify(v)})">${fmt(v)}</div>`).join('')}</div>`;
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="${click}"><div class="mini-toggle-thumb"></div></div>`;
  const route = rid => routeNodes(rid).map(n => n ? `<span class="dock-node">${n.flag} ${esc(n.name)}</span>` : '<span class="dock-node none">no working node</span>')
    .join('<span class="dock-arrow">→</span>');
  const standby = standbyIds();
  const own = sourceOrder.filter(sid => sourcesData[sid].kind === 'sub' && sourcesData[sid].updateInterval !== 'auto');

  el.innerHTML = `
    <div class="am-now">
      <div class="am-now-main">
        <div class="card-label" style="margin-bottom:2px">${autoConnect ? 'Now · auto' : 'Now · manual'}</div>
        <div class="am-now-name">${e ? esc(e.name) : '—'}</div>
        <div class="dock-route">${e ? route(id) : ''}</div>
      </div>
      <div class="am-now-ms">${latMsHtml(routeMs(id))}<div class="am-checked">checked ${timeAgo(autoLastCheck)}</div></div>
    </div>
    <div class="am-actions">
      <button class="btn-secondary" onclick="autoCheckNow()">${ICON.bolt}Check now</button>
      <button class="btn-secondary" onclick="openProfiles()">Priority list</button>
    </div>

    <div class="am-label">Standby · next by priority</div>
    <div class="am-standby">${!autoConnect ? '<div class="route-empty">Manual — no failover, standby is idle</div>'
      : !autoCfg.standby ? '<div class="route-empty">Off — only the current server is checked</div>'
      : standby.map((sid, i) => `<div class="am-sb-row"><span class="cc-rank">${i + 1}</span><div class="am-sb-main"><div class="am-sb-name">${esc(connectEntry(sid).name)}${chainsData[sid] ? '<span class="conn-tag">chain</span>' : ''}</div><div class="dock-route">${route(sid)}</div></div>${latMsHtml(routeMs(sid))}</div>`).join('')
        || '<div class="route-empty">Nothing else in Auto</div>'}</div>

    <div class="set-group">
      <div class="set-row"><div class="set-label">Auto mode<div class="set-hint">Off = Manual: stays on the entry you tapped</div></div>${toggle(autoConnect, 'setAutoConnect(!autoConnect);renderAutoMode()')}</div>
      <div class="set-row stack"><div><div class="set-label">Switch to a faster server</div><div class="set-hint">Only if it is faster than the current one by at least this</div></div>
        ${chips('threshold', [20, 50, 100, 200], v => v + ' ms')}</div>
      <div class="set-row stack"><div><div class="set-label">Check the connection every</div><div class="set-hint">Pings the current route${autoCfg.standby ? ` and ${autoCfg.standby} standby` : ''}</div></div>
        ${chips('checkEvery', [30, 60, 300], fmtEvery)}</div>
      <div class="set-row stack"><div><div class="set-label">Keep warm</div><div class="set-hint">Next entries by priority pinged with the current one — failover goes straight to a working one</div></div>
        ${chips('standby', [0, 1, 2, 3], v => v ? 'next ' + v : 'off')}</div>
      <div class="set-row stack"><div><div class="set-label">Leave a server after</div><div class="set-hint">Timeouts in a row before Auto moves on</div></div>
        ${chips('failAfter', [1, 2, 3], v => v + ' timeout' + (v > 1 ? 's' : ''))}</div>
      <div class="set-row"><div class="set-label">Pause checks with the screen off<div class="set-hint">Saves battery; checks again on wake</div></div>${toggle(autoCfg.pauseScreenOff, "setAutoCfg('pauseScreenOff',!autoCfg.pauseScreenOff)")}</div>
    </div>

    <div class="am-label">Subscriptions</div>
    <div class="set-group">
      <div class="set-row stack"><div><div class="set-label">Update all subscriptions every</div><div class="set-hint">${own.length
        ? `${own.map(sid => esc(sourcesData[sid].name)).join(', ')} ${own.length > 1 ? 'use their own periods' : 'uses its own period'} (Nodes → Edit)`
        : 'Each subscription follows this unless given its own period in Nodes'}</div></div>
        ${chips('subsEvery', [6, 12, 24, 0], v => v ? v + ' h' : 'Off')}</div>
    </div>`;
}

sourceViewHooks.push(() => {
  renderAutoCard();
  renderAutoMode();
});
