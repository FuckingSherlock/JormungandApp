/* ══════════════════════ SETTINGS → GENERAL ══════════════════════
   Language, startup, notifications, clipboard, updates. genCfg is what the Flutter app
   keeps in its settings store. */
const genCfg = {
  lang: 'en',             // 'en' | 'ru' (mockup text stays English)
  launchAtStartup: false, // start with the OS (Android: after boot; desktop: login item)
  startMinimized: true,   // desktop: start in the tray
  connectOnLaunch: false, // connect as soon as the app opens
  pingOnLaunch: true,     // ping the top Auto entries by priority and the rules' targets on open
  statusNotif: true,      // Android: ongoing notification with the entry and speed
  switchNotif: true,      // notify when Auto moves to another entry
  clipboard: true,        // offer to import a subscription / server link found in the clipboard
  updates: true,          // check for app updates
};
const LANGS = { en: 'English', ru: 'Русский' };

function renderGeneral() {
  const toggle = (key, fn) => `<div class="mini-toggle ${genCfg[key] ? 'on' : ''}" onclick="${fn || `setGenCfg('${key}',!genCfg.${key})`}"><div class="mini-toggle-thumb"></div></div>`;
  const row = (key, label, hint) => `<div class="set-row" data-key="${key}"><div class="set-label" style="flex:1">${label}<div class="set-hint">${hint}</div></div>${toggle(key)}</div>`;
  const n = autoCfg.standby;
  document.getElementById('general-settings').innerHTML = `
    <div class="set-group">
      <div class="set-row"><div class="set-label" style="flex:1">Language</div>
        <button class="set-value" id="gen-lang" onclick="openLangPicker()">${LANGS[genCfg.lang]}${CHEVRON_R}</button></div>
    </div>
    <div class="set-caption">Startup</div>
    <div class="set-group">
      ${row('launchAtStartup', 'Launch at startup', 'Start with the system (Android: after reboot)')}
      ${row('startMinimized', 'Start minimized', 'Desktop: open in the tray, not as a window')}
      ${row('connectOnLaunch', 'Connect on launch', 'Turn the VPN on as soon as the app opens')}
      ${row('pingOnLaunch', 'Check servers on launch', `Pings the top Auto entry and the next ${n} by priority (the Keep warm count in Auto mode), and the targets of your rules`)}
    </div>
    <div class="set-caption">Notifications</div>
    <div class="set-group">
      ${row('statusNotif', 'Status notification', 'Android: shows the entry, server and speed while connected')}
      ${row('switchNotif', 'When Auto switches', 'Tell me when Auto moves to another entry or server')}
    </div>
    <div class="set-caption">Other</div>
    <div class="set-group">
      ${row('clipboard', 'Links in the clipboard', 'On open, offer to add a subscription or server link you copied')}
      ${row('updates', 'Check for app updates', 'Once a day; nothing is installed without asking')}
    </div>`;
  const sub = document.getElementById('setGeneralSub');
  if (sub) sub.textContent = LANGS[genCfg.lang] + (genCfg.connectOnLaunch ? ' · connects on launch' : '');
}
function setGenCfg(key, v) { genCfg[key] = v; renderGeneral(); }

function openLangPicker() {
  openActions('Language', Object.entries(LANGS).map(([k, name]) =>
    menuRow(genCfg.lang === k ? ICON.check : '', name, `closeSheet('actions');setGenCfg('lang','${k}')`)).join(''));
}

/* On open: ping the entry the app would connect through now and the next `autoCfg.standby`
   usable entries of the Route priority (Auto-eligible, not broken). Every server of those
   entries is pinged, so Fastest picks and failover start from fresh numbers. */
/* Launch ping: the servers Auto would try first — the top (1 + Keep warm) Auto entries,
   counted from the top of the priority list, not from the current pick (after a restart
   the current pick may sit lower only because the top one is not measured yet) — the
   pinned entry in Manual, and every target of an enabled rule or app (the rules' flows). */
function launchPingEntries() {
  const top = visibleOrder().filter(id => connectEntry(id).inAuto).slice(0, 1 + autoCfg.standby);
  return [...new Set((autoConnect ? [] : [effectiveConnectId()]).concat(top))].filter(Boolean);
}
// Servers behind a rule target ('src:' / 'node:' / 'profile:' / 'chain:' + id).
function targetRefs(t) {
  const at = t.indexOf(':'), kind = t.slice(0, at), ref = t.slice(at + 1);
  if (kind === 'src') { const s = sourcesData[ref]; return s && s.enabled ? liveNodes(s).map(node => ({ sid: ref, node })) : []; }
  if (kind === 'node') {
    const [sid, nid] = ref.split('::'), s = sourcesData[sid], n = s && s.nodes.find(x => x.id === nid);
    return n && s.enabled && !isNodeDisabled(s, nid) ? [{ sid, node: n }] : [];
  }
  if (kind === 'profile') return profilesData[ref] ? unitRefs(ref) : [];
  return chainsData[ref] ? entryRefs(ref) : [];
}
function ruleTargets() {
  const ts = Object.values(rulesData).filter(r => r.enabled && r.action === 'proxy' && r.target).map(r => r.target)
    .concat(Object.values(appRules).filter(a => a.act === 'proxy').flatMap(a => [a.target, a.split ? a.udpTarget : '']));
  return [...new Set(ts.filter(Boolean))];
}
const uniqNodes = refs => { const seen = new Set(); return refs.map(r => r.node).filter(n => !seen.has(pingKey(n)) && seen.add(pingKey(n))); };
function pingOnLaunch() {
  const nodes = uniqNodes(launchPingEntries().flatMap(entryRefs).concat(ruleTargets().flatMap(targetRefs)));
  return nodes.length ? pingNodes(nodes) : Promise.resolve();
}
/* Tap on the latency in the dock: a quick look at what Auto would use — the first 3
   servers (in the entry's own pick order; Fastest: best known first) of the first 4 Auto
   entries by priority; in Manual the pinned entry comes first. A chain: 3 of each end. */
function dockTopRefs() {
  const ids = [...new Set((autoConnect ? [] : [effectiveConnectId()]).concat(visibleOrder().filter(id => connectEntry(id).inAuto)))].filter(Boolean).slice(0, 4);
  const first3 = (refs, priority) => (priority ? refs : refs.slice().sort((a, b) => pingRank(a.node) - pingRank(b.node))).slice(0, 3);
  return ids.flatMap(id => {
    const c = chainsData[id];
    if (c) return first3(chainEntryRefs(c), false).concat(first3(chainExitRefs(c), c.exitMode === 'priority'));
    const pin = pinnedRef(id);
    return (pin ? [pin] : []).concat(first3(unitPickRefs(id), unitPriority(id))).slice(0, 3);
  });
}
/* It keeps going after that first batch — every other server of the Route list (Auto
   entries first, each in its own order), DOCK_PING_BATCH at a time — until
   DOCK_PING_ENOUGH servers answered or all are measured. While it runs a frame runs round
   the dock's latency; a second tap stops it (the batch in flight still reports). */
const DOCK_PING_BATCH = 8, DOCK_PING_ENOUGH = 10;
let dockPing = null;   // { stopped } while running
function dockPingBatches() {
  const order = visibleOrder();
  const ids = [...new Set((autoConnect ? [] : [effectiveConnectId()]).concat(order.filter(id => connectEntry(id).inAuto), order))].filter(Boolean);
  const own = id => {
    const c = chainsData[id];
    if (c) return chainEntryRefs(c).concat(chainExitRefs(c));
    return unitPriority(id) ? unitPickRefs(id) : unitPickRefs(id).slice().sort((a, b) => pingRank(a.node) - pingRank(b.node));
  };
  const first = uniqNodes(dockTopRefs()), had = new Set(first.map(pingKey));
  const rest = uniqNodes(ids.flatMap(own)).filter(n => !had.has(pingKey(n))), out = first.length ? [first] : [];
  for (let i = 0; i < rest.length; i += DOCK_PING_BATCH) out.push(rest.slice(i, i + DOCK_PING_BATCH));
  return out;
}
const setDockPinging = on => document.querySelector('.dock .profiles-meta').classList.toggle('pinging', on);
function pingDockTop() {
  if (dockPing) {
    dockPing.stopped = true; dockPing = null; setDockPinging(false);
    refreshSourceViews(); updateMainConnectCard();
    return;
  }
  const run = dockPing = { stopped: false }, batches = dockPingBatches();
  let alive = 0;
  const next = () => {
    if (run.stopped) return;
    const batch = batches.shift();
    if (!batch || alive >= DOCK_PING_ENOUGH) { dockPing = null; setDockPinging(false); return; }
    pingNodes(batch).then(() => { alive += batch.filter(isAlive).length; next(); });
  };
  setDockPinging(true);
  next();
}
