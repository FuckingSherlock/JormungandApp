/* ══════════════════════ APPS (Rules → Per-app routing) ══════════════════════
   Each app gets its own action — no global switch on top: Default (goes by the rules),
   Proxy (through a target from the target picker, with "If unavailable" like a rule's),
   Direct or Block. "Split TCP / UDP" (any action) gives TCP and UDP an action each, e.g.
   Discord chat via one server and voice (UDP to bare IPs, which domain rules cannot catch) via
   another, or TCP Default + UDP Block to kill QUIC. Apps come first in the engine's order.
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
// pkg -> { act: 'default' | 'proxy' | 'direct' | 'block', target, fallback: 'default' | 'main' | 'block' | 'direct',
//          split, udp: { act, target, fallback } } — with split the top-level fields are TCP, `udp` is UDP.
// A half that is 'default' has no rule of its own; an app with nothing set is not stored at all.
let appRules = {
  'org.telegram.messenger': { act: 'proxy', target: '', fallback: 'default', split: false },
  'com.discord': { act: 'proxy', target: '', fallback: 'default', split: true, udp: { act: 'proxy', target: 'chain:sc1', fallback: 'default' } },
  'ru.sberbankmobile': { act: 'direct', target: '', fallback: 'default', split: false },
};
const APP_ACTS = [['default', 'Default'], ['proxy', 'Proxy'], ['direct', 'Direct'], ['block', 'Block']];
const appBlankHalf = () => ({ act: 'default', target: '', fallback: 'default' });

// Full shape from any stored one; the old { act: 'proxy', split, udpTarget } becomes udp: { act: 'proxy', target: udpTarget }.
function appNormalize(a) {
  const o = Object.assign({ split: false }, appBlankHalf(), a);
  const old = 'udpTarget' in o;
  if (!o.udp && old && o.split) o.udp = { act: 'proxy', target: o.udpTarget || '', fallback: 'default' };
  delete o.udpTarget;
  o.udp = Object.assign(appBlankHalf(), o.udp);
  o.split = !!o.split;
  return o;
}
function appRulesNormalize(rules) { return Object.fromEntries(Object.entries(rules || {}).map(([k, v]) => [k, appNormalize(v)])); }
// [protocol label, half]: one half for the whole app, or TCP and UDP when split.
const appHalves = a => a.split ? [['TCP', a], ['UDP', a.udp || appBlankHalf()]] : [['', a]];
const appHalfText = h => h.act === 'proxy' ? (h.target ? '→ ' + targetName(h.target) : 'Proxy') : ({ default: 'Default', direct: 'Direct', block: 'Block' })[h.act];
function appActText(a) {
  if (!a.split) return appHalfText(a);
  return appHalves(a).map(([p, h]) => p + ' ' + appHalfText(h)).join(' · ');
}
// the colour of the right column: the one action, or the first non-default half
const appStateClass = a => (appHalves(a).find(([, h]) => h.act !== 'default') || [0, a])[1].act;

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
      ${appStateHtml(a.pkg)}</div>`;
  }).join('') || '<div class="rules-empty">No apps</div>';
}

// Right column: the app's own route; otherwise a service that covers it ("via service"), or —.
function appStateHtml(pkg) {
  const r = appRules[pkg], svc = serviceOfApp(pkg), sv = svc && quickCfg.services[svc[0]];
  if (r && r.split) return `<span class="app-state split" title="${esc(appActText(r))}">${appHalves(r).map(([p, h]) =>
    `<span class="${h.act}">${p} ${esc(appHalfText(h))}</span>`).join('')}</span>`;   // one line per protocol
  if (r) return `<span class="app-state ${appStateClass(r)}" title="${esc(appActText(r))}">${esc(appActText(r))}</span>`;
  if (sv && sv !== 'default') return `<span class="app-state svc ${sv === 'vpn' ? 'proxy' : 'direct'}" title="Set by the ${esc(svc[1])} service">${svcState(sv)} · service</span>`;
  return '<span class="app-state">—</span>';
}

/* ── One app's action (small dialog) ── */
let appEditing = null, appDraft = null;
function openAppAct(pkg) {
  appEditing = pkg;
  appDraft = clone(appNormalize(appRules[pkg]));
  document.getElementById('aaTitle').textContent = APPS.find(a => a.pkg === pkg).name;
  renderAppAct();
  openSheet('appact');
}
// One action (h = appDraft or appDraft.udp, path = its JS path): the segment, and for Proxy the
// target with "If unavailable" — the same rows as the rule form — or a hint for the others.
// `between` goes right under the segment (the Split switch, while it is off).
function appHalfHtml(h, path, proto, between = '') {
  const id = proto ? proto.toLowerCase() : 'all';
  const hint = { default: proto ? `No own route for ${proto}: it goes by the rules` : 'Goes by the rules like any other traffic', direct: 'Always bypasses the VPN',
    block: proto ? `${proto} is blocked while connected` : 'No network at all while connected' }[h.act];
  return `<div class="aa-half" data-half="${id}">
    ${proto ? `<div class="aa-proto">${proto}</div>` : ''}
    <div class="seg3 wide">${APP_ACTS.map(([v, l]) => `<button class="${h.act === v ? 'on ' + v : ''}" onclick="${path}.act='${v}';renderAppAct()">${l}</button>`).join('')}</div>
    ${between}
    ${h.act === 'proxy' ? `<div class="set-group aa-group">
      ${targetRowHtml('Via', h.target, `t => { ${path}.target = t; renderAppAct(); }`)}
      ${h.target ? fallbackRowsHtml(h, path, 'renderAppAct', 'aa-fallback-' + id) : ''}
    </div>` : `<div class="set-hint aa-hint">${hint}</div>`}</div>`;
}
// The app has an own route unless every half is Default.
const appDraftAct = d => appHalves(d).every(([, h]) => h.act === 'default') ? 'default' : 'own';
function renderAppAct() {
  const d = appDraft;
  const toggle = `<div class="set-group aa-group aa-split"><div class="set-row"><div class="set-label">Split TCP / UDP<button class="help-btn" onclick="openHelp('apps')" title="What is this?">?</button></div>
      <div class="mini-toggle ${d.split ? 'on' : ''}" id="aa-split" onclick="appDraft.split=!appDraft.split;renderAppAct()"><div class="mini-toggle-thumb"></div></div></div></div>`;
  document.getElementById('aa-body').innerHTML = toggle + (d.split
    ? appHalfHtml(d, 'appDraft', 'TCP') + appHalfHtml(d.udp, 'appDraft.udp', 'UDP')
    : appHalfHtml(d, 'appDraft', '')) + appSvcNote(appEditing, appDraftAct(d));
}
// The service with the same app: what it does, and who wins.
function appSvcNote(pkg, act) {
  const svc = serviceOfApp(pkg), sv = svc && quickCfg.services[svc[0]];
  if (!svc) return '';
  const state = sv && sv !== 'default' ? `${svc[1]} service: ${svcState(sv)}` : `${svc[1]} service: not added`;
  const who = act === 'default' ? (sv && sv !== 'default' ? 'so this app goes ' + svcState(sv) + ' by the service' : 'add it in Rules → Services to route its sites from any app')
    : 'this app’s own route wins for the app; the service still covers its sites in other apps';
  return `<div class="set-hint aa-hint aa-svc">${state} — ${who}</div>`;
}

function saveAppAct() {
  if (appDraftAct(appDraft) === 'default') delete appRules[appEditing];
  else {
    const a = clone(appDraft);
    if (!a.split) a.udp = appBlankHalf();   // the UDP half only lives while Split is on
    appRules[appEditing] = a;
  }
  closeSheet('appact');
  renderApps(); renderRules();
}
