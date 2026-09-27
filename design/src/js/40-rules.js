/* ══════════════════════ RULES (Home → Rules card) ══════════════════════
   One ordered list of sing-box route rules, shown in layers (docs/rules.md):
     1. Apps       — per-app action (42-apps.js);
     2. My rules   — full form (75-rule-form.js), drag to reorder;
     3. Quick      — local networks, ads, services, "my region direct";
     4. Everything else — one final action.
   The engine checks them top-down, first match wins; "Final order" shows it read-only. */

/* ── Targets ──
   What a rule / app sends traffic through: '' = the main flow (what Home connects through),
   or any catalog item from Nodes, whatever mode the route is in —
     'src:<id>'          a subscription / server group: all its servers, fastest;
     'node:<sid>::<nid>' one server;
     'profile:<id>', 'chain:<id>'.
   Picked in the target picker (44-target-picker.js). A target is unavailable when it is
   switched off in Nodes, has no server left, or was deleted (the reference is kept, so the
   rule shows it); the traffic then goes by the rule's "If unavailable": Default (the global
   setting in Rules), Main flow, Block or Direct. Apps always use the global setting. */
function targetInfo(t) {
  if (!t) return { kind: 'main', name: 'Main flow', ok: true };
  const at = t.indexOf(':'), kind = t.slice(0, at), ref = t.slice(at + 1);
  if (kind === 'src') {
    const s = sourcesData[ref];
    return { kind: s && s.kind === 'node' ? 'servers' : 'subscription', name: s ? s.name : '', gone: !s, ok: !!s && s.enabled && liveNodes(s).length > 0 };
  }
  if (kind === 'node') {
    const [sid, nid] = ref.split('::'), s = sourcesData[sid], n = s && s.nodes.find(x => x.id === nid);
    return { kind: 'node', name: n ? n.name : '', flag: n ? n.flag : '', gone: !n, ok: !!n && s.enabled && !isNodeDisabled(s, nid) };
  }
  const e = kind === 'profile' ? profilesData[ref] : chainsData[ref];
  const ok = !!e && (kind === 'profile' ? unitRefs(ref).length > 0 : chainEntryRefs(e).length > 0 && chainExitRefs(e).length > 0);
  return { kind, name: e ? e.name : '', gone: !e, ok };
}
const targetName = t => { const i = targetInfo(t); return i.gone ? 'deleted ' + i.kind : i.name; };
const targetTag = t => t ? targetInfo(t).kind + ':' + targetName(t) : 'proxy';
// Every target the picker offers, in its order (for JSON import: outbound tag -> target).
function allTargets() {
  return [''].concat(sourceOrder.flatMap(sid => ['src:' + sid].concat(sourcesData[sid].nodes.map(n => 'node:' + sid + '::' + n.id))),
    getProfileIds().map(id => 'profile:' + id), Object.keys(chainsData).map(id => 'chain:' + id));
}
// apply: JS source of a function taking the picked target, e.g. 't => { ruleDraft.target = t; renderRuleForm(); }'.
function targetRowHtml(label, t, apply) {
  const i = targetInfo(t);
  return `<div class="set-row tgt-row" onclick="openTargetPicker('${t}', ${apply})"><div class="set-label">${label}</div>
    <span class="tgt-val">${i.flag ? i.flag + ' ' : ''}${esc(targetName(t))}${t ? `<span class="tgt-kind">${i.kind}</span>` : ''}${i.ok ? '' : '<span class="conn-tag warn">unavailable</span>'}</span>${CHEVRON_R}</div>`;
}

const FALLBACKS = [['main', 'Main flow'], ['block', 'Block'], ['direct', 'Direct']];
const fallbackName = v => (FALLBACKS.find(f => f[0] === v) || [, ''])[1];
const ruleFallback = r => r.fallback && r.fallback !== 'default' ? r.fallback : quickCfg.fallback;
const fallbackText = v => ({ main: 'through the main flow', block: 'nowhere (blocked)', direct: 'direct' })[v];

// Rules and apps whose target a deletion removes (gone: target -> bool), for the delete dialog.
function targetImpact(gone) {
  const lines = [];
  ruleOrder.forEach((id, i) => {
    const r = rulesData[id];
    if (r.action === 'proxy' && r.target && gone(r.target))
      lines.push([ruleTitle(r), 'rule #' + (i + 1), 'loses its target — traffic goes ' + fallbackText(ruleFallback(r)), 'warn']);
  });
  Object.entries(appRules).forEach(([pkg, a]) => {
    if (a.act === 'proxy' && [a.target, a.split ? a.udpTarget : ''].some(t => t && gone(t)))
      lines.push([APPS.find(x => x.pkg === pkg).name, 'app', 'loses its target — traffic goes ' + fallbackText(quickCfg.fallback), 'warn']);
  });
  return lines;
}

/* Condition groups of a rule. Inside a field values are OR, between groups AND; each group
   may be negated ("except"). kinds drive validation (validVal). */
const RULE_GROUPS = [
  { key: 'domain', title: 'Domains', fields: [
    ['domain_suffix', 'Suffix', 'google.com', 'suffix'], ['domain', 'Exact domain', 'example.com', 'domain'],
    ['domain_keyword', 'Keyword', 'google', 'text'], ['domain_regex', 'Regex', '^.+\\.ru$', 'regex'],
    ['geosite', 'Geosite', 'youtube', 'name'], ['rule_set', 'Rule set', 'ru-blocked', 'ruleset']] },
  { key: 'ip', title: 'IP', fields: [['ip_cidr', 'IP / CIDR / range', '10.0.0.0/8, 1.1.1.1-1.1.1.9', 'ip'], ['geoip', 'GeoIP', 'ru', 'name']],
    flag: ['ip_is_private', 'Local networks'] },
  { key: 'port', title: 'Ports', fields: [['port', 'Ports and ranges', '443, 8000-9000', 'port']] },
  { key: 'source', title: 'Source', fields: [['source_ip_cidr', 'Source IP / CIDR', '192.168.1.0/24', 'ip'], ['source_port', 'Source ports', '5000-6000', 'port']] },
  { key: 'network', title: 'Network', choices: [['network', 'Network', ['tcp', 'udp']], ['protocol', 'Protocol (sniffed)', ['tls', 'http', 'quic', 'bittorrent', 'stun', 'dns']]] },
  { key: 'process', title: 'Process', desktop: true, fields: [['process', 'Name or path', 'chrome.exe, /usr/bin/*', 'text']] },
];
const GROUP = Object.fromEntries(RULE_GROUPS.map(g => [g.key, g]));

/* ── Validation ── */
const ip2n = s => s.split('.').reduce((a, o) => a * 256 + +o, 0);
const n2ip = n => [24, 16, 8, 0].map(b => Math.floor(n / 2 ** b) % 256).join('.');
const isIp4 = s => /^\d{1,3}(\.\d{1,3}){3}$/.test(s) && s.split('.').every(o => +o <= 255);
function isIpVal(v) {
  if (v.includes(':')) return /^[0-9a-f:]+(\/\d{1,3})?$/i.test(v) && !(+v.split('/')[1] > 128);
  const r = v.split('-');
  if (r.length === 2) return isIp4(r[0]) && isIp4(r[1]) && ip2n(r[0]) <= ip2n(r[1]);
  const [a, p] = v.split('/');
  return isIp4(a) && (p === undefined || /^\d{1,2}$/.test(p) && +p <= 32);
}
function isPortVal(v) {
  const m = /^(\d+)(?:-(\d+))?$/.exec(v);
  if (!m) return false;
  const a = +m[1], b = m[2] === undefined ? a : +m[2];
  return a >= 1 && b <= 65535 && a <= b;
}
const VALIDATORS = {
  domain: v => /^(\*\.)?([a-z0-9-]+\.)+[a-z0-9-]{2,}$/i.test(v),
  suffix: v => /^\.?([a-z0-9-]+\.)*[a-z0-9-]+$/i.test(v),
  text: v => !/\s/.test(v),
  regex: v => { try { new RegExp(v); return true; } catch { return false; } },
  name: v => /^[a-z0-9@!_-]+$/i.test(v),
  ruleset: v => ruleSets.some(s => s.name === v),
  ip: isIpVal, port: isPortVal,
};
const VAL_HINT = {
  domain: 'a domain, e.g. example.com or *.example.com', suffix: 'a domain suffix, e.g. google.com', text: 'no spaces',
  regex: 'not a valid regular expression', name: 'letters, digits, - and _', ruleset: 'no rule set with this name (Rule sets)',
  ip: 'an IP, CIDR (10.0.0.0/8) or range (1.1.1.1-1.1.1.9)', port: '1–65535 or a range like 8000-9000',
};
const validVal = (kind, v) => VALIDATORS[kind](v);

// 1.1.1.1-1.1.1.9 → the CIDR blocks sing-box needs (ip_cidr has no ranges).
function rangeToCidrs(a, b) {
  const out = [];
  let s = ip2n(a); const e = ip2n(b);
  while (s <= e) {
    let size = 32;
    while (size > 0) { const block = 2 ** (32 - size + 1); if (s % block || s + block - 1 > e) break; size--; }
    out.push(n2ip(s) + '/' + size);
    s += 2 ** (32 - size);
  }
  return out;
}

/* ── Data ── */
let rulesData = {
  r1: { id: 'r1', name: 'Work network', enabled: true, action: 'direct', target: '', block: 'drop', fallback: 'default', dns: 'auto',
        groups: { domain: { not: false, v: { domain_suffix: ['corp.local', 'intra.example.com'] } } } },
  r2: { id: 'r2', name: 'Discord voice', enabled: true, action: 'proxy', target: 'chain:sc1', block: 'drop', fallback: 'block', dns: 'auto',
        groups: { domain: { not: false, v: { domain_suffix: ['discord.gg', 'discord.media'] } }, network: { not: false, v: { network: ['udp'] } } } },
  r3: { id: 'r3', name: '', enabled: true, action: 'direct', target: '', block: 'drop', fallback: 'default', dns: 'auto',
        groups: { network: { not: false, v: { protocol: ['bittorrent'] } }, port: { not: false, v: { port: ['6881-6889'] } } } },
  r4: { id: 'r4', name: 'Trackers', enabled: false, action: 'block', target: '', block: 'drop', fallback: 'default', dns: 'auto', groups: {},
        composite: { type: 'logical', mode: 'or', rules: [{ domain_keyword: ['tracker'] }, { port: [6969] }], action: 'reject', method: 'drop' } },
};
let ruleOrder = ['r1', 'r2', 'r3', 'r4'];
let ruleSeq = 5;

// [key, name, domains, app packages]. The service catches its sites from any app (browser too);
// its own app is matched earlier by Apps, so an app rule wins for that app's traffic.
const SERVICES = [
  ['telegram', 'Telegram', ['telegram.org', 't.me', 'telegram.me'], ['org.telegram.messenger']],
  ['youtube', 'YouTube', ['youtube.com', 'googlevideo.com', 'ytimg.com', 'youtu.be'], ['com.google.android.youtube']],
  ['discord', 'Discord', ['discord.com', 'discord.gg', 'discordapp.com'], ['com.discord']],
  ['netflix', 'Netflix', ['netflix.com', 'nflxvideo.net'], ['com.netflix.mediaclient']],
  ['spotify', 'Spotify', ['spotify.com', 'scdn.co'], ['com.spotify.music']],
  ['chatgpt', 'ChatGPT', ['openai.com', 'chatgpt.com'], ['com.openai.chatgpt']],
  ['instagram', 'Instagram', ['instagram.com', 'cdninstagram.com'], ['com.instagram.android']],
  ['x', 'X / Twitter', ['x.com', 'twitter.com', 'twimg.com'], ['com.twitter.android']],
];
const svcState = v => v === 'vpn' ? 'VPN' : v === 'direct' ? 'Direct' : '';
const serviceOfApp = pkg => SERVICES.find(s => s[3].includes(pkg));
// The app rule that overrides a service for its own app, if any.
const appOfService = key => { const s = SERVICES.find(x => x[0] === key); const pkg = s && s[3].find(p => appRules[p]); return pkg ? { pkg, name: (APPS.find(a => a.pkg === pkg) || { name: pkg }).name, text: appActText(appRules[pkg]) } : null; };
const REGIONS = [['RU', '🇷🇺 Russia', ['ru', 'рф', 'su']], ['BY', '🇧🇾 Belarus', ['by']], ['KZ', '🇰🇿 Kazakhstan', ['kz']],
  ['UA', '🇺🇦 Ukraine', ['ua']], ['CN', '🇨🇳 China', ['cn']], ['IR', '🇮🇷 Iran', ['ir']]];
const ADS = ['doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'adservice.google.com', 'an.yandex.ru'];
const quickCfg = {
  regionOn: true, region: 'RU', ads: false, final: 'proxy',
  fallback: 'main',   // a rule's target is unavailable and the rule says Default; apps always
  services: { telegram: 'vpn', youtube: 'vpn', discord: 'default', netflix: 'default', spotify: 'default', chatgpt: 'vpn', instagram: 'vpn', x: 'default' },
};
const SVC_STATES = [['default', 'Default'], ['vpn', 'VPN'], ['direct', 'Direct']];

let ruleSets = [
  { id: 'geosite', name: 'geosite', builtin: true, url: 'built-in', format: 'srs', via: 'vpn', every: 7 * 86400, updated: '2 d ago' },
  { id: 'geoip', name: 'geoip', builtin: true, url: 'built-in', format: 'srs', via: 'vpn', every: 7 * 86400, updated: '2 d ago' },
  { id: 'rs1', name: 'ru-blocked', url: 'https://example.org/lists/ru-blocked.srs', format: 'srs', via: 'vpn', every: 86400, updated: '5 h ago' },
];
let rsSeq = 2;

/* ── Labels ── */
function ruleTargetText(r) {
  if (r.action === 'direct') return 'Direct';
  if (r.action === 'block') return 'Block';
  return r.target ? '→ ' + targetName(r.target) : 'Proxy';
}
function ruleSummary(r) {
  if (r.composite) return 'composite rule';
  const parts = RULE_GROUPS.filter(g => r.groups[g.key]).map(g => {
    const d = r.groups[g.key];
    // The prefix goes on a field's first value only: "port 443, 8000-9000".
    const vals = Object.entries(d.v).flatMap(([f, list]) => list.map((v, i) =>
      (i ? '' : { domain_keyword: 'kw ', domain_regex: 're ', geosite: 'geosite:', rule_set: 'set:', geoip: 'geoip:', port: 'port ', source_ip_cidr: 'from ', source_port: 'from port ' }[f] || '') + v));
    if (d.flag) vals.unshift('local networks');
    const shown = vals.slice(0, 2).join(', ') + (vals.length > 2 ? ' +' + (vals.length - 2) : '');
    return (d.not ? 'not ' : '') + (shown || '—');
  });
  return parts.join(' · ') || 'no conditions';
}
const ruleTitle = r => r.name || ruleSummary(r);

/* ── Rules sheet ── */
let ruleQuery = '';
function openRules() { ruleQuery = ''; document.getElementById('rules-search').value = ''; renderRules(); openSheet('rules'); }
function setRuleQuery(q) { ruleQuery = q.trim().toLowerCase(); renderRules(); }

function renderRules() {
  const q = ruleQuery, hit = s => !q || s.toLowerCase().includes(q);
  const toggle = (on, click) => `<div class="mini-toggle ${on ? 'on' : ''}" onclick="event.stopPropagation();${click}"><div class="mini-toggle-thumb"></div></div>`;

  const shownRules = ruleOrder.filter(id => { const r = rulesData[id]; return hit(r.name + ' ' + ruleSummary(r) + ' ' + ruleTargetText(r)); });
  const ruleRows = shownRules.map(id => {
    const r = rulesData[id], i = ruleOrder.indexOf(id) + 1;
    const cls = r.action === 'proxy' ? 'proxy' : r.action;
    return `<div class="rule-row ${r.enabled ? '' : 'dimmed'}" data-id="${id}" onclick="openRuleForm('${id}')">
      ${q ? '<span class="cc-rank"></span>' : `<div class="drag-handle cc-grip" onclick="event.stopPropagation()" onpointerdown="startRuleDrag(event,'${id}')">${GRIP_SVG}</div>`}
      <span class="cc-rank">${i}</span>
      <div class="rule-main"><div class="rule-name">${esc(ruleTitle(r))}${r.composite ? '<span class="conn-tag muted">JSON</span>' : ''}${r.action === 'proxy' && r.target && !targetInfo(r.target).ok ? `<span class="conn-tag warn">down → ${fallbackName(ruleFallback(r))}</span>` : ''}</div>
        ${r.name ? `<div class="rule-sub">${esc(ruleSummary(r))}</div>` : ''}</div>
      <span class="rule-action-badge ${cls}">${esc(ruleTargetText(r))}</span>
      ${toggle(r.enabled, `toggleRuleEnabled('${id}')`)}
    </div>`;
  }).join('');

  /* Services: a dropdown of the ones the user added (VPN / Direct each, × removes = back to
     the rules); "+ Add service" offers the rest of the built-in list. Search opens it. */
  const added = SERVICES.filter(([k]) => quickCfg.services[k] !== 'default');
  const shownSvc = added.filter(([, name]) => hit(name));
  const svcOpenNow = svcOpen || !!q;
  const svcRows = shownSvc.map(([key, name]) => { const app = appOfService(key); return `<div class="set-row svc-row" data-svc="${key}"><div class="set-label">${name}${app
      ? `<div class="set-hint svc-app" onclick="openApps();openAppAct('${app.pkg}')">App: ${esc(app.text)} — its own route wins in the app</div>` : ''}</div>
    <div class="seg3">${SVC_STATES.filter(([v]) => v !== 'default').map(([v, l]) => `<button class="${quickCfg.services[key] === v ? 'on ' + v : ''}" onclick="setService('${key}','${v}')">${l}</button>`).join('')}</div>
    <button class="icon-btn ghost svc-del" onclick="setService('${key}','default')" title="Remove">${ICON.close}</button></div>`; }).join('');
  const rest = SERVICES.filter(([k, name]) => quickCfg.services[k] === 'default' && hit(name));
  const svcAdd = q ? '' : svcAddOpen
    ? `<div class="chip-row svc-add">${rest.map(([k, name]) => `<div class="chip" onclick="setService('${k}','vpn')">${name}</div>`).join('') || '<span class="set-hint">All services added</span>'}</div>`
    : `<div class="node-add svc-add-btn" onclick="svcAddOpen=true;renderRules()">+ Add service</div>`;
  const svcBlock = q && !shownSvc.length ? '' : `<div class="rules-label">Services</div><div class="set-group svc-group">
    <div class="set-row svc-head" onclick="svcOpen=!svcOpen;svcAddOpen=false;renderRules()"><div class="set-label">${added.length ? added.length + ' added' : 'None added'}<div class="set-hint">${added.map(s => s[1]).join(', ') || 'Route a known app or site by name'}</div></div>
      <svg class="src-chevron" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" style="${svcOpenNow ? 'transform:rotate(180deg)' : ''}"><polyline points="6 9 12 15 18 9"/></svg></div>
    ${svcOpenNow ? svcRows + svcAdd : ''}</div>`;

  const appsSet = Object.keys(appRules).length;
  const regionSel = `<select class="set-select" id="qr-region" onchange="quickCfg.region=this.value;renderRules()">${REGIONS.map(([c, l]) => `<option value="${c}" ${c === quickCfg.region ? 'selected' : ''}>${l}</option>`).join('')}</select>`;

  document.getElementById('rules-body').innerHTML = `
    <div class="rules-label">Apps</div>
    <div class="set-group"><div class="set-row" style="cursor:pointer" onclick="openApps()"><div class="set-label">Per-app routing<div class="set-hint">${appsSet ? appsSet + ' apps with their own route' : 'No apps set'}</div></div>${CHEVRON_R}</div></div>

    <div class="rules-label">My rules<span class="rules-note">first match wins</span><button class="am-link" onclick="openRuleForm()">+ Add</button></div>
    <div class="set-group" id="rules-list">${ruleRows || `<div class="rules-empty">${q ? 'No rules match' : 'No rules yet'}</div>`}</div>

    <div class="rules-label">Quick rules</div>
    <div class="set-group">
      ${hit('local networks') ? `<div class="set-row" id="qr-lan"><div class="set-label">Local networks direct<div class="set-hint">Always, in Global too · 192.168.x.x, 10.x.x.x, .local, printers, NAS</div></div><span class="order-act">Always</span></div>` : ''}
      ${hit('ads block') ? `<div class="set-row"><div class="set-label">Block ads<div class="set-hint">Known ad and tracker domains</div></div>${toggle(quickCfg.ads, 'quickCfg.ads=!quickCfg.ads;renderRules()')}</div>` : ''}
      ${hit('region direct') ? `<div class="set-row"><div class="set-label">My region direct<div class="set-hint">Its sites and IPs skip the VPN</div></div>${quickCfg.regionOn ? regionSel : ''}${toggle(quickCfg.regionOn, 'quickCfg.regionOn=!quickCfg.regionOn;renderRules()')}</div>` : ''}
    </div>
    ${svcBlock}

    <div class="rules-label">Everything else</div>
    <div class="set-group"><div class="set-row"><div class="seg3 wide">${[['proxy', 'Proxy'], ['direct', 'Direct'], ['block', 'Block']].map(([v, l]) =>
      `<button class="${quickCfg.final === v ? 'on ' + v : ''}" onclick="quickCfg.final='${v}';renderRules()">${l}</button>`).join('')}</div></div></div>

    <div class="rules-label">Target unavailable<span class="rules-note">rules on Default, and apps</span></div>
    <div class="set-group"><div class="set-row"><div class="seg3 wide" id="rules-fallback">${FALLBACKS.map(([v, l]) =>
      `<button class="${quickCfg.fallback === v ? 'on ' + (v === 'main' ? 'proxy' : v) : ''}" onclick="quickCfg.fallback='${v}';renderRules()">${l}</button>`).join('')}</div></div>
      <div class="set-row"><div class="set-hint">When a rule’s profile, chain, subscription or server is off in Nodes, has no working server or was deleted</div></div></div>

    <div class="set-group rules-more">
      <div class="set-row" onclick="openRuleOrder()"><div class="set-label">Final order<div class="set-hint">The list exactly as the engine checks it</div></div>${CHEVRON_R}</div>
      <div class="set-row" onclick="openRuleSets()"><div class="set-label">Rule sets<div class="set-hint">${ruleSets.length} lists · geosite, geoip, your own</div></div>${CHEVRON_R}</div>
      <div class="set-row" onclick="openRuleIO()"><div class="set-label">Import / export<div class="set-hint">sing-box JSON, Clash rules</div></div>${CHEVRON_R}</div>
    </div>`;

  const active = ruleOrder.filter(id => rulesData[id].enabled).length;
  document.getElementById('rulesCardSub').textContent = active + ' rules' + (quickCfg.regionOn ? ' · ' + quickCfg.region + ' direct' : '');
}

function toggleRuleEnabled(id) { rulesData[id].enabled = !rulesData[id].enabled; renderRules(); }
let svcOpen = false, svcAddOpen = false;
function setService(key, v) { quickCfg.services[key] = v; if (v !== 'default') svcAddOpen = false; renderRules(); }
function startRuleDrag(e, id) {
  const rowEl = document.querySelector('#rules-list .rule-row[data-id="' + id + '"]');
  startRowDrag(e, rowEl, '.rule-row', () => ruleOrder, renderRules);
}

/* ── Final order: the whole list as the engine sees it ── */
function effectiveRules() {
  const out = [['Local networks', 'always first, in Global too', 'Direct']];
  const apps = Object.keys(appRules).length;
  if (apps) out.push(['Apps', apps + ' apps with their own route', 'mixed']);
  ruleOrder.filter(id => rulesData[id].enabled).forEach(id => { const r = rulesData[id]; out.push([ruleTitle(r), r.name ? ruleSummary(r) : '', ruleTargetText(r)]); });
  if (quickCfg.ads) out.push(['Ads', 'quick rule', 'Block']);
  SERVICES.filter(([k]) => quickCfg.services[k] !== 'default').forEach(([k, n]) => out.push([n, 'service', quickCfg.services[k] === 'vpn' ? 'Proxy' : 'Direct']));
  if (quickCfg.regionOn) out.push(['Region ' + quickCfg.region, 'geosite + geoip', 'Direct']);
  out.push(['Everything else', '', { proxy: 'Proxy', direct: 'Direct', block: 'Block' }[quickCfg.final]]);
  return out;
}
function openRuleOrder() {
  document.getElementById('ruleorder-list').innerHTML = effectiveRules().map(([t, s, a], i) =>
    `<div class="set-row order-row"><span class="cc-rank">${i + 1}</span><div class="set-label">${esc(t)}${s ? `<div class="set-hint">${esc(s)}</div>` : ''}</div><span class="order-act">${esc(a)}</span></div>`).join('');
  openSheet('ruleorder');
}

/* ── Test an address: which rule catches it and where it goes ── */
// names only a local network resolves: core/lib/src/routing.dart lanSuffixes
const LAN_SUFFIXES = ['local', 'localhost', 'lan', 'home.arpa'];
const PRIVATE_NETS = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16'];
function inCidr(ip, c) {
  if (c.includes('-')) { const [a, b] = c.split('-'); return ip2n(ip) >= ip2n(a) && ip2n(ip) <= ip2n(b); }
  const [a, p = 32] = c.split('/');
  const size = 2 ** (32 - p);
  return Math.floor(ip2n(ip) / size) === Math.floor(ip2n(a) / size);
}
const onDomain = (host, d) => host === d || host.endsWith('.' + d);
const hostOfService = key => (SERVICES.find(s => s[0] === key) || [, , []])[2];
function groupMatches(key, d, t) {
  const v = d.v;
  const any = (f, fn) => (v[f] || []).some(fn);
  let m = false;
  if (key === 'domain' && !t.ip) m = any('domain', x => x.startsWith('*.') ? onDomain(t.host, x.slice(2)) : t.host === x)
    || any('domain_suffix', x => onDomain(t.host, x.replace(/^\./, ''))) || any('domain_keyword', x => t.host.includes(x))
    || any('domain_regex', x => new RegExp(x).test(t.host)) || any('geosite', x => hostOfService(x).some(h => onDomain(t.host, h)));
  if (key === 'ip' && t.ip) m = any('ip_cidr', x => !x.includes(':') && inCidr(t.host, x)) || (d.flag && PRIVATE_NETS.some(c => inCidr(t.host, c)));
  if (key === 'port') m = any('port', x => { const [a, b = a] = x.split('-'); return t.port >= +a && t.port <= +b; });
  if (key === 'network') m = (!v.network || !v.network.length || v.network.includes('tcp')) && (!v.protocol || !v.protocol.length || v.protocol.includes(t.port === 443 ? 'tls' : 'http'));
  return d.not ? !m : m;
}
function testAddress(raw) {
  const s = raw.trim().toLowerCase().replace(/^\w+:\/\//, '').split('/')[0];
  if (!s) return null;
  const app = APPS.find(a => a.name.toLowerCase() === s || a.pkg === s);
  if (app) {
    const a = appRules[app.pkg];
    return a ? { rule: 'Apps → ' + app.name, to: appActText(a) } : { rule: 'No app rule for ' + app.name, to: 'goes by the rules below' };
  }
  const [host, port = '443'] = s.split(':');
  const t = { host, port: +port, ip: isIp4(host) };
  if (t.ip ? PRIVATE_NETS.some(c => inCidr(host, c)) : LAN_SUFFIXES.some(d => onDomain(host, d))) return { rule: 'Local networks (always)', to: 'Direct' };
  for (const id of ruleOrder) {
    const r = rulesData[id];
    if (!r.enabled) continue;
    if (r.composite) continue;
    const gs = Object.entries(r.groups);
    if (gs.length && gs.every(([k, d]) => groupMatches(k, d, t))) return { rule: '#' + (ruleOrder.indexOf(id) + 1) + ' ' + ruleTitle(r), to: ruleTargetText(r).replace('→ ', '') };
  }
  if (quickCfg.ads && ADS.some(d => onDomain(host, d))) return { rule: 'Block ads', to: 'Block' };
  const svc = SERVICES.find(([k, , ds]) => quickCfg.services[k] !== 'default' && ds.some(d => onDomain(host, d)));
  if (svc) return { rule: 'Service ' + svc[1], to: quickCfg.services[svc[0]] === 'vpn' ? 'Proxy' : 'Direct' };
  const reg = REGIONS.find(([c]) => c === quickCfg.region);
  if (quickCfg.regionOn && !t.ip && reg[2].some(tld => host.endsWith('.' + tld))) return { rule: 'My region direct (' + reg[0] + ')', to: 'Direct' };
  return { rule: 'Everything else', to: { proxy: 'Proxy', direct: 'Direct', block: 'Block' }[quickCfg.final] };
}
function openRuleTest() {
  document.getElementById('rt-result').innerHTML = '';
  openSheet('ruletest');
  const i = document.getElementById('rt-input'); i.value = ''; i.focus();
}
function runRuleTest() {
  const res = testAddress(document.getElementById('rt-input').value);
  document.getElementById('rt-result').innerHTML = !res ? '' :
    `<div class="rt-rule">${esc(res.rule)}</div><div class="rt-to">→ ${esc(res.to)}</div>`;
}

/* ── Import / export ── */
let ioTab = 'export', ioFormat = 'json';
function openRuleIO() { ioTab = 'export'; ioFormat = 'json'; renderRuleIO(); openSheet('ruleio'); }
function setRuleIO(tab, fmt) { if (tab && tab !== ioTab) { ioTab = tab; document.getElementById('io-text').value = ''; } if (fmt) ioFormat = fmt; renderRuleIO(); }
const CLASH_OUT = r => r.action === 'direct' ? 'DIRECT' : r.action === 'block' ? 'REJECT' : r.target ? targetName(r.target) : 'PROXY';
const CLASH_TYPES = { domain: 'DOMAIN', domain_suffix: 'DOMAIN-SUFFIX', domain_keyword: 'DOMAIN-KEYWORD', domain_regex: 'DOMAIN-REGEX', geosite: 'GEOSITE', ip_cidr: 'IP-CIDR', geoip: 'GEOIP', port: 'DST-PORT', source_ip_cidr: 'SRC-IP-CIDR', source_port: 'SRC-PORT', process: 'PROCESS-NAME' };
function exportClash() {
  return ruleOrder.map(id => {
    const r = rulesData[id], gs = Object.entries(r.groups);
    const vals = gs.length === 1 && !gs[0][1].not && !gs[0][1].flag ? Object.entries(gs[0][1].v).filter(([f]) => CLASH_TYPES[f]) : null;
    if (r.composite || !vals || vals.length !== Object.keys(gs[0][1].v).length) return '# skipped (only sing-box JSON can hold it): ' + ruleTitle(r);
    return vals.flatMap(([f, list]) => list.map(v => CLASH_TYPES[f] + ',' + v + ',' + CLASH_OUT(r))).join('\n');
  }).join('\n');
}
function renderRuleIO() {
  const kept = ioTab === 'import' && document.getElementById('io-text') ? document.getElementById('io-text').value : '';
  document.querySelectorAll('#sh-ruleio .sheet-tab').forEach(t => t.classList.toggle('active', t.dataset.tab === ioTab));
  const text = ioTab === 'export' ? (ioFormat === 'json' ? JSON.stringify(ruleOrder.map(id => ruleJson(rulesData[id])), null, 2) : exportClash()) : kept;
  document.getElementById('ruleio-body').innerHTML = `
    <div class="form-group"><div class="chip-row" style="padding:0">${[['json', 'sing-box JSON'], ['clash', 'Clash rules']].map(([v, l]) => `<div class="chip ${ioFormat === v ? 'active' : ''}" onclick="setRuleIO(null,'${v}')">${l}</div>`).join('')}</div></div>
    <div class="form-group"><textarea class="form-input code-area" id="io-text" ${ioTab === 'export' ? 'readonly' : ''} placeholder="${ioFormat === 'json' ? '[{ &quot;domain_suffix&quot;: [&quot;example.com&quot;], &quot;outbound&quot;: &quot;direct&quot; }]' : 'DOMAIN-SUFFIX,example.com,DIRECT'}">${esc(text)}</textarea>
      <div class="set-hint warn" id="io-err"></div></div>
    ${ioTab === 'import' ? `<div class="set-group"><div class="set-row" onclick="toast('Picks a subscription with Clash rules — coming with the targets rework')"><div class="set-label">From a subscription<div class="set-hint">Rules shipped in a Clash YAML subscription</div></div><span class="soon-tag">stub</span>${CHEVRON_R}</div></div>` : ''}`;
  document.getElementById('io-action').textContent = ioTab === 'export' ? 'Copy' : 'Import';
}
function ruleIOAction() {
  const text = document.getElementById('io-text').value;
  if (ioTab === 'export') { navigator.clipboard && navigator.clipboard.writeText(text).catch(() => {}); toast('Copied'); return; }
  const err = document.getElementById('io-err');
  let rules;
  try { rules = ioFormat === 'json' ? parseJsonRules(text) : parseClash(text); }
  catch (e) { err.textContent = e.message; return; }
  if (!rules.length) { err.textContent = 'Nothing to import'; return; }
  rules.forEach(r => { r.id = 'r' + (ruleSeq++); rulesData[r.id] = r; ruleOrder.push(r.id); });
  closeSheet('ruleio');
  renderRules();
  toast('Imported ' + rules.length + ' rule' + (rules.length > 1 ? 's' : ''));
}
function parseJsonRules(text) {
  let o;
  try { o = JSON.parse(text); } catch (e) { throw new Error(jsonErrorText(text, e)); }
  return (Array.isArray(o) ? o : [o]).map(ruleFromJson);
}
function parseClash(text) {
  const byType = Object.fromEntries(Object.entries(CLASH_TYPES).map(([f, t]) => [t, f]));
  const lines = text.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
  // MATCH,POLICY is Clash's catch-all: it becomes Everything else, not a rule.
  const match = lines.find(l => /^MATCH,/i.test(l));
  if (match) { const P = match.split(',')[1].trim().toUpperCase(); quickCfg.final = P === 'DIRECT' ? 'direct' : P === 'REJECT' ? 'block' : 'proxy'; }
  return lines.filter(l => l !== match).map((l, i) => {
    const [type, value, pol] = l.split(',').map(s => s && s.trim());
    const f = byType[(type || '').toUpperCase()] || (type === 'IP-CIDR6' ? 'ip_cidr' : null);
    if (!f || !value || !pol) throw new Error('Line ' + (i + 1) + ': expected TYPE,value,POLICY');
    const g = RULE_GROUPS.find(g => (g.fields || []).some(x => x[0] === f));
    const P = pol.toUpperCase();
    return newRule({ groups: { [g.key]: { not: false, v: { [f]: [value] } } }, action: P === 'DIRECT' ? 'direct' : P === 'REJECT' ? 'block' : 'proxy' });
  });
}
const newRule = o => Object.assign({ id: '', name: '', enabled: true, action: 'proxy', target: '', block: 'drop', fallback: 'default', dns: 'auto', groups: {} }, o);

/* ── Rule sets: built-in geo lists + remote ones ── */
function openRuleSets() { renderRuleSets(); openSheet('rulesets'); }
function renderRuleSets() {
  document.getElementById('rulesets-list').innerHTML = ruleSets.map(s => `<div class="set-row rs-row" onclick="openRsForm('${s.id}')">
    <div class="set-label"><span class="mono">${esc(s.name)}</span>${s.builtin ? '<span class="conn-tag muted">built-in</span>' : ''}
      <div class="set-hint">${s.builtin ? '' : s.format.toUpperCase() + ' · '}every ${fmtEvery(s.every)} · via ${s.via === 'vpn' ? 'VPN' : 'direct'} · ${s.updated}</div></div>${CHEVRON_R}</div>`).join('');
}
let rsEditing = null, rsDraft = null;
function openRsForm(id) {
  rsEditing = id || null;
  rsDraft = Object.assign({ name: '', url: '', format: 'srs', via: 'vpn', every: 86400 }, id ? ruleSets.find(s => s.id === id) : {});
  document.getElementById('rsTitle').textContent = id ? 'Rule set' : 'Add rule set';
  document.getElementById('rs-name').value = rsDraft.name;
  document.getElementById('rs-url').value = rsDraft.url;
  document.getElementById('rs-name').disabled = document.getElementById('rs-url').disabled = !!rsDraft.builtin;
  document.getElementById('rs-delete').style.display = id && !rsDraft.builtin ? '' : 'none';
  renderRsForm();
  openSheet('rsform');
}
function renderRsForm() {
  const chips = (key, opts) => opts.map(([v, l]) => `<div class="chip ${rsDraft[key] === v ? 'active' : ''}" onclick="rsDraft.${key}='${v}';renderRsForm()">${l}</div>`).join('');
  document.getElementById('rs-format').innerHTML = rsDraft.builtin ? '<span class="set-hint">SRS (binary)</span>' : chips('format', [['srs', 'SRS (binary)'], ['json', 'JSON (source)']]);
  document.getElementById('rs-via').innerHTML = chips('via', [['vpn', 'VPN'], ['direct', 'Direct']]);
  document.getElementById('rs-every').innerHTML = fmtEvery(rsDraft.every) + CHEVRON_R;
}
function saveRsForm() {
  const name = document.getElementById('rs-name').value.trim(), url = document.getElementById('rs-url').value.trim();
  if (!rsDraft.builtin) {
    if (!/^[a-z0-9_-]+$/i.test(name)) { toast('Name: letters, digits, - and _'); return; }
    if (ruleSets.some(s => s.name === name && s.id !== rsEditing)) { toast('A rule set with this name exists'); return; }
    if (!/^https?:\/\/\S+$/.test(url)) { toast('URL: https://…'); return; }
  }
  Object.assign(rsDraft, rsDraft.builtin ? {} : { name, url });
  if (rsEditing) Object.assign(ruleSets.find(s => s.id === rsEditing), rsDraft);
  else ruleSets.push(Object.assign(rsDraft, { id: 'rs' + (rsSeq++), updated: 'never' }));
  closeSheet('rsform');
  renderRuleSets(); renderRules();
}
function deleteRuleSet() {
  const s = ruleSets.find(x => x.id === rsEditing);
  const users = ruleOrder.filter(id => ((rulesData[id].groups.domain || { v: {} }).v.rule_set || []).includes(s.name));
  if (users.length) { toast('Used in rule ' + users.map(id => '#' + (ruleOrder.indexOf(id) + 1)).join(', ') + ' — remove it there first'); return; }
  ruleSets = ruleSets.filter(x => x !== s);
  closeSheet('rsform');
  renderRuleSets(); renderRules();
}
