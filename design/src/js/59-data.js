/* ══════════════════════ SETTINGS → DATA, LATENCY TEST URL ══════════════════════
   Data: Backup (the state snapshot the core keeps as one JSON file: sources with their
   servers, profiles, chains, Route order, settings), Restore (a file → confirm → it
   replaces everything), About (versions, the data folder).
   Latency test URL (Settings → Connection): what ping and Fastest measure against; sent
   to the core as the plan's urlTest.url and with every ping ('' = the core's default).
   (Flutter: DataSettingsPage, BackupService over the core's state store.) */

const APP_VERSION = '0.1.0';
const CLOUD_ICON = {
  down: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
  up: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>',
};

function openDataSettings() {
  renderDataSettings(null);
  openSheet('setdata');
  backend.version().then(v => renderDataSettings(v), () => renderDataSettings({}));
}

function renderDataSettings(v) {
  const val = (x, fallback) => `<span class="settings-value mono">${x ? esc(x) : fallback}</span>`;
  const wait = '<span class="settings-value">…</span>';
  const noCore = v && !backend.live;
  document.getElementById('data-settings').innerHTML = `
    <div class="set-caption">Backup</div>
    <div class="set-group">
      <div class="set-row tap" id="data-export" onclick="exportBackup()"><div class="set-label" style="flex:1">Export backup<div class="set-hint">Sources with their servers, profiles, chains, Route order, rules, DNS and settings — one JSON file</div></div>${CLOUD_ICON.down}</div>
      <div class="set-row tap" id="data-restore" onclick="document.getElementById('restoreFile').click()"><div class="set-label" style="flex:1">Restore from file<div class="set-hint">Replaces everything here with the backup; asks first</div></div>${CLOUD_ICON.up}</div>
    </div>
    <div class="set-caption">About</div>
    <div class="set-group">
      <div class="set-row"><div class="set-label" style="flex:1">Jormungand</div>${val(APP_VERSION + (backend.live ? '' : ' mockup'))}</div>
      <div class="set-row"><div class="set-label" style="flex:1">Core</div>${!v ? wait : noCore ? val('', 'not connected') : val(v.core, '—')}</div>
      <div class="set-row"><div class="set-label" style="flex:1">sing-box</div>${!v ? wait : noCore ? val('', '—') : val(v.singBox, 'not found')}</div>
      ${v && v.dataDir ? `<div class="set-row"><div class="set-label" style="flex:1;min-width:0">Data folder<div class="set-hint data-dir">${esc(v.dataDir)}</div></div></div>` : ''}
    </div>`;
}

function exportBackup() {
  backend.exportState().then(snapshot => {
    const at = new Date();
    const file = { app: 'jormungand', backup: 1, at: at.toISOString(), snapshot };
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([JSON.stringify(file, null, 2)], { type: 'application/json' }));
    a.download = 'jormungand-backup-' + at.toISOString().slice(0, 10) + '.json';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    toast('Backup saved: ' + a.download);
  }, e => toast('Backup failed: ' + e.message));
}

// A backup file, or a bare snapshot. Only one with sources is taken.
let pendingRestore = null;
function readRestoreFile(input) {
  const f = input.files && input.files[0];
  input.value = '';
  if (!f) return;
  f.text().then(text => {
    let j;
    try { j = JSON.parse(text); } catch (e) { throw new Error('not a JSON file'); }
    const snap = j && j.snapshot ? j.snapshot : j;
    if (!snap || typeof snap.sourcesData !== 'object' || !Array.isArray(snap.sourceOrder)) throw new Error('no Jormungand backup in it');
    pendingRestore = snap;
    confirmRestore(snap, j.at, f.name);
  }).catch(e => toast('Cannot restore: ' + e.message));
}

function confirmRestore(snap, at, fileName) {
  const count = o => Object.keys(o || {}).length;
  const servers = Object.values(snap.sourcesData).reduce((n, s) => n + (s.nodes || []).length, 0);
  const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  const what = [plural(count(snap.sourcesData), 'source'), plural(servers, 'server'), plural(count(snap.profilesData), 'profile'), plural(count(snap.chainsData), 'chain'),
    plural(count(snap.rulesData), 'rule')].join(' · ');
  openActions('Restore backup?',
    `<div class="restore-card">
       <div class="restore-file">${esc(fileName)}${at ? ' · ' + esc(new Date(at).toLocaleString()) : ''}</div>
       <div class="restore-what">${what}</div>
       <div class="restore-warn">Everything here is replaced: sources, profiles, chains, Route and settings.${connected ? ' The connection restarts with the restored state.' : ''}</div>
     </div>` +
    menuRow(CLOUD_ICON.up, 'Restore', "closeSheet('actions');applyRestore()", 'danger') +
    menuRow('', 'Cancel', "closeSheet('actions')"));
}

function applyRestore() {
  const snap = pendingRestore;
  pendingRestore = null;
  if (!snap) return;
  backend.importState(snap).then(() => {
    renderAfterRestore();
    closeSheet('setdata');
    toast('Backup restored');
  }, e => toast('Not restored: ' + e.message));
}

// The whole UI from the restored state (as after the core's state loads, 95-live.js).
function renderAfterRestore() {
  renderAutoMode(); renderConnSettings(); renderDns(); renderGeneral();
  ['mode', 'route', 'sys'].forEach(g => setSegment(g, segState[g]));
  renderConnects(); renderNodes(); renderRules(); updateMainConnectCard(); renderConnState();
}

/* ── Latency test URL ── */

const TEST_URLS = [
  ['', 'Default', 'www.gstatic.com/generate_204 (Google)'],
  ['https://cp.cloudflare.com/generate_204', 'Cloudflare', 'cp.cloudflare.com/generate_204'],
  ['http://www.msftconnecttest.com/connecttest.txt', 'Microsoft', 'www.msftconnecttest.com'],
  ['http://detectportal.firefox.com/success.txt', 'Mozilla', 'detectportal.firefox.com'],
  ['http://captive.apple.com/hotspot-detect.html', 'Apple', 'captive.apple.com'],
];
function testUrlLabel() {
  const p = TEST_URLS.find(([u]) => u === (connCfg.testUrl || ''));
  if (p) return p[1];
  try { return new URL(connCfg.testUrl).hostname; } catch (e) { return 'Custom'; }
}

function openTestUrlPicker() {
  const cur = connCfg.testUrl || '', custom = !TEST_URLS.some(([u]) => u === cur);
  openActions('Latency test URL',
    TEST_URLS.map(([u, name, hint]) => menuRow(u === cur ? ICON.check : '<span class="menu-ico-gap"></span>',
      `${name}<div class="menu-sub">${hint}</div>`, `closeSheet('actions');setTestUrl('${u}')`)).join('') +
    `<div class="menu-caption">Custom</div>
     <div class="form-group testurl-custom">
       <input class="form-input" id="testurl-input" placeholder="https://example.com/generate_204" value="${custom ? esc(cur) : ''}" spellcheck="false" autocomplete="off">
       <button class="btn-primary" onclick="setCustomTestUrl()">Use</button>
     </div>
     <div class="set-hint testurl-hint">Any address that answers fast over HTTP(S); the time to its reply is the ping. Pick one that works in your country.</div>`);
}

function setCustomTestUrl() {
  const v = document.getElementById('testurl-input').value.trim();
  if (!/^https?:\/\/[^\s/?#]+\.[^\s/?#]+/i.test(v)) { toast('Enter an http:// or https:// address'); return; }
  closeSheet('actions');
  setTestUrl(v);
}

function setTestUrl(url) {
  if ((connCfg.testUrl || '') === url) return;
  connCfg.testUrl = url;
  renderConnSettings();
  toast('Latency test: ' + testUrlLabel() + (connected ? ' — Fastest uses it from the next connect' : ''));
}

/* ── Backup checks (connCfg.checkers) ── */

// The presets are the test URL services (Default = gstatic); anything else is the user's own.
const checkerPresets = () => TEST_URLS.map(([u, name, hint]) => [u || 'https://www.gstatic.com/generate_204', name === 'Default' ? 'Google' : name, hint.replace(' (Google)', '')]);
function openCheckersPicker() {
  const on = new Set(connCfg.checkers), presets = checkerPresets();
  const own = connCfg.checkers.filter(u => !presets.some(([p]) => p === u));
  const row = (u, name, hint) => menuRow(on.has(u) ? ICON.check : '<span class="menu-ico-gap"></span>',
    `${esc(name)}<div class="menu-sub">${esc(hint)}</div>`, `toggleChecker('${esc(u)}')`);
  openActions('Backup checks',
    presets.map(([u, name, hint]) => row(u, name, hint)).join('') +
    own.map(u => row(u, (() => { try { return new URL(u).hostname; } catch (e) { return u; } })(), u + ' · tap to remove')).join('') +
    `<div class="menu-caption">Your own</div>
     <div class="form-group testurl-custom">
       <input class="form-input" id="checker-input" placeholder="https://example.com/generate_204" spellcheck="false" autocomplete="off">
       <button class="btn-primary" onclick="addChecker()">Add</button>
     </div>
     <div class="set-hint testurl-hint">Services of different owners: one blocked service must not make a working server look dead. Tried only after the test URL missed.</div>`);
}

function toggleChecker(u) {
  const i = connCfg.checkers.indexOf(u);
  if (i >= 0) connCfg.checkers.splice(i, 1); else connCfg.checkers.push(u);
  checkersChanged();
}

function addChecker() {
  const v = document.getElementById('checker-input').value.trim();
  if (!/^https?:\/\/[^\s/?#]+\.[^\s/?#]+/i.test(v)) { toast('Enter an http:// or https:// address'); return; }
  if (!connCfg.checkers.includes(v)) connCfg.checkers.push(v);
  checkersChanged();
}

function checkersChanged() {
  renderConnSettings();
  openCheckersPicker();
  if (typeof liveSyncAuto === 'function') liveSyncAuto();
}
