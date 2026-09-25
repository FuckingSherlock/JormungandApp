/* ══════════════════════ SETTINGS → GENERAL ══════════════════════
   Language, startup, notifications, clipboard, updates. genCfg is what the Flutter app
   keeps in its settings store. */
const genCfg = {
  lang: 'en',             // 'en' | 'ru' (mockup text stays English)
  launchAtStartup: false, // start with the OS (Android: after boot; desktop: login item)
  startMinimized: true,   // desktop: start in the tray
  connectOnLaunch: false, // connect as soon as the app opens
  pingOnLaunch: true,     // ping the current entry and the next ones by priority on open
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
      ${row('pingOnLaunch', 'Check servers on launch', `Pings the current entry and the next ${n} by priority (the Keep warm count in Auto mode)`)}
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
function launchPingEntries() {
  const cur = effectiveConnectId(), order = visibleOrder();
  const next = order.slice(order.indexOf(cur) + 1).filter(id => connectEntry(id).inAuto).slice(0, autoCfg.standby);
  return [cur].concat(next).filter(Boolean);
}
function pingOnLaunch() {
  const seen = new Set(), nodes = [];
  launchPingEntries().forEach(id => entryRefs(id).forEach(r => {
    const k = serverKey(r.node);
    if (!seen.has(k)) { seen.add(k); nodes.push(r.node); }
  }));
  return nodes.length ? pingNodes(nodes) : Promise.resolve();
}
