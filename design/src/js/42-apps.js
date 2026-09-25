/* ══════════════════════ APPS (Rules → Per-app routing) ══════════════════════
   Each app gets its own action — no global switch on top: Default (goes by the rules),
   Direct, Proxy (through a target; stub picker for now) or Block. "Split TCP / UDP" gives
   the app two targets, e.g. Discord chat via one server and voice (UDP to bare IPs, which
   domain rules cannot catch) via another. Apps come first in the engine's order.
   Android: package names; desktop: running processes + "add by path" (same screen).
   Flutter: installed apps via a platform channel; sing-box rules on package_name /
   process_name, with network: tcp|udp when split. */

const APPS = [
  { pkg: 'org.telegram.messenger', name: 'Telegram' }, { pkg: 'com.discord', name: 'Discord' },
  { pkg: 'com.google.android.youtube', name: 'YouTube' }, { pkg: 'com.android.chrome', name: 'Chrome' },
  { pkg: 'ru.sberbankmobile', name: 'SberBank' }, { pkg: 'com.spotify.music', name: 'Spotify' },
  { pkg: 'com.instagram.android', name: 'Instagram' }, { pkg: 'com.whatsapp', name: 'WhatsApp' },
  { pkg: 'com.openai.chatgpt', name: 'ChatGPT' }, { pkg: 'ru.yandex.taxi', name: 'Yandex Go' },
  { pkg: 'com.valvesoftware.android.steam.community', name: 'Steam' }, { pkg: 'org.torproject.torbrowser', name: 'Tor Browser' },
  { pkg: 'com.google.android.gms', name: 'Google Play services', sys: true }, { pkg: 'com.android.vending', name: 'Play Store', sys: true },
  { pkg: 'com.android.providers.downloads', name: 'Downloads', sys: true }, { pkg: 'com.android.systemui', name: 'System UI', sys: true },
];
// pkg -> { act: 'direct' | 'proxy' | 'block', target, split, udpTarget }
let appRules = {
  'org.telegram.messenger': { act: 'proxy', target: 0, split: false, udpTarget: 0 },
  'com.discord': { act: 'proxy', target: 0, split: true, udpTarget: 2 },
  'ru.sberbankmobile': { act: 'direct', target: 0, split: false, udpTarget: 0 },
};
const APP_ACTS = [['default', 'Default'], ['direct', 'Direct'], ['proxy', 'Proxy'], ['block', 'Block']];

function appActText(a) {
  if (a.act === 'direct') return 'Direct';
  if (a.act === 'block') return 'Block';
  if (a.split) return 'TCP ' + (a.target ? targetName(a.target) : 'Proxy') + ' · UDP ' + (a.udpTarget ? targetName(a.udpTarget) : 'Proxy');
  return a.target ? '→ ' + targetName(a.target) : 'Proxy';
}

let appQuery = '', appFilter = 'user';
function openApps() { appQuery = ''; document.getElementById('apps-search').value = ''; renderApps(); openSheet('apps'); }
function setAppFilter(f) { appFilter = f; renderApps(); }
function renderApps() {
  document.querySelectorAll('#apps-filter .chip').forEach(c => c.classList.toggle('active', c.dataset.f === appFilter));
  const q = appQuery.toLowerCase();
  const list = APPS.filter(a => (appFilter === 'set' ? appRules[a.pkg] : appFilter === 'sys' ? a.sys : !a.sys)
    && (!q || a.name.toLowerCase().includes(q) || a.pkg.includes(q)));
  document.getElementById('apps-list').innerHTML = list.map(a => {
    const r = appRules[a.pkg];
    return `<div class="set-row app-row" data-pkg="${a.pkg}" onclick="openAppAct('${a.pkg}')">
      <div class="app-ico" style="--h:${hash(a.pkg) % 360}">${esc(a.name[0])}</div>
      <div class="set-label">${esc(a.name)}<div class="app-pkg">${esc(a.pkg)}</div></div>
      <span class="app-state ${r ? r.act : ''}">${r ? esc(appActText(r)) : '—'}</span></div>`;
  }).join('') || '<div class="rules-empty">No apps</div>';
}

/* ── One app's action (small dialog) ── */
let appEditing = null, appDraft = null;
function openAppAct(pkg) {
  appEditing = pkg;
  appDraft = Object.assign({ act: 'default', target: 0, split: false, udpTarget: 0 }, appRules[pkg] || {});
  document.getElementById('aaTitle').textContent = APPS.find(a => a.pkg === pkg).name;
  renderAppAct();
  openSheet('appact');
}
function renderAppAct() {
  const d = appDraft;
  document.getElementById('aa-body').innerHTML = `
    <div class="seg3 wide">${APP_ACTS.map(([v, l]) => `<button class="${d.act === v ? 'on ' + v : ''}" onclick="appDraft.act='${v}';renderAppAct()">${l}</button>`).join('')}</div>
    ${d.act === 'proxy' ? `<div class="set-group aa-group">
      ${targetRowHtml(d.split ? 'TCP via' : 'Via', d.target, 'appDraft.target=nextTarget(appDraft.target);renderAppAct()')}
      ${d.split ? targetRowHtml('UDP via', d.udpTarget, 'appDraft.udpTarget=nextTarget(appDraft.udpTarget);renderAppAct()') : ''}
      <div class="set-row"><div class="set-label">Split TCP / UDP<div class="set-hint">Different routes, e.g. voice (UDP) apart from chat</div></div>
        <div class="mini-toggle ${d.split ? 'on' : ''}" onclick="appDraft.split=!appDraft.split;renderAppAct()"><div class="mini-toggle-thumb"></div></div></div>
    </div>` : `<div class="set-hint aa-hint">${{ default: 'Goes by the rules like any other traffic', direct: 'Always bypasses the VPN', block: 'No network at all while connected' }[d.act]}</div>`}`;
}
function saveAppAct() {
  if (appDraft.act === 'default') delete appRules[appEditing];
  else appRules[appEditing] = appDraft;
  closeSheet('appact');
  renderApps(); renderRules();
}
