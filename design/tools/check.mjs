// Smoke tests and screenshots for design/main_screen.html (headless Chromium).
//
//   node design/tools/check.mjs                 run all checks, print one line per failure
//   node design/tools/check.mjs shot home dock  screenshots into design/.shots/
//        options: --theme original|karing|github  --scale 1  --width 400 --height 800
//                 --out <dir> (instead of design/.shots)  --files (with --grid: keep the single shots too)
//                 --grid-name <name> (grid file name, default grid); preset "all" = every preset
//        presets: see SHOTS below
//
// Playwright is resolved from the global npm root (pre-installed in the cloud env).
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const PAGE = 'file://' + join(root, 'main_screen.html');
const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(join(execSync('npm root -g').toString().trim(), 'playwright')); }

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : def; };
const positional = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));

// Deterministic runs: the mock (genNodes, mockPing, backend timings) draws on Math.random.
// Seeding it (env CHECK_SEED, default fixed) makes a failure reproducible instead of a
// 1-in-N flake — replay the same seed to get the same dead servers / delays / churn every time.
const CHECK_SEED = Number(process.env.CHECK_SEED) || 1;
function seedScript(seed) {
  return `(() => {
    let s = ${seed} >>> 0 || 1;
    Math.random = function () {
      s |= 0; s = (s + 0x6D2B79F5) | 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  })();`;
}

async function openPage(browser, { width = 400, height = 800, scale = 1, theme, lang } = {}) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
  page.setDefaultTimeout(5000);
  page.errors = [];
  page.on('pageerror', e => page.errors.push(e.message));
  // Fonts come from Google; offline they only slow the load down.
  await page.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await page.addInitScript(seedScript(CHECK_SEED));
  await page.goto(PAGE);
  await page.evaluate(() => { try { localStorage.clear(); } catch (e) {} });
  if (theme) await page.evaluate(t => applyTheme(t), theme);
  if (lang && lang !== 'en') await page.evaluate(l => setGenCfg('lang', l), lang);   // docs/i18n.md
  await page.waitForTimeout(350);   // let initial transitions settle
  return page;
}

const settle = page => page.waitForTimeout(400);
// The mockup starts with no quick-rule services (a real first run); checks and shots that need some
// set them up here: all others Default, a few on VPN, `over` on top ({ key: 'vpn' | 'direct' | 'default' }).
const seedServices = (page, over = {}) => page.evaluate(over => {
  SERVICES.forEach(([k]) => { quickCfg.services[k] = 'default'; });
  Object.assign(quickCfg.services, { telegram: 'vpn', youtube: 'vpn', chatgpt: 'vpn', instagram: 'vpn' }, over);
}, over);
const tab = (page, name) => page.click(`.nav-btn[data-tab=${name}]`);
// Raw open: scrolled up to the top, a few new lines (error, warnings, info) arrive below and stay unread.
const logsRawUnread = async page => {
  await page.evaluate(() => { document.getElementById('logScroll').scrollTop = 0; });
  await page.waitForTimeout(250);
  await page.evaluate(async () => {
    [['info', 'inbound/mixed[mixed-in]: inbound connection to discord.com:443'], ['warn', 'outbound/urltest[proxy]: context deadline exceeded'], ['error', 'connection: open outbound connection: dial tcp 185.22.14.61:443: i/o timeout'], ['info', 'router: found process path: chrome.exe'], ['warn', 'dns: exchange failed for example.org']]
      .forEach(([lvl, msg]) => mockLogAdd('sing-box', lvl, msg));
    pollLogs();
  });
  await page.waitForTimeout(300);
};
// Back button (60-sheets.js): syncBackHistory runs in setTimeout 0, so give it a moment
// to land before history.back(), and a moment after for goBack()'s re-render + any
// corrective pushState to settle before the next assertion or back() call.
const preBack = p => p.waitForTimeout(100);
// 400ms, not just past the popstate: a closed sheet keeps `visibility` for its .32s slide-down
// transition (css/40-sheets.css .sheet:not(.open)), so isVisible() still sees it briefly.
async function backAndSettle(p) { await preBack(p); await p.goBack(); await p.waitForTimeout(400); }

/* ═══════════════ SCREENSHOT PRESETS ═══════════════ */

// Live connections presets: open the sheet on the mock connections, then run fn in the page
const connBase = async (p, fn) => { await p.evaluate(() => backend.traffic().then(t => { traffic = t; openSheet('connections'); renderTraffic(); })); await p.evaluate(fn); await settle(p); };
const SHOTS = {
  home:       async p => {},
  nodes:      async p => { await tab(p, 'nodes'); },
  'nodes-open': async p => { await tab(p, 'nodes'); await p.evaluate(() => { expandState[sourceOrder[0]] = true; goneOpen.add('nodes:' + sourceOrder[0]); renderNodes(); document.querySelector('#view-nodes .scroll').scrollTop = 520; }); },
  settings:   async p => { await tab(p, 'settings'); },
  dock:       async p => ({ clip: await clipOf(p, '.dock', 60) }),
  'broken': async p => { await p.evaluate(() => { sourcesData.src4.enabled = false; renderAll(); openProfiles(); }); await settle(p); },
  'dock-chain': async p => { await p.evaluate(() => { selectConnect('sc1'); }); return { clip: await clipOf(p, '.dock', 60) }; },
  'dock-profile': async p => { await p.evaluate(() => { setConnectMode('profiles'); selectConnect('default'); }); return { clip: await clipOf(p, '.dock', 60) }; },
  'connections': async p => { await p.evaluate(() => backend.traffic().then(t => { traffic = t; renderTraffic(); openSheet('connections'); })); await settle(p); },
  'sys-on': async p => { await p.evaluate(() => setSysProxy(true)); await p.waitForTimeout(400); return { clip: await clipOf(p, '.segments-card', 10) }; },
  'sys-off': async p => { return { clip: await clipOf(p, '.segments-card', 10) }; },
  'dock-off': async p => { await p.click('#powerBtn'); await p.waitForTimeout(1000); return { clip: await clipOf(p, '.dock', 60) }; },
  profiles:   async p => { await p.click('.dock-profile'); await settle(p); },
  'profiles-full': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); }); await settle(p); },
  'source-entry': async p => { await p.evaluate(() => { openProfiles(); openSourceEntry('src1'); }); await settle(p); },
  'simple-chain': async p => { await p.evaluate(() => { openProfiles(); openEditChain('sc1'); toggleCcOpen('out', chainDraft.outId); }); await settle(p); },
  'chain-priority': async p => { await p.evaluate(() => { openProfiles(); openEditChain('sc1'); toggleCcOpen('out', chainDraft.outId); }); await settle(p); },
  'gone': async p => { await p.evaluate(() => { openProfiles(); goneOpen.add('se:src1'); openSourceEntry('src1'); document.querySelector('#sh-sourceentry .sheet-body').scrollTop = 9999; }); await settle(p); },
  'nothing-ticked': async p => { await p.evaluate(() => { openProfiles(); openEditChain('sc1'); toggleCcOpen('in', 'src4'); setChainNodesAll('in'); }); await settle(p); },
  'profile-edit': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditProfile('gaming'); }); await settle(p); },
  'drag-mid': async p => { await p.evaluate(() => { openProfiles(); setRouteEdit(true); }); await settle(p);
    const g = await p.locator('.conn-row >> nth=0').locator('.drag-handle').boundingBox();
    const r = await p.locator('.conn-row >> nth=2').boundingBox();
    await p.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await p.mouse.down();
    await p.mouse.move(g.x + g.width / 2, r.y + r.height * .7, { steps: 10 }); await p.waitForTimeout(300); },
  'chain-groups': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditChain('cpdefault'); toggleCcOpen('out', chainDraft.outId); testChainRoute(); }); await p.waitForFunction(() => !chainTest.running, null, { timeout: 30000 });
    await p.evaluate(() => { chainTest.view = 'entry'; const g = chainTest.pairs[0]; if (g) chainTest.open.add(serverKey(g.entry)); renderChainTest(); document.querySelector('#sh-createchain .sheet-body').scrollTop = 9999; }); await settle(p); },
  'chain-edit': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditChain('cpdefault'); testChainRoute(); }); await p.waitForFunction(() => !chainTest.running, null, { timeout: 30000 }); await settle(p); },
  automode:   async p => { await p.click('#autoCard'); await settle(p); },
  'node-off': async p => { await tab(p, 'nodes'); await p.evaluate(() => { sourcesData.src2.disabledNodes.push('n2'); expandState.src2 = true; renderNodes(); document.querySelector('#view-nodes .scroll').scrollTop = 150; }); },
  'broken-node': async p => { await p.evaluate(() => { sourcesData.src4.disabledNodes = ['n0', 'n1']; setConnectMode('profiles'); openProfiles(); }); await settle(p); },
  'nodes-edit': async p => { await tab(p, 'nodes'); await p.evaluate(() => { expandState.src2 = true; setNodesEdit(true); }); },
  'settings-general': async p => { await tab(p, 'settings'); await p.evaluate(() => openSheet('setgeneral')); await settle(p); },
  'nodes-edit-chain': async p => { await tab(p, 'nodes'); await p.evaluate(() => { expandState.sc1 = true; setNodesEdit(true); document.querySelector('#nodes-list .entry-card[data-id=sc1]').scrollIntoView(); }); },
  'entry-priority': async p => { await p.evaluate(() => { openProfiles(); sourcesData.src3.pickMode = 'priority'; openSourceEntry('src3'); }); await settle(p); },
  'profile-priority': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditProfile('gaming'); document.querySelector('#sh-createprofile .sheet-body').scrollTop = 9999; }); await settle(p); },
  interval: async p => { await p.evaluate(() => { openAutoMode(); openIntervalDialog('subsEvery'); }); await settle(p); },
  'settings-auto': async p => { await p.evaluate(() => openAutoMode()); await settle(p); },
  'settings-look': async p => { await p.evaluate(() => { switchTab('settings'); openSheet('setlook'); }); await settle(p); },
  help: async p => { await p.evaluate(() => { openProfiles(); openSourceEntry('src1'); openHelp('sourceentry'); }); await settle(p); },
  'delete-confirm': async p => { await tab(p, 'nodes'); await p.evaluate(() => confirmDeleteSource('src2')); await settle(p); },
  addmenu:    async p => { await tab(p, 'nodes'); await p.click('.icon-btn.primary'); await settle(p); },
  srcform:    async p => { await tab(p, 'nodes'); await p.evaluate(() => { openSrcForm(); toggleSrcAdvanced(true); }); await settle(p); },
  nodeform:   async p => { await tab(p, 'nodes'); await p.evaluate(() => openNodeForm()); await settle(p); },
  actions:    async p => { await tab(p, 'nodes'); await p.click('.src-card >> nth=0 >> button[title=More]'); await settle(p); },
  rules:      async p => { await seedServices(p); await p.evaluate(() => openRules()); await settle(p); },
  'rules-more': async p => { await seedServices(p); await p.evaluate(() => { openRules(); document.getElementById('rules-body').scrollTop = 9999; }); await settle(p); },
  'rule-form': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); }); await settle(p); },
  'rule-new':  async p => { await p.evaluate(() => { openRules(); openRuleForm(); rfAddField('ip', 'ip_cidr'); rfAddValues('domain', 'domain_suffix', 'youtube.com, bad domain', false); }); await settle(p); },
  // a rule with an IP condition: the "IP conditions only in TUN" block, the state of Resolve for IP rules, the link
  'rule-ip-resolve': async p => { await p.evaluate(() => { openRules(); openRuleForm(); rfAddField('ip', 'ip_cidr'); rfAddValues('ip', 'ip_cidr', '10.0.0.0/8, 192.168.0.0/16', false); document.querySelector('.rf-ip').scrollIntoView({ block: 'end' }); }); await settle(p); },
  // Domains + IP (a logical AND in JSON) with an except card; the JSON tab, as the form wrote it
  'rule-json': async p => { await p.evaluate(() => { openRules(); openRuleForm(); rfAddValues('domain', 'domain_suffix', 'youtube.com', false); rfAddField('ip', 'ip_cidr'); rfAddValues('ip', 'ip_cidr', '10.0.0.0/8', false); rfAddField('port', 'port'); rfAddValues('port', 'port', '443', false); ruleDraft.groups.port.not = true; setRfTab('json'); }); await settle(p); },
  // + Condition open: every field not on the form yet, under its card's title
  'rule-add': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); rfAddOpen = true; renderRuleForm(); document.querySelector('.rf-add').scrollIntoView(); }); await settle(p); },
  // Settings → DNS opened from the rule form's link: above the form
  'rule-dns-over': async p => { await p.evaluate(() => { openRules(); openRuleForm(); rfAddField('ip', 'ip_cidr'); rfAddValues('ip', 'ip_cidr', '10.0.0.0/8', false); rfOpenDnsResolve(); }); await p.waitForTimeout(700); },
  'rule-test': async p => { await p.evaluate(() => { openRules(); openRuleTest(); document.getElementById('rt-input').value = 'discord.com'; runRuleTest(); }); await settle(p); },
  'rule-order': async p => { await seedServices(p); await p.evaluate(() => { openRules(); openRuleOrder(); }); await settle(p); },
  'rule-io':   async p => { await seedServices(p); await p.evaluate(() => { openRules(); openRuleIO(); setRuleIO('export', 'clash'); }); await settle(p); },
  'rule-sets': async p => { await p.evaluate(() => { openRules(); openRuleSets(); }); await settle(p); },
  apps:       async p => { await seedServices(p); await p.evaluate(() => { openRules(); openApps(); }); await settle(p); },
  'app-act':  async p => { await seedServices(p); await p.evaluate(() => { openRules(); openApps(); openAppAct('org.telegram.messenger'); appDraft.target = 'src:src1'; appDraft.fallback = 'block'; renderAppAct(); }); await settle(p); },
  'app-split': async p => { await seedServices(p); await p.evaluate(() => { openRules(); openApps(); openAppAct('org.telegram.messenger'); appDraft.split = true; appDraft.act = 'proxy'; appDraft.target = 'src:src1'; appDraft.fallback = 'block'; appDraft.udp.act = 'block'; renderAppAct(); }); await settle(p); },
  'settings-dns': async p => { await p.evaluate(() => openDnsSettings()); await settle(p); },
  // Resolve for IP rules on a direct server (the leak warning), scrolled to and flashed as the rule form's link does
  'dns-resolve': async p => { await p.evaluate(() => { dnsCfg.resolve = 'local'; openDnsSettings('dnsResolve'); }); await settle(p); },
  // one server fails its checks, the next one is in use (the mock: from the pings)
  'dns-failover': async p => { await p.evaluate(async () => { openDnsSettings(); await wait(1200); dnsPing.remote = -1; dnsPing.local = 12; dnsPing.google = 30; renderDns(); }); await settle(p); },
  'dns-form': async p => { await p.evaluate(() => { openDnsSettings(); openDnsForm(); }); await settle(p); },
  'settings-conn': async p => { await p.evaluate(() => { switchTab('settings'); openSheet('setconn'); }); await settle(p); },
  'kill-closed-confirm': async p => { await p.evaluate(() => { connCfg.killSwitch = true; genCfg.launchAtStartup = genCfg.connectOnLaunch = true; switchTab('settings'); openSheet('setconn'); renderConnSettings(); confirmClosedKill(); }); await settle(p); },
  'kill-off-confirm': async p => { await p.evaluate(() => { connCfg.killSwitch = true; connected = true; switchTab('settings'); openSheet('setconn'); renderConnSettings(); toggleKillSwitch(); }); await settle(p); },
  // password on the proxy port: a login and password shown, copy buttons (fixed values: the shot must not change)
  'conn-proxy-auth': async p => { await p.evaluate(() => { connCfg.sysProxy = true; connCfg.proxyAuth = true; connCfg.proxyUser = 'k7m2xq9d'; connCfg.proxyPass = 'Kq7mT2vXp9Rd4WzN8sYb'; switchTab('settings'); openSheet('setconn'); renderConnSettings(); }); await settle(p); },
  'conn-ipv6': async p => { await p.evaluate(() => { connCfg.ipv6 = true; switchTab('settings'); openSheet('setconn'); renderConnSettings(); }); await settle(p); },
  'kill-on': async p => { await p.evaluate(() => { connCfg.killSwitch = true; connCfg.killOnDisconnect = true; switchTab('settings'); openSheet('setconn'); renderConnSettings(); }); await settle(p); },
  'core-down-kept': async p => { await p.evaluate(() => { connected = true; vpn.down = { since: Date.now() - 83e3, attempt: 4, proxy: 'kept' }; renderConnState(); }); await settle(p); },
  'core-down-direct': async p => { await p.evaluate(() => { connected = true; vpn.down = { since: Date.now() - 250e3, attempt: 9, proxy: 'removed' }; renderConnState(); }); await settle(p); },
  'kill-blocking': async p => { await p.evaluate(() => { connected = false; vpn.blocking = { since: Date.now() - 40e3, reason: 'disconnect', proxy: 'kept' }; renderConnState(); }); await settle(p); },
  'core-recovering': async p => { await p.evaluate(() => { connected = true; vpn.recovering = { attempt: 1, next: 4000, code: 1 }; renderConnState(); }); await settle(p); },
  'settings-notif': async p => { await p.evaluate(() => { switchTab('settings'); openSheet('setnotif'); }); await settle(p); },
  'nodes-profiles': async p => { await tab(p, 'nodes'); await p.evaluate(() => { setNodesTab('profiles'); expandState.default = true; renderNodes(); }); await settle(p); },
  'nodes-swipe': async p => { await tab(p, 'nodes'); await p.evaluate(() => { document.getElementById('view-nodes').classList.add('swiping'); renderNodesTabs(-170); }); },
  'route-open': async p => { await p.evaluate(() => { openProfiles(); const id = visibleOrder().find(x => sourcesData[x]); sourcesData[id].pickMode = 'priority'; toggleRouteRow(id); }); await settle(p); },
  'no-auto': async p => { await p.evaluate(() => { visibleOrder().forEach(id => { connectEntry(id).inAuto = false; }); connected = false; renderConnState(); updateMainConnectCard(); toggleMain(); }); await settle(p); },
  'no-auto-dock': async p => { await p.evaluate(() => { visibleOrder().forEach(id => { connectEntry(id).inAuto = false; }); connected = false; renderConnState(); updateMainConnectCard(); }); await settle(p); },
  'ping-testing': async p => { await p.evaluate(() => { openProfiles(); const id = autoOrder()[0]; toggleRouteRow(id);
    unitPickRefs(id).slice(0, 2).forEach(r => pingCache.set(pingKey(r.node), { ms: 'testing', at: Date.now() })); renderConnects(); }); await settle(p); },
  'route': async p => { await p.evaluate(() => { openProfiles(); }); await settle(p); },
  'route-pin': async p => { await p.evaluate(() => { openProfiles(); const id = visibleOrder().find(x => sourcesData[x] && unitRefs(x).length > 1); toggleRouteRow(id); pinRouteNode(id, refKey(unitRefs(id)[1])); }); await settle(p); },
  'entry-delete': async p => { await tab(p, 'nodes'); await p.evaluate(() => { setNodesTab('profiles'); openEditProfile('work'); confirmDeleteEntry('work'); }); await settle(p); },
  'target-picker': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); openTargetPicker(rulesData.r2.target, () => {}); tpOpen.clear(); renderTargetPicker(); }); await settle(p); },
  'target-picker-open': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); openTargetPicker(rulesData.r2.target, () => {}); tpOpen.clear(); tpOpen.add('src:src2'); renderTargetPicker(); pickTarget('node:src2::' + sourcesData.src2.nodes[1].id); }); await settle(p); },
  'rule-fallback': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); document.querySelector('#sh-ruleform .sheet-body').scrollTop = 9999; }); await settle(p); },
  'rules-services': async p => { await seedServices(p); await p.evaluate(() => { openRules(); svcOpen = true; svcAddOpen = true; renderRules(); document.querySelector('.svc-group').scrollIntoView(); }); await settle(p); },
  'text-large': async p => { await p.evaluate(() => { applyScale(UI_SCALE_MAX); openProfiles(); }); await settle(p); },
  'text-large-rule': async p => { await p.evaluate(() => { applyScale(UI_SCALE_MAX); openRules(); openRuleForm('r2'); document.querySelector('#sh-ruleform .sheet-body').scrollTop = 9999; }); await settle(p); },
  more:       async p => { await tab(p, 'nodes'); await p.evaluate(() => openNodesMore()); await settle(p); },
  // Logs tab, share / QR, Data, latency URL, empty catalog, source error, connections tools
  logs:       async p => { await tab(p, 'logs'); await p.waitForTimeout(600); },   // Events, at the bottom
  // Raw, scrolled up to old lines while new ones arrive below: unread badges on the chips
  'logs-raw': async p => { await tab(p, 'logs'); await p.evaluate(() => setLogTab('raw')); await p.waitForTimeout(500); await logsRawUnread(p); },
  // the filter sheet: Auto and Subscriptions unfolded, one type off (the Auto box goes half), Show my actions on
  'logs-filter': async p => { await tab(p, 'logs'); await p.waitForTimeout(400); await p.evaluate(() => { openEvFilter(); evFilterFold('auto'); evFilterFold('sub'); evToggleType('auto/fastest'); evToggleType('sub/updated'); setEvProblems(true); logCfg.showOwn = true; renderEvFilter(); }); await settle(p); },
  // a folded row (×3 repeats) opened: its times and every field
  'logs-event-open': async p => { await tab(p, 'logs'); await p.waitForTimeout(500); await p.evaluate(() => { const r = document.querySelector('#evList .ev-row.cat-site'); evToggle(+r.dataset.key); r.scrollIntoView({ block: 'center' }); }); await settle(p); },
  // "does not open": the failing entry and the working one as two rows with Open, Create rule / In raw log below
  'logs-blocked': async p => { await tab(p, 'logs'); await p.waitForTimeout(500); await p.evaluate(() => { const r = document.querySelector('#evList .ev-row.cat-site'); r.scrollIntoView({ block: 'center' }); }); await settle(p); },
  // "does not open" on every route: the entry in use and the route tried as ⚠️ rows, then the same with the muted "No other working route to try"
  'logs-unreachable': async p => { await tab(p, 'logs'); await p.waitForTimeout(500); await p.evaluate(() => { const e = evState.list.find(x => x.type === 'unreachable' && (x.data.tried || []).length); const r = [...document.querySelectorAll('#evList .ev-row')].find(x => x.dataset.ids.split(',').includes(String(e.id))); r.scrollIntoView({ block: 'start' }); }); await settle(p); },
  // scrolled up, two events arrive: the view stays, the pill counts them
  'logs-new-below': async p => { await tab(p, 'logs'); await p.waitForTimeout(500); await p.evaluate(() => { document.getElementById('evScroll').scrollTop = 0; }); await p.waitForTimeout(200);
    await p.evaluate(() => { const [a, b] = visibleOrder(); mockEventAdd('auto', 'switched', 'info', { from: a, to: b, reason: 'failover', fails: 3 }); mockEventAdd('site', 'blocked', 'warn', { host: 'discord.com', dest: 'discord.com:443', entry: a, via: b }); return pollEvents(); }); await p.waitForTimeout(400); },
  // an unseen error and warning: both dots on the Logs tab
  'nav-dots': async p => { await p.evaluate(() => { mockEventAdd('core', 'crashed', 'error', { code: 1 }); mockEventAdd('conn', 'lost', 'warn', {}); return pollEvents(); }); await p.waitForTimeout(400); },
  // a notification toast on its way into the Logs tab (mid-flight frame)
  'toast-fly': async p => { await p.evaluate(async () => { const [a, b] = visibleOrder(); mockEventAdd('auto', 'switched', 'info', { from: a, to: b, reason: 'failover', fails: 3 }); await pollEvents(); await new Promise(r => setTimeout(r, 400)); document.getElementById('toast').style.transition = 'transform 2.4s ease-in, opacity 2.4s ease-in'; hideToast(); }); await p.waitForTimeout(1100); },
  'logs-search': async p => { await tab(p, 'logs'); await p.evaluate(() => setLogTab('raw')); await p.waitForTimeout(400); await p.evaluate(() => { toggleLogSearch(true); document.getElementById('logSearch').value = 'discord'; renderLogs(); }); await settle(p); },
  'logs-warn': async p => { await tab(p, 'logs'); await p.evaluate(() => setLogTab('raw')); await p.waitForTimeout(400); await logsRawUnread(p); await p.evaluate(() => setLogLevel('warn')); await settle(p); },
  'qr-node':  async p => { await tab(p, 'nodes'); await p.evaluate(() => showNodeQr('src1', sourcesData.src1.nodes[0].id)); await settle(p); },
  'speed-test': async p => { await tab(p, 'nodes'); await p.evaluate(() => { const n = sourcesData.src1.nodes.find(x => truthOf(x) >= 0); openSpeedTest('src1', n.id); }); await p.waitForTimeout(3000); },
  'speed-done': async p => { await tab(p, 'nodes'); await p.evaluate(() => { const n = sourcesData.src1.nodes.find(x => truthOf(x) >= 0); openSpeedTest('src1', n.id); }); await p.waitForFunction(() => speedRun && speedRun.p.final); await p.waitForTimeout(600); },
  'speed-fail': async p => { await tab(p, 'nodes'); await p.evaluate(() => { const n = sourcesData.src1.nodes.find(x => truthOf(x) < 0) || sourcesData.src1.nodes[0]; const m = truthOf; truthOf = x => x.id === n.id ? -1 : m(x); openSpeedTest('src1', n.id); }); await p.waitForTimeout(1900); },
  'qr-sub':   async p => { await tab(p, 'nodes'); await p.evaluate(() => showSourceQr('src1')); await settle(p); },
  'settings-data': async p => { await tab(p, 'settings'); await p.evaluate(() => openDataSettings()); await settle(p); },
  // Settings → Data → App updates (59-data.js) against the mock feed (mockUpdate, 12-backend.js)
  'update-available': async p => { await tab(p, 'settings'); await p.evaluate(() => { openDataSettings(); updCheck(); }); await p.waitForFunction(() => upd.phase === 'available'); await settle(p); },
  'update-progress': async p => { await tab(p, 'settings'); await p.evaluate(() => { mockUpdate.pauseAt = 45; openDataSettings(); updCheck(); });
    await p.waitForFunction(() => upd.phase === 'available'); await p.evaluate(() => updDownload()); await p.waitForFunction(() => upd.received >= upd.offer.size * .45 - 1); await settle(p); },
  'update-ready': async p => { await tab(p, 'settings'); await p.evaluate(() => { openDataSettings(); updCheck(); });
    await p.waitForFunction(() => upd.phase === 'available'); await p.evaluate(() => updDownload()); await p.waitForFunction(() => upd.phase === 'ready'); await settle(p); },
  'update-error': async p => { await tab(p, 'settings'); await p.evaluate(() => { mockUpdate.checkFails = 'network'; openDataSettings(); updCheck(); }); await p.waitForFunction(() => upd.phase === 'failed'); await settle(p); },
  'update-uptodate': async p => { await tab(p, 'settings'); await p.evaluate(() => { mockUpdate.find = false; openDataSettings(); updCheck(); }); await p.waitForFunction(() => upd.phase === 'upToDate'); await settle(p); },
  'restore-confirm': async p => { await tab(p, 'settings'); await p.evaluate(() => { openDataSettings(); confirmRestore(liveSnapshot(), '2026-09-20T18:30:00Z', 'jormungand-backup-2026-09-20.json'); }); await settle(p); },
  'checkers': async p => { await tab(p, 'settings'); await p.evaluate(() => { openSheet('setconn'); openCheckersPicker(); }); await settle(p); },
  'blocked-toast': async p => { await p.evaluate(() => { const id = autoOrder()[0], via = autoOrder()[1] || id;
    mockEventAdd('site', 'blocked', 'warn', { host: 'chat.example.com', dest: 'chat.example.com:443', entry: id, route: id, via }); return pollEvents(); }); await p.waitForTimeout(300); },
  'test-url': async p => { await tab(p, 'settings'); await p.evaluate(() => { openSheet('setconn'); openTestUrlPicker(); }); await settle(p); },
  'tun-stack': async p => { await tab(p, 'settings'); await p.evaluate(() => { openSheet('setconn'); openTunStackPicker(); }); await settle(p); },
  'lang-soon': async p => { await tab(p, 'settings'); await p.evaluate(() => { openSheet('setgeneral'); openLangPicker(); }); await settle(p); },
  'conn-filter': async p => { await p.evaluate(() => backend.traffic().then(t => { traffic = t; openSheet('connections'); document.getElementById('connFilter').value = 'disc'; renderTraffic(); })); await settle(p); },
  'conn-sort': async p => { await connBase(p, () => { connSort = 'down'; renderLiveConns(); openConnSort(); }); },
  'conn-menu': async p => { await connBase(p, () => { connF.app.add('chrome.exe'); openConnMore(); }); },
  'conn-filter-sheet': async p => { await connBase(p, () => { openConnFilter(); ['net:tcp', 'app:chrome.exe', 'app:Telegram.exe', 'exit:direct'].forEach(s => connFilterToggle(...s.split(':'))); document.getElementById('cf-body').scrollTop = 0; }); },
  'conn-open': async p => { await connBase(p, () => { connOpen = 'wiki.corp.local'; renderLiveConns(); document.querySelector('#liveConnList .open').scrollIntoView({ block: 'center' }); }); },
  'conn-groups': async p => { await connBase(p, () => { connFolded.add('service|s:telegram'); connFolded.add('service|s:discord'); renderLiveConns(); document.querySelector('.live-group.folded').scrollIntoView({ block: 'center' }); }); },
  'conn-paused': async p => { await connBase(p, () => { connSetPaused(true); traffic.conns.push({ ...traffic.conns[0], id: 'new1', host: 'new.example.com', start: new Date().toISOString() }); connOpen = 't.me'; renderLiveConns(); }); },
  'source-error': async p => { await tab(p, 'nodes'); await p.evaluate(() => { sourcesData.src1.lastError = { msg: 'Connection timed out (15 s)', at: Date.now() - 180e3 }; renderNodes(); }); await settle(p); },
  'dock-empty': async p => { await p.evaluate(() => { liveApply(null); connected = false; renderAll(); renderConnState(); updateMainConnectCard(); }); await settle(p); return { clip: await clipOf(p, '.dock', 60) }; },
  'nodeform-many': async p => { await tab(p, 'nodes'); await p.evaluate(links => { openNodeForm(); document.getElementById('nf-link').value = links.join('\n'); parseNodeLink(); }, SAMPLE_LINKS); await settle(p); },
  'nodeform-edit': async p => { await tab(p, 'nodes'); await p.evaluate(() => { const g = manualGroups()[0]; openNodeForm(g, sourcesData[g].nodes[0].id); }); await settle(p); },
  // Nodes → + → Import config file: a Clash file picked, its local source (no refresh / URL bits) at the end of the list
  'import-file': async p => {
    await tab(p, 'nodes');
    await p.setInputFiles('#configFile', { name: 'office-vpn.yaml', mimeType: 'text/yaml', buffer: Buffer.from(IMPORT_YAML) });
    await p.waitForTimeout(700);
    await p.evaluate(() => { document.querySelector('#view-nodes .scroll').scrollTop = 99999; });
    await settle(p);
  },
};
// ru-<preset>: the same preset with the language set to Russian (docs/i18n.md); `all` skips them.
for (const n of ['home', 'nodes', 'route', 'settings', 'rules', 'rule-form', 'logs', 'profiles', 'settings-auto', 'settings-dns', 'dock', 'connections', 'help', 'update-available', 'import-file']) if (SHOTS[n]) SHOTS['ru-' + n] = SHOTS[n];
// Links the manual server form must read without a core: vmess base64, legacy ss, IPv6, anytls.
const SAMPLE_LINKS = [
  'vmess://' + Buffer.from(JSON.stringify({ v: '2', ps: '🇳🇱 Amsterdam VM', add: 'nl1.example.net', port: '443', id: '11111111-2222-3333-4444-555555555555', aid: '0', net: 'ws', tls: 'tls' })).toString('base64'),
  'ss://' + Buffer.from('aes-256-gcm:pa55@198.51.100.7:8388').toString('base64') + '#Legacy%20SS',
  'trojan://secret@[2001:db8::1]:443?sni=v6.example#%F0%9F%87%A9%F0%9F%87%AA%20Berlin%20v6',
  'anytls://pw@any.example:8443?sni=any.example#AnyTLS%201',
];
// Config files the Import config file row must read (Nodes → + ): Clash YAML, sing-box JSON, a link list.
const IMPORT_YAML = `proxies:
  - {name: "🇩🇪 Berlin 01", type: vless, server: de1.example.net, port: 443, uuid: 11111111-2222-3333-4444-555555555555}
  - {name: "🇳🇱 Amsterdam 01", type: trojan, server: nl1.example.net, port: 443, password: pw}
  - {name: "🇫🇮 Helsinki 01", type: ss, server: fi1.example.net, port: 8388, cipher: aes-128-gcm, password: pw}
proxy-groups: []
`;
const IMPORT_JSON = JSON.stringify({ outbounds: [
  { type: 'selector', tag: 'select', outbounds: ['a'] },
  { type: 'vless', tag: '🇸🇪 Stockholm 01', server: 'se1.example.net', server_port: 443, uuid: '11111111-2222-3333-4444-555555555555' },
  { type: 'shadowsocks', tag: '🇵🇱 Warsaw 01', server: 'pl1.example.net', server_port: 8388, method: 'aes-128-gcm', password: 'pw' },
  { type: 'direct', tag: 'direct' },
] });

async function clipOf(page, sel, extraTop = 0) {
  const r = await page.locator(sel).boundingBox();
  return { x: 0, y: Math.max(0, r.y - extraTop), width: page.viewportSize().width, height: r.height + extraTop };
}

// --grid (or verify) glues the presets into one labelled .shots/grid.png, 4 per row:
// one image to look at instead of several.
async function shots(names, grid = args.includes('--grid')) {
  if (names.length === 1 && names[0] === 'all') names = Object.keys(SHOTS).filter(n => !n.startsWith('ru-'));   // every preset
  const browser = await playwright.chromium.launch();
  const dir = opt('out') ? resolve(opt('out')) : join(root, '.shots');
  const files = !grid || args.includes('--files');
  mkdirSync(dir, { recursive: true });
  const cells = [];
  for (const name of names) {
    if (!SHOTS[name]) { console.log(`unknown preset "${name}". presets: ${Object.keys(SHOTS).join(', ')}`); continue; }
    const page = await openPage(browser, {
      width: +opt('width', 400), height: +opt('height', 800), scale: +opt('scale', 1), theme: opt('theme'),
      lang: opt('lang', name.startsWith('ru-') ? 'ru' : undefined),   // ru-<preset> = the same preset in Russian
    });
    const extra = (await (SHOTS[name] || SHOTS[name.replace(/^ru-/, '')])(page)) || {};
    const file = join(dir, name + (opt('theme') ? '-' + opt('theme') : '') + '.png');
    const buf = await page.screenshot({ path: files ? file : undefined, ...extra });
    if (grid) cells.push([name, buf.toString('base64')]);
    if (!grid || page.errors.length) console.log((grid ? name : file) + (page.errors.length ? '   ERRORS: ' + page.errors.join(' | ') : ''));
    await page.close();
  }
  if (grid && cells.length) {
    // the grid keeps the shots' own resolution (--scale), not a 1x downscale
    const page = await browser.newPage({ viewport: { width: 400 * Math.min(4, cells.length) + 8, height: 100 }, deviceScaleFactor: +opt('scale', 1) });
    await page.setContent(`<body style="margin:0;background:#000;display:flex;flex-wrap:wrap;gap:4px;padding:4px;width:${400 * 4 + 12}px;font:600 13px sans-serif;color:#fff">${
      cells.map(([n, b]) => `<div style="width:400px"><div style="padding:2px 4px">${n}</div><img style="display:block;width:400px" src="data:image/png;base64,${b}"></div>`).join('')}</body>`);
    const file = join(dir, opt('grid-name', 'grid') + '.png');
    await page.screenshot({ path: file, fullPage: true });
    console.log(file);
  }
  await browser.close();
}

/* ═══════════════ CHECKS ═══════════════ */

const results = [];

async function check(name, fn) {
  try { await fn(); results.push([name, null]); }
  catch (e) { results.push([name, e.message.split('\n')[0]]); }
}
function expect(cond, msg) { if (!cond) throw new Error(msg); }

async function runChecks() {
  const browser = await playwright.chromium.launch();
  let page = await openPage(browser);

  await check('loads without errors', async () => expect(!page.errors.length, page.errors.join(' | ')));

  await check('tabs switch views', async () => {
    for (const t of ['nodes', 'settings', 'home']) {
      await tab(page, t);
      expect(await page.isVisible(`#view-${t}`), `#view-${t} not visible`);
    }
  });

  await check('home cards keep their height on a short screen', async () => {
    const vp = page.viewportSize();
    await tab(page, 'home');
    await page.setViewportSize({ width: 360, height: 480 });
    const h = await page.$eval('.segments-card', el => el.getBoundingClientRect().height);
    await page.setViewportSize(vp);
    expect(h >= 90, 'mode switch card squashed to ' + h + 'px');
  });

  await check('home header at 320px: name whole, badge one line and one width in every state', async () => {
    const vp = page.viewportSize();
    await tab(page, 'home');
    await page.setViewportSize({ width: 320, height: 640 });
    const r = await page.evaluate(() => {
      const n = document.querySelector('.app-name'), b = document.getElementById('mainToggle'), L = document.getElementById('connLabel'), was = L.textContent;
      const boxes = ['Tap to connect', 'Connecting…', 'Connected', 'VPN is down'].map(t => { L.textContent = t; const x = b.getBoundingClientRect(); return [Math.round(x.left), Math.round(x.right), Math.round(x.height)]; });
      L.textContent = was;
      const titles = [...document.querySelectorAll('#view-home .nav-title, #exitIp')].filter(e => e.scrollWidth > e.clientWidth).map(e => e.textContent);
      return { whole: n.scrollWidth <= n.clientWidth, same: boxes.every(x => x.join() === boxes[0].join()), oneLine: boxes[0][2] < 32, titles };
    });
    await page.setViewportSize(vp);
    expect(r.whole && r.same && r.oneLine && !r.titles.length, JSON.stringify(r));
  });

  await check('header and bottom nav stay fixed while content scrolls', async () => {
    await tab(page, 'nodes');
    await page.evaluate(() => { sourceOrder.forEach(id => expandState[id] = true); renderNodes(); });
    const pos = () => page.evaluate(() => ['#view-nodes .topbar', '.bottomnav'].map(s => Math.round(document.querySelector(s).getBoundingClientRect().top)).join());
    const before = await pos();
    const scrolled = await page.evaluate(() => { const el = document.querySelector('#nodes-list'); el.scrollTop = 1e5; return el.scrollTop; });
    expect(scrolled > 0, 'nodes list did not scroll');
    expect(before === await pos(), 'header/nav moved');
    expect(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight), 'page itself scrolls');
    await page.evaluate(() => { sourceOrder.forEach(id => expandState[id] = false); renderNodes(); });
  });

  await check('no horizontal overflow at 360px', async () => {
    const narrow = await openPage(browser, { width: 360 });
    for (const t of ['home', 'nodes', 'settings']) {
      await tab(narrow, t);
      const w = await narrow.evaluate(() => document.documentElement.scrollWidth);
      expect(w <= 360, `${t}: scrollWidth ${w}`);
    }
    await narrow.close();
  });

  await check('ping: a batch goes out by the cache — alive fastest first, then unmeasured, dead last', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const nodes = Object.values(sourcesData).flatMap(s => s.nodes).slice(0, 15);
      nodes.forEach((n, i) => i % 3 === 0 ? pingCache.set(pingKey(n), { ms: -1, at: Date.now() })
        : i % 3 === 1 ? pingCache.set(pingKey(n), { ms: 400 - i * 10, at: Date.now() }) : pingCache.delete(pingKey(n)));
      const before = new Map(nodes.map(n => [n, ping(n)]));
      let sent = [];
      backend.ping = list => { sent = list.slice(); return Promise.resolve(); };
      await pingNodes(nodes.slice().reverse());
      const cls = v => typeof v === 'number' ? (v >= 0 ? 0 : 2) : 1, seq = sent.map(n => before.get(n));
      const alive = seq.filter(v => cls(v) === 0);
      return { all: sent.length === nodes.length, classes: seq.every((v, i) => !i || cls(seq[i - 1]) <= cls(v)),
        fastestFirst: alive.every((v, i) => !i || alive[i - 1] <= v), mixed: new Set(seq.map(cls)).size === 3 };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('home nav cards: two per row, one line each, all four the same height', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const cards = [...document.querySelectorAll('#view-home .row-nav .nav-card')].map(c => c.getBoundingClientRect());
      return { four: cards.length === 4, pairs: cards[0].top === cards[1].top && cards[2].top === cards[3].top && cards[2].top > cards[1].bottom,
        sameH: new Set(cards.map(c => Math.round(c.height))).size === 1, low: cards[0].height <= 56,
        autoSub: /^Check every /.test(document.getElementById('autoCardSub').textContent) };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('route: unfolding a row never folds another', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      openProfiles();
      const ids = visibleOrder().filter(x => !chainsData[x]).slice(0, 2);
      ids.forEach(toggleRouteRow);
      const both = ids.every(id => document.querySelector(`#connects-list .conn-row[data-id="${id}"] .conn-body`));
      setRouteEdit(true);
      document.querySelector(`#connects-list .conn-row[data-id="${ids[1]}"] .conn-body`).dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
      setRouteRowMode('priority');
      const own = unitOwner(ids[1]).pickMode === 'priority';
      toggleRouteRow(ids[0]);
      const one = !document.querySelector(`#connects-list .conn-row[data-id="${ids[0]}"] .conn-body`) && !!document.querySelector(`#connects-list .conn-row[data-id="${ids[1]}"] .conn-body`);
      setRouteEdit(false); closeSheet('profiles');
      return { both, own, one };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('auto: an unmeasured entry on top is not passed over, nor one lost ping or an old miss; a dead one is', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      setAutoConnect(true);
      autoCfg.failAfter = 2;
      const order = visibleOrder().filter(id => connectEntry(id).inAuto && !chainsData[id]);
      const top = order[0], nodes = () => unitPickRefs(top).map(x => x.node);
      nodes().forEach(n => pingCache.delete(pingKey(n)));
      const unmeasured = effectiveConnectId() === top;
      nodes().forEach(n => setPing(n, -1));
      const oneMiss = effectiveConnectId() === top;
      nodes().forEach(n => setPing(n, -1));
      const dead = effectiveConnectId() !== top;
      pingNodes(nodes());   // re-measuring: still dead until the answer is in
      const deadWhileTesting = effectiveConnectId() !== top;
      nodes().forEach(n => pingCache.set(pingKey(n), Object.assign({}, pingEntry(n), { ms: -1, at: Date.now() - PING_FRESH_MS - 1000 })));
      const oldMiss = effectiveConnectId() === top;
      return { unmeasured, oneMiss, dead, deadWhileTesting, oldMiss };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('dock: the latency pings the first 3 servers of the first 4 Auto entries', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const refs = dockTopRefs(), ids = visibleOrder().filter(id => connectEntry(id).inAuto).slice(0, 4);
      const allowed = new Set(ids.flatMap(id => entryRefs(id).map(r => pingKey(r.node))));
      const route = document.getElementById('sh-profiles').classList.contains('open');
      [...pingCache.keys()].forEach(k => { if (pingCache.get(k).ms === 'testing') pingCache.delete(k); });
      const meta = document.querySelector('.dock .profiles-meta');
      meta.click();
      const testing = [...pingCache.entries()].filter(([, v]) => v.ms === 'testing').map(([k]) => k);
      const frame = meta.classList.contains('pinging') && getComputedStyle(meta.querySelector('.ping-frame .run')).display !== 'none';
      meta.click();
      const stopped = !meta.classList.contains('pinging') && !dockPing && getComputedStyle(meta.querySelector('.ping-frame .run')).display === 'none'
        && getComputedStyle(meta.querySelector('.ping-frame')).display !== 'none';
      return { some: refs.length > 0, inTop: refs.every(r => allowed.has(pingKey(r.node))),
        perEntry: ids.every(id => refs.filter(r => entryRefs(id).includes(r)).length <= (chainsData[id] ? 6 : 3)),
        pinged: testing.length > 0 && testing.every(k => allowed.has(k)), frame, stopped,
        noSheet: !route && !document.getElementById('sh-profiles').classList.contains('open') };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('dock: the ping goes on past the first batch and ends at 10 working servers or when all are done', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const total = dockPingBatches().flat().length, first = dockPingBatches()[0].length;
      document.querySelector('.dock .profiles-meta').click();
      const seen = new Set();
      for (let i = 0; i < 100 && dockPing; i++) {
        pingCache.forEach((v, k) => { if (v.ms === 'testing') seen.add(k); });
        await new Promise(r => setTimeout(r, 50));
      }
      const all = dockPingBatches().flat(), alive = all.filter(n => seen.has(pingKey(n)) && isAlive(n)).length;
      return { beyondFirst: seen.size > first, ended: !dockPing && !document.querySelector('.dock .profiles-meta.pinging'),
        rule: alive >= 10 || seen.size === total };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('nodes: Reality has its own protocol badge', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      switchTab('nodes'); setNodesTab('simple');
      const sid = sourceOrder[0]; expandState[sid] = true; renderNodes();
      const badges = [...document.querySelectorAll(`#view-nodes .node-proto`)].map(el => el.textContent);
      return { shown: badges.includes('reality') && badges.includes('vless'),
        core: protoLabel({ protocol: 'vless', outbound: { tls: { reality: { enabled: true } } } }) === 'reality' && protoLabel({ protocol: 'vless', outbound: { tls: {} } }) === 'vless' };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  for (const lang of ['en', 'ru']) await check('nodes: Import config file — Clash / sing-box / links become local sources (no URL, no Update), junk is refused, rename, delete, backup; 320 px / 120%' + (lang === 'ru' ? ' [ru]' : ''), async () => {
    const p = await openPage(browser, { width: 320, lang });
    await p.evaluate(() => applyScale(UI_SCALE_MAX));
    await tab(p, 'nodes');
    const said = () => p.textContent('#toast'), count = () => p.evaluate(() => sourceOrder.length);
    const n0 = await count();
    const pick = (name, text) => p.setInputFiles('#configFile', { name, mimeType: 'text/plain', buffer: Buffer.from(text) });
    const last = () => p.evaluate(() => { const s = sourcesData[sourceOrder[sourceOrder.length - 1]]; return { id: s.id, kind: s.kind, name: s.name, url: s.url, format: s.format, n: s.nodes.length, count: s.count, enabled: s.enabled }; });
    // the menu row opens the file chooser (it was a stub toast)
    await p.evaluate(() => openNodesAdd()); await settle(p);
    expect(await p.isVisible('#importFileRow'), 'no Import config file row');
    const [chooser] = await Promise.all([p.waitForEvent('filechooser'), p.click('#importFileRow')]);
    expect(!chooser.isMultiple(), 'the picker takes one file');
    await chooser.setFiles({ name: 'office-vpn.yaml', mimeType: 'text/yaml', buffer: Buffer.from(IMPORT_YAML) });
    await p.waitForTimeout(600);
    let s = await last();
    expect(await count() === n0 + 1 && s.kind === 'file' && s.name === 'office-vpn' && s.url === undefined && s.format === 'clash' && s.n === 3 && s.count === 3 && s.enabled, 'clash: ' + JSON.stringify(s));
    expect(await p.evaluate(() => sourceOrder.includes(sourcesData[sourceOrder[sourceOrder.length - 1]].id) && catalogOrder.simple.includes(sourceOrder[sourceOrder.length - 1])), 'not in the Simple tab');
    expect(/office-vpn/.test(await said()) && (lang === 'ru' ? /Импортировано 3 узла/ : /Imported 3 servers from office-vpn/).test(await said()), 'toast: ' + await said());
    // the card: marked as a local file; no Update button, no usage line, no URL anywhere
    const card = `.src-card[data-id=${s.id}]`;
    const cardHtml = await p.$eval(card, el => ({ tag: el.querySelector('.fmt-tag').textContent, update: !!el.querySelector('button[title=Update]'), usage: !!el.querySelector('.src-usage'), err: !!el.querySelector('.src-error'), meta: el.querySelector('.src-meta').textContent }));
    expect(cardHtml.tag === (lang === 'ru' ? 'локальный файл' : 'local file') && !cardHtml.update && !cardHtml.usage && !cardHtml.err, 'card: ' + JSON.stringify(cardHtml));
    expect(!await p.evaluate(sid => { const s = sourcesData[sid]; return updateSource(sid), s.updating || ('url' in s); }, s.id), 'Update touched it');
    // the meta line wraps between items on a 320 px screen at 120 %, nothing sticks out
    const sticks = await p.evaluate(() => {
      const bad = [], sc = document.querySelector('#view-nodes .scroll');
      if (sc.scrollWidth > sc.clientWidth + 1) bad.push('scroll ' + sc.scrollWidth + '>' + sc.clientWidth);
      document.querySelectorAll('.src-meta.wrap').forEach(el => { const r = el.getBoundingClientRect(); if (r.width && [...el.children].some(c => c.getBoundingClientRect().right > r.right + 1)) bad.push('meta: ' + el.textContent); });
      return bad;
    });
    expect(!sticks.length, sticks.join(' | '));

    // sing-box JSON: server outbounds only; a list of links, plain and base64 (a server twice is one)
    await pick('sb.json', IMPORT_JSON); await p.waitForTimeout(500);
    s = await last();
    expect(s.kind === 'file' && s.name === 'sb' && s.format === 'sing-box' && s.n === 2, 'sing-box: ' + JSON.stringify(s));
    await pick('links.txt', SAMPLE_LINKS.concat(SAMPLE_LINKS[0]).join('\n')); await p.waitForTimeout(500);
    s = await last();
    expect(s.format === 'links' && s.n === SAMPLE_LINKS.length, 'links: ' + JSON.stringify(s));
    await pick('links-b64', Buffer.from(SAMPLE_LINKS.join('\n')).toString('base64')); await p.waitForTimeout(500);
    s = await last();
    expect(s.format === 'base64' && s.n === SAMPLE_LINKS.length && s.name === 'links-b64', 'base64: ' + JSON.stringify(s));
    // junk: refused with the reason, nothing added
    const n1 = await count();
    await pick('junk.txt', 'this is not a config'); await p.waitForTimeout(400);
    expect(await count() === n1 && (lang === 'ru' ? /Не удалось импортировать junk\.txt: В файле не найдено узлов/ : /Could not import junk\.txt: No servers found in the file/).test(await said()), 'junk: ' + await said());

    // its menu: rename (only the name), route settings, delete; no URL / update / QR rows
    const sid = (await p.evaluate(() => sourceOrder.find(id => sourcesData[id].name === 'sb')));
    await p.evaluate(sid => openSourceActions(sid), sid); await settle(p);
    const rows = await p.$$eval('#actions-body .menu-row', r => r.map(x => x.textContent.trim()));
    expect(rows.length === 3 && /^(Rename|Переименовать)/.test(rows[0]) && !rows.some(t => /^(Copy URL|Show QR|Update with)/.test(t)), 'menu rows: ' + rows.join(' | '));
    await p.evaluate(sid => { closeSheet('actions'); openSrcForm(sid); }, sid); await settle(p);
    expect(!await p.isVisible('#sf-url') && await p.inputValue('#sf-name') === 'sb', 'rename form shows the URL / the name is wrong');
    await p.fill('#sf-name', 'Stockholm file');
    await p.click('#sfSaveBtn'); await settle(p);
    s = await p.evaluate(sid => ({ name: sourcesData[sid].name, n: sourcesData[sid].nodes.length, kind: sourcesData[sid].kind, url: sourcesData[sid].url }), sid);
    expect(s.name === 'Stockholm file' && s.n === 2 && s.kind === 'file' && s.url === undefined, 'rename: ' + JSON.stringify(s));

    // backup: the snapshot carries it, restore brings it back
    const back = await p.evaluate(async sid => {
      const snap = JSON.parse(JSON.stringify(await backend.exportState()));
      const got = snap.sourcesData[sid];
      await backend.importState(snap);
      return [got && got.kind, got && got.nodes.length, sourcesData[sid] && sourcesData[sid].kind, sourcesData[sid] && sourcesData[sid].name, sourceOrder.includes(sid)];
    }, sid);
    expect(back.join() === 'file,2,file,Stockholm file,true', 'backup: ' + back.join());

    // delete impact as for any source: the confirmation says what goes
    await p.evaluate(sid => confirmDeleteSource(sid), sid); await settle(p);
    const del = await p.textContent('#actions-body');
    expect((lang === 'ru' ? /Импортированный файл и его 2 узла удаляются/ : /The imported file and its 2 servers are removed/).test(del), 'delete text: ' + del.slice(0, 120));
    await p.evaluate(sid => { closeSheet('actions'); deleteSource(sid); }, sid); await settle(p);
    expect(await p.evaluate(sid => !sourcesData[sid] && !sourceOrder.includes(sid) && !catalogOrder.simple.includes(sid), sid), 'not deleted');
    expect(!p.errors.length, p.errors.join(' | '));
    await p.close();
  });

  await check('ping sort: answers go up by ms, timeouts go to the bottom at once, waiting rows stay between', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const nodes = sourcesData[sourceOrder[0]].nodes.slice(0, 5);
      nodes.forEach(n => pingCache.set(pingKey(n), { ms: 'testing', at: Date.now() }));
      setPing(nodes[3], 40); setPing(nodes[1], -1);
      const fast = byPing(nodes).map(n => nodes.indexOf(n));
      nodeSort = 'latency'; const sorted = sortedNodes(nodes).map(n => nodes.indexOf(n)); nodeSort = 'order';
      return { fast: fast.join() === '3,0,2,4,1', sorted: sorted.join() === '3,0,2,4,1' };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('node rows: a timeout is a red warning sign, long names wrap instead of being cut', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      switchTab('nodes'); setNodesTab('simple');
      const sid = sourceOrder[0], n = sourcesData[sid].nodes[0], was = n.name;
      n.name = 'A very long server name from a provider that never fits on one line at all';
      setPing(n, -1); expandState[sid] = true; renderNodes();
      const row = document.querySelector(`#view-nodes .node-row[data-id="${n.id}"]`) || [...document.querySelectorAll('#view-nodes .node-row')].find(el => el.textContent.includes('A very long'));
      const name = row.querySelector('.node-name'), lat = row.querySelector('.lat');
      const out = { sign: !!lat.querySelector('svg') && !/timeout/.test(lat.textContent) && lat.classList.contains('bad'),
        wraps: name.getClientRects().length && name.offsetHeight > parseFloat(getComputedStyle(name).lineHeight) * 1.5 && name.scrollWidth <= name.clientWidth,
        fits: row.scrollWidth <= row.clientWidth,
        flagInName: !!name.querySelector('.node-flag') && name.firstElementChild.classList.contains('node-flag') };
      n.name = was; renderNodes();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('route: a long node name wraps under its flag, the header ms stays on its first line', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      openProfiles(); setRouteEdit(false);
      const id = visibleOrder().find(x => sourcesData[x] && unitNode(x));
      // the row shows the best-by-ping server, which random pings can swap mid-check: rename them all
      const all = unitPickRefs(id).map(r => r.node), was = all.map(x => x.name);
      all.forEach(x => { x.name = 'RU-SPB ➡️ Нидерланды ➡️ WARP and a long tail that wraps twice'; });
      renderConnects(); toggleRouteRow(id);
      await new Promise(r => setTimeout(r, 600));
      const row = document.querySelector(`#connects-list .conn-row[data-id="${id}"]`);
      const node = row.querySelector('.conn-sub .conn-node'), lat = row.querySelector('.conn-sub .lat').getBoundingClientRect();
      const lines = node.getClientRects(), first = lines[0];
      const nr = [...row.querySelectorAll('.conn-body .node-name')].find(el => el.textContent.includes('long tail'));
      const out = { wraps: node.offsetHeight > 30, flagInName: !!node.querySelector('.conn-flag') && !!nr && nr.firstElementChild.classList.contains('node-flag'),
        msFirstLine: lat.top >= first.top - 3 && lat.bottom <= first.bottom + 3 };
      all.forEach((x, i) => { x.name = was[i]; }); toggleRouteRow(id);
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('route: title and ⚡ sit at the same inset; a tap just above the ms pings, never pins', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      openProfiles(); setRouteEdit(false);
      const id = visibleOrder().find(x => sourcesData[x] && unitRefs(x).length > 1);
      await new Promise(r => setTimeout(r, 600));   // the sheet slides in
      const row = document.querySelector(`#connects-list .conn-row[data-id="${id}"]`), box = row.getBoundingClientRect();
      const title = row.querySelector('.conn-state').getBoundingClientRect(), bolt = row.querySelector('.route-ping svg').getBoundingClientRect();
      const inset = Math.abs((title.left - box.left) - (box.right - bolt.right)) <= 3;
      toggleRouteRow(id);
      const nr0 = document.querySelector(`#connects-list .conn-row[data-id="${id}"] .conn-body .node-row`); nr0.scrollIntoView({ block: 'center' });
      const nr = document.querySelector(`#connects-list .conn-row[data-id="${id}"] .conn-body .node-row`), nb = nr.getBoundingClientRect();
      const lat = nr.querySelector('.lat').getBoundingClientRect();
      const hit = document.elementFromPoint(lat.left + lat.width / 2, nb.top + 2);
      const pinnedBefore = pinnedNode;
      hit.click();
      const out = { inset, hit: !!hit.closest('.lat-hit'), noPin: pinnedNode === pinnedBefore };
      toggleRouteRow(id); closeSheet('profiles');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('every entry off Auto: Auto picks nothing, the dock says so, power alerts instead of connecting', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const ids = visibleOrder(), was = ids.map(id => connectEntry(id).inAuto);
      ids.forEach(id => { connectEntry(id).inAuto = false; }); updateMainConnectCard();
      const out = { none: effectiveConnectId() === null, dock: /Nothing in Auto/.test(document.getElementById('profCardName').textContent) };
      connected = false; renderConnState(); toggleMain();   // the mockup starts connected
      out.notConnecting = !connecting && !connected;
      out.alert = document.getElementById('sh-actions').classList.contains('open') && /Nothing in Auto/.test(document.getElementById('actionsTitle').textContent);
      [...document.querySelectorAll('#actions-body .menu-row')].find(el => /Open Route/.test(el.textContent)).click();
      await new Promise(r => setTimeout(r, 400));
      out.route = document.getElementById('sh-profiles').classList.contains('open') && routeEdit;
      toggleEntryAuto(ids[1]);
      out.back = effectiveConnectId() === ids[1] && !nothingInAuto();
      out.manual = (() => { selectConnect(ids[2]); const ok = effectiveConnectId() === ids[2] && !nothingInAuto(); autoConnect = true; return ok; })();
      ids.forEach((id, i) => { connectEntry(id).inAuto = was[i]; }); setRouteEdit(false); closeSheet('profiles'); connected = true; renderConnState(); updateMainConnectCard();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('bottom nav: visible over every sheet; a tab tap closes the sheets', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      openSheet('connections'); openAutoMode();
      await new Promise(r => setTimeout(r, 500));
      const nav = document.querySelector('.bottomnav').getBoundingClientRect();
      const top = document.elementFromPoint(nav.left + nav.width / 2, nav.top + nav.height / 2);
      const sheetsEnd = [...document.querySelectorAll('.sheet.open')].every(el => el.getBoundingClientRect().bottom <= nav.top + 1);
      document.querySelector('.nav-btn[data-tab=nodes]').click();
      return { onTop: !!top.closest('.bottomnav'), sheetsEnd, closed: !document.querySelector('.sheet.open'),
        tab: document.getElementById('view-nodes').classList.contains('active') };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('live traffic: cards and Live connections follow backend.traffic, zero when off', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      // the launch ping may still be measuring: wait until Auto has a server to go through
      for (let i = 0; i < 50 && !unitNode(effectiveConnectId()); i++) await new Promise(r => setTimeout(r, 100));
      connGroup = 'none'; traffic = await backend.traffic(); renderTraffic(); openSheet('connections');
      const rows = [...document.querySelectorAll('#liveConnList .live-conn-row')];
      const node = unitNode(effectiveConnectId());
      const n0 = sourcesData[sourceOrder[0]].nodes[0];
      const on = { speed: document.getElementById('speedDown').textContent === '48.3' && document.getElementById('speedDownUnit').textContent === 'MB/s',
        total: document.getElementById('trafficDown').textContent === '1.84 GB', conns: document.getElementById('connTotal').textContent === '51',
        rows: rows.length === 17, newest: rows[0].textContent.includes('192.168.0.1:53'),
        via: !!node && rows[1].textContent.includes(node.name), app: rows[1].textContent.includes('Code.exe'),
        tag: trafficVia(['route0/' + sourceOrder[0] + '::' + n0.id]).includes(n0.name) };
      connected = false; renderConnState();
      const off = { speed: document.getElementById('speedDown').textContent === '0', conns: document.getElementById('connTotal').textContent === '0',
        kept: document.getElementById('trafficDown').textContent === '1.84 GB', empty: document.getElementById('liveConnList').textContent.includes('Not connected') };
      return { ...on, ...off };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('settings: the proxy port is editable, bad or taken ports are refused', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const set = v => { const i = document.getElementById('conn-port'); i.value = v; i.dispatchEvent(new Event('change')); return connCfg.port; };
      return { ok: set('10808') === 10808, low: set('80') === 10808, taken: set('9090') === 10808, junk: set('12a') === 10808,
        shown: document.getElementById('conn-port').value === '10808' };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('settings: password on the proxy port — off by default, generated when on, own login / password into the plan, copy strings, New password, validation', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      window.__copied = null;
      Object.defineProperty(navigator, 'clipboard', { configurable: true,
        value: { writeText: t => { window.__copied = t; return Promise.resolve(); }, readText: () => Promise.resolve('') } });
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { n.outbound = { type: 'socks', server: '127.0.0.1', server_port: 1 }; n.unsupported = false; }));
      switchTab('settings'); openSheet('setconn');
      const $ = id => document.getElementById(id), text = () => $('conn-settings').textContent, toast = () => $('toast').textContent;
      const set = (id, v) => { $(id).value = v; $(id).dispatchEvent(new Event('change')); };
      const out = {};
      const sigOff = planSig();
      out.off = connCfg.proxyAuth === false && !$('conn-user') && livePlan().mixedAuth === undefined && !!document.querySelector('[data-key=proxyAuth] .help-btn');
      document.querySelector('[data-key=proxyAuth] .mini-toggle').click();
      out.generated = connCfg.proxyAuth && /^[a-z0-9]{8}$/.test(connCfg.proxyUser) && connCfg.proxyPass.length === 20
        && $('conn-user').value === connCfg.proxyUser && $('conn-pass').value === connCfg.proxyPass;
      out.planOn = JSON.stringify(livePlan().mixedAuth) === JSON.stringify({ user: connCfg.proxyUser, pass: connCfg.proxyPass }) && planSig() !== sigOff;
      // the user's own
      set('conn-user', 'alice'); set('conn-pass', 'S3cret&pass');
      out.own = JSON.stringify(livePlan().mixedAuth) === JSON.stringify({ user: 'alice', pass: 'S3cret&pass' }) && $('conn-user').value === 'alice' && $('conn-pass').value === 'S3cret&pass';
      $('conn-copy-socks').click();
      out.socks = window.__copied === 'socks5://alice:S3cret%26pass@127.0.0.1:' + connCfg.port;
      $('conn-copy-http').click();
      out.http = window.__copied === 'http://alice:S3cret%26pass@127.0.0.1:' + connCfg.port;
      // the fields start at one x, the regenerate button sits inside the Password field
      const ru = $('conn-user').getBoundingClientRect(), rp = $('conn-pass').getBoundingClientRect(), rb = $('conn-newpass').getBoundingClientRect();
      out.aligned = Math.abs(ru.left - rp.left) < 1 && Math.abs(ru.right - rp.right) < 1 && rb.left >= rp.left && rb.right <= rp.right + 1 && !!$('conn-newpass').querySelector('svg');
      // New password: another one, the login stays
      const old = connCfg.proxyPass;
      $('conn-newpass').click();
      out.fresh = connCfg.proxyPass !== old && connCfg.proxyPass.length === 20 && connCfg.proxyUser === 'alice' && $('conn-pass').value === connCfg.proxyPass;
      // validation: the old values stay, a toast says why
      const keep = { u: connCfg.proxyUser, p: connCfg.proxyPass }, bad = [];
      [['conn-user', '', /empty/], ['conn-user', 'a:b', /:/], ['conn-user', 'a b', /spaces/], ['conn-user', 'x'.repeat(65), /too long/],
        ['conn-pass', '', /empty/], ['conn-pass', 'abc', /too short/], ['conn-pass', 'has space', /spaces/], ['conn-pass', 'x'.repeat(129), /too long/]]
        .forEach(([id, v, why]) => {
          $('toast').textContent = '';
          set(id, v);
          if (connCfg.proxyUser !== keep.u || connCfg.proxyPass !== keep.p || !why.test(toast()) || $(id).value !== (id === 'conn-user' ? keep.u : keep.p)) bad.push(id + '=' + v.slice(0, 6));
        });
      out.validation = !bad.length;
      out.validationWhy = bad.join(',');
      // off: the credentials are kept, the plan does not send them, the copy strings have none
      const kept = { u: connCfg.proxyUser, p: connCfg.proxyPass };
      document.querySelector('[data-key=proxyAuth] .mini-toggle').click();
      out.kept = !connCfg.proxyAuth && connCfg.proxyUser === kept.u && connCfg.proxyPass === kept.p && !$('conn-user') && livePlan().mixedAuth === undefined && planSig() === sigOff;
      $('conn-copy-socks').click();
      out.plainSocks = window.__copied === 'socks5://127.0.0.1:' + connCfg.port;
      $('conn-copy-http').click();
      out.plainHttp = window.__copied === 'http://127.0.0.1:' + connCfg.port;
      // on again: the same ones come back
      document.querySelector('[data-key=proxyAuth] .mini-toggle').click();
      out.reused = connCfg.proxyUser === kept.u && connCfg.proxyPass === kept.p && $('conn-user').value === kept.u
        && JSON.stringify(livePlan().mixedAuth) === JSON.stringify({ user: kept.u, pass: kept.p });
      // empty ones are generated on
      document.querySelector('[data-key=proxyAuth] .mini-toggle').click();
      connCfg.proxyUser = connCfg.proxyPass = '';
      document.querySelector('[data-key=proxyAuth] .mini-toggle').click();
      out.generatedEmpty = /^[a-z0-9]{8}$/.test(connCfg.proxyUser) && connCfg.proxyPass.length === 20;
      // no row changes its height on the toggles (both hint texts are reserved)
      const hs = () => ['proxyPort', 'proxyAuth', 'killSwitch', 'downProxy'].map(k => { const e = document.querySelector(`#conn-settings [data-key="${k}"]`); return e ? Math.round(e.getBoundingClientRect().height) : -1; }).join();
      connCfg.killSwitch = false; document.querySelector('[data-key=proxyAuth] .mini-toggle').click(); renderConnSettings();
      const h0 = hs();
      document.querySelector('[data-key=proxyAuth] .mini-toggle').click(); const h1 = hs();
      setSysProxy(!connCfg.sysProxy); renderConnSettings(); const h2 = hs();
      document.querySelector('[data-key=downProxy] .mini-toggle').click(); const h3 = hs();
      out.heights = h0 === h1 && h1 === h2 && h2 === h3 && !h0.includes('-1');
      out.heightsWhy = [h0, h1, h2, h3].join(' | ');
      return out;
    });
    expect(Object.entries(r).every(([k, v]) => k === 'validationWhy' || k === 'heightsWhy' || v) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('per-app dialog: vertically centred, Split tabs only while Split is on, swipe TCP → UDP, Via inert unless Proxy, fits 320 wide at 120%', async () => {
    const p = await openPage(browser, { width: 320 });
    await p.evaluate(() => { applyScale(UI_SCALE_MAX); openRules(); openApps(); openAppAct('com.whatsapp'); });
    await p.waitForTimeout(400);
    const box = () => p.evaluate(() => { const r = document.getElementById('sh-appact').getBoundingClientRect(); return { t: Math.round(r.top), b: Math.round(r.bottom), h: innerHeight }; });
    const a = await box();
    const out = { centred: Math.abs((a.t + a.b) / 2 - a.h / 2) <= 2 };
    out.noTabs = await p.evaluate(() => !document.getElementById('aa-tabs') && document.querySelectorAll('#aa-body .aa-route .seg3 button').length === 8);
    out.inertDefault = await p.evaluate(() => document.querySelectorAll('#aa-body .aa-inert').length === 1 && !!document.querySelector('#aa-body .aa-fb-via.aa-inert')   // Default: only the Fallback Via is dimmed
      && !!document.querySelector('#aa-body .aa-fixed svg') && /Main flow/.test(document.querySelector('#aa-body .aa-fixed').textContent) && !document.querySelector('#aa-body .aa-fb.aa-inert'));
    await p.evaluate(() => { appDraft.act = 'direct'; renderAppAct(); });
    out.inertDirect = await p.evaluate(() => { document.querySelector('#aa-body .aa-inert').click(); return document.querySelectorAll('#aa-body .aa-inert').length === 3 && !!document.querySelector('#aa-body .aa-fb.aa-inert') && !document.getElementById('sh-target').classList.contains('open'); });
    await p.evaluate(() => { appDraft.act = 'proxy'; appDraft.target = 'src:src1'; renderAppAct(); });
    out.proxyLive = await p.evaluate(() => document.querySelectorAll('#aa-body .aa-inert').length === 1 && !!document.querySelector('#aa-body .aa-fb-via.aa-inert') && document.querySelectorAll('#aa-body .tgt-row').length === 2);
    await p.evaluate(() => document.getElementById('aa-split').click());
    out.tabs = await p.evaluate(() => !!document.getElementById('aa-tabs') && document.querySelector('#aa-tabs .nodes-tab.active').dataset.tab === 'tcp');
    const bb = await p.evaluate(() => document.getElementById('aa-body').getBoundingClientRect());
    const y = bb.top + 120, x0 = bb.left + bb.width * 0.7;
    await p.mouse.move(x0, y); await p.mouse.down(); await p.mouse.move(x0 - 80, y, { steps: 5 }); await p.mouse.up();
    await p.waitForTimeout(200);
    out.swipe = await p.evaluate(() => appTab === 'udp' && document.querySelector('#aa-tabs .nodes-tab.active').dataset.tab === 'udp' && document.getElementById('aa-card').dataset.half === undefined && document.querySelector('#aa-card .aa-half').dataset.half === 'udp');
    await p.mouse.move(bb.left + bb.width * 0.3, y); await p.mouse.down(); await p.mouse.move(bb.left + bb.width * 0.3 + 80, y, { steps: 5 }); await p.mouse.up();
    await p.waitForTimeout(200);
    out.swipeBack = await p.evaluate(() => appTab === 'tcp');
    await p.evaluate(() => document.getElementById('aa-split').click());
    out.tabsGone = await p.evaluate(() => !document.getElementById('aa-tabs'));
    out.fits = await p.evaluate(() => { const d = document.getElementById('sh-appact'); return d.scrollWidth <= d.clientWidth + 1 && [...d.querySelectorAll('.set-row')].every(r => r.scrollWidth <= r.clientWidth + 1); });
    expect(Object.values(out).every(Boolean) && !p.errors.length, JSON.stringify(out) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('selected rows: pinned (Route) and picked (target picker) rows show the left stripe unclipped, no ✓ in the picker; kill switch text; password hint behind (?)', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const out = {};
      // the stripe is an inset box-shadow: the row must start at or right of every clipping ancestor's left edge
      const stripe = el => {
        if (!el || !/inset/.test(getComputedStyle(el).boxShadow)) return false;
        const l = el.getBoundingClientRect().left;
        for (let a = el.parentElement; a && a !== document.body; a = a.parentElement)
          { const cs = getComputedStyle(a); if (cs.overflowX !== 'visible' && a.getBoundingClientRect().left - (cs.overflowX === 'clip' ? parseFloat(cs.overflowClipMargin) || 0 : 0) > l + 0.5) return false; }
        return el.getBoundingClientRect().width > 0;
      };
      openProfiles();
      const id = visibleOrder().find(x => sourcesData[x] && unitRefs(x).length > 1);
      toggleRouteRow(id); pinRouteNode(id, refKey(unitRefs(id)[1]));
      const pin = document.querySelector('#connects-list .conn-body .node-row.pinned');
      out.pinStripe = stripe(pin) && /3px/.test(getComputedStyle(pin).boxShadow);
      const hint = document.querySelector('#connects-list .conn-body .conn-hint, #connects-list .conn-body .set-hint');
      out.pinAligned = !hint || Math.abs(pin.querySelector('.node-name').getBoundingClientRect().left - hint.getBoundingClientRect().left) <= 8;
      pinRouteNode(id, refKey(unitRefs(id)[1])); toggleRouteRow(id);
      // the picker
      openRules(); openRuleForm('r1'); ruleDraft.action = 'proxy'; renderRuleForm();
      document.querySelector('#rf-body .tgt-row').click();
      const sid = sourceOrder[0], card = () => document.querySelector(`#tp-body .tp-card[data-t="src:${sid}"]`);
      card().querySelector('.src-head .conn-state').click();
      out.cardStripe = stripe(card());
      out.noCheck = !document.querySelector('#tp-body .tp-check');
      card().querySelector('.src-head .conn-state').click();
      card().querySelector('.src-head').click();
      const row = card().querySelector('.conn-body .node-row'); row.click();
      const pr = card().querySelector('.node-row.picked');
      out.rowStripe = stripe(pr);
      out.noCheck2 = !document.querySelector('#tp-body .tp-check, #tp-body .node-row.picked svg.tp-check');
      out.flagInset = pr.querySelector('.node-flag').getBoundingClientRect().left - pr.getBoundingClientRect().left >= 10;
      closeSheet('target'); closeSheet('ruleform'); closeSheet('rules');
      // kill switch confirm
      connCfg.killSwitch = true; connected = true; connCfg.downProxy = 'remove'; toggleKillSwitch();
      const t = document.getElementById('actions-body').textContent;
      out.killText = !/cannot recover/i.test(t) && /system proxy is removed and your traffic goes direct/.test(t);
      closeSheet('actions'); connected = false;
      // password row: hint behind (?)
      openSheet('setconn'); renderConnSettings();
      const row2 = document.querySelector('#conn-settings [data-key="proxyAuth"]');
      out.pwHelp = !!row2.querySelector('.help-btn') && !row2.querySelector('.set-hint, .hint-stack');
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('home stat cards: labels at one offset, live values never move or resize anything', async () => {
    const bad = [];
    for (const [width, big] of [[400, false], [320, true]]) {
      const p = await openPage(browser, { width });
      if (big) await p.evaluate(() => applyScale(UI_SCALE_MAX));
      const geo = () => p.evaluate(() => [...document.querySelectorAll('#view-home .row1 .card')].map(c => {
        const b = c.getBoundingClientRect(), l = c.querySelector('.card-label').getBoundingClientRect();
        return { w: Math.round(b.width), h: Math.round(b.height), lx: Math.round(l.left - b.left), ly: Math.round(l.top - b.top) };
      }));
      const g0 = await geo();
      if (new Set(g0.map(g => g.lx + ',' + g.ly)).size !== 1) bad.push(`${width}: label offsets ${JSON.stringify(g0.map(g => [g.lx, g.ly]))}`);
      // widest realistic values: 5-char speed, traffic, 3-digit counts, the globe instead of a flag
      await p.evaluate(() => {
        const set = (id, v) => { document.getElementById(id).textContent = v; };
        set('speedDown', '999.9'); set('speedDownUnit', 'KB/s'); set('speedUp', '0'); set('speedUpUnit', 'B/s');
        set('trafficDown', '999.9 GB'); set('trafficUp', '999.9 MB');
        set('connTotal', '999'); set('connTcp', '999'); set('connUdp', '999');
        set('exitFlag', '🌐'); set('exitLoc', 'Tap to retry');
      });
      const g1 = await geo();
      if (JSON.stringify(g0) !== JSON.stringify(g1)) bad.push(`${width}: ${JSON.stringify(g0)} -> ${JSON.stringify(g1)}`);
      // the Speed divider is level with the gap between Exit IP and Connections, and the
      // session label with the Connections label
      const lvl = await p.evaluate(() => {
        const r = s => document.querySelector('#view-home .row1 ' + s).getBoundingClientRect();
        const halves = [...document.querySelectorAll('#view-home .row1-right .card')].map(c => c.getBoundingClientRect());
        const d = r('.stat-divider');
        return { div: (d.top + d.bottom) / 2, gap: (halves[0].bottom + halves[1].top) / 2,
          session: r('.stat-part.session .card-label').top, conn: halves[1].top + (r('.row1-right .card:last-child .card-label').top - halves[1].top) };
      });
      if (Math.abs(lvl.div - lvl.gap) > 1 || Math.abs(lvl.session - lvl.conn) > 1) bad.push(`${width}: levels ${JSON.stringify(lvl)}`);
      const clipped = await p.evaluate(() => [...document.querySelectorAll('#view-home .row1 :is(.stat-row, .stat-total-row, .conn-stats, .card-label, .ip-addr, .ip-loc)')]
        .filter(el => el.scrollWidth > el.clientWidth + 1).map(el => el.className + ' ' + el.textContent.trim()));
      if (clipped.length) bad.push(`${width}: clipped ${clipped.join(', ')}`);
      await p.close();
    }
    expect(!bad.length, bad.join(' | '));
  });

  for (const lang of ['en', 'ru']) await check('text size: 120% on a 320px phone — nothing sticks out, titles keep their size' + (lang === 'ru' ? ' [ru]' : ''), async () => {
    const narrow = await openPage(browser, { width: 320, lang });
    const title0 = await narrow.evaluate(() => getComputedStyle(document.querySelector('.app-name')).fontSize);
    await narrow.evaluate(() => applyScale(UI_SCALE_MAX));
    const over = () => narrow.evaluate(() => {
      const bad = [];
      document.querySelectorAll('.view.active .scroll, .view.active .nodes-page, .sheet.open .sheet-body').forEach(el => {
        if (el.closest('.nodes-pager') && !el.getBoundingClientRect().width) return;
        if (el.scrollWidth > el.clientWidth + 1) {
          const r = el.getBoundingClientRect(), w = [...el.querySelectorAll('*')].find(c => c.getBoundingClientRect().right > r.right + 1);
          bad.push((el.id || el.className) + ' ' + el.scrollWidth + '>' + el.clientWidth + (w ? ' <' + (w.className || w.tagName) + ': ' + w.textContent.trim().slice(0, 40) + '>' : ''));
        }
      });
      // the source meta line wraps between items instead of being clipped
      document.querySelectorAll('.view.active .src-meta.wrap').forEach(el => {
        const r = el.getBoundingClientRect();
        if (r.width && [...el.children].some(c => c.getBoundingClientRect().right > r.right + 1)) bad.push('src-meta clipped: ' + el.textContent);
      });
      return bad;
    });
    const bad = [];
    await seedServices(narrow);
    await narrow.evaluate(() => { sourcesData.src1.lastError = { msg: 'Connection timed out (15 s) while fetching the subscription', at: Date.now() }; renderNodes(); connected = true; vpn.down = { since: Date.now() - 65e3, attempt: 4, proxy: 'kept' }; renderConnState(); });
    for (const t of ['home', 'nodes', 'settings', 'logs']) { await tab(narrow, t); await narrow.waitForTimeout(t === 'logs' ? 300 : 0); if (t === 'logs') await narrow.evaluate(() => document.querySelectorAll('#evList .ev-row').forEach(r => r.classList.add('open'))); bad.push(...await over()); }
    const sheets = [
      () => { switchTab('logs'); openEvFilter(); evFilterFold('auto'); evFilterFold('sub'); setShowOwn(true); },
      () => { switchTab('nodes'); setNodesTab('profiles'); },
      () => { setNodesTab('simple'); openProfiles(); const id = visibleOrder().find(x => sourcesData[x]); sourcesData[id].pickMode = 'priority'; toggleRouteRow(id); },
      () => { closeSheet('profiles'); openRules(); svcOpen = true; renderRules(); },
      () => openRuleForm('r2'),
      () => openTargetPicker('chain:sc1', () => {}),
      () => { closeSheet('target'); closeSheet('ruleform'); openApps(); },
      () => { closeSheet('apps'); closeSheet('rules'); openEditChain('sc1'); },
      () => { closeSheet('createchain'); openSheet('setlook'); },
      () => { closeSheet('setlook'); openSheet('setauto'); },
      () => { closeSheet('setauto'); openSheet('setnotif'); },
      () => { closeSheet('setnotif'); openDataSettings(); },
      () => { upd.phase = 'downloading'; upd.offer = mockRelease('beta'); upd.received = upd.offer.size * .45; renderUpdates(); },   // App updates: the tallest state
      () => { upd.phase = 'failed'; upd.stage = 'download'; upd.error = updErrorText({ code: 'network' }); renderUpdates(); },
      () => { upd.phase = 'idle'; upd.offer = null; upd.error = null; renderUpdates(); },
      () => { closeSheet('setdata'); showSourceQr('src1'); },
      () => { closeSheet('actions'); connCfg.killSwitch = true; openSheet('setconn'); renderConnSettings(); },
      () => { connCfg.killSwitch = false; renderConnSettings(); },
      () => { openTestUrlPicker(); },
      () => { closeSheet('actions'); closeSheet('setconn'); openNodeForm(); document.getElementById('nf-link').value = 'vless://a@b.example:443#x\nvless://a@c.example:443#y'; parseNodeLink(); },
      () => { closeSheet('nodeform'); connected = true; return backend.traffic().then(t => { traffic = t; openSheet('connections'); renderTraffic(); }); },
    ];
    // Live connections: an unfolded row, a long sort label and the filter badge — the tools row keeps its size and stays inside
    sheets.push(() => { connOpen = 'rr3.googlevideo.com'; connSort = 'downed'; connF.app.add('chrome.exe'); connF.rule.add('YouTube'); connF.exit.add('direct'); renderLiveConns(); });
    sheets.push(() => { openConnFilter(); connFExp.add('host'); renderConnFilter(); });
    for (const f of sheets) { await narrow.evaluate(f); await settle(narrow); bad.push(...await over()); }
    // Auto mode: every row's controls stay inside the row
    await narrow.evaluate(() => { closeSheet('connfilter'); connOpen = null; renderLiveConns(); });
    bad.push(...await narrow.evaluate(() => {   // the tools row: every control inside it, the search keeps room, sizes fixed
      const row = document.querySelector('#sh-connections .conn-tools'), r = row.getBoundingClientRect();
      const kids = [...row.querySelectorAll('.search, .icon-btn, .conn-sort')].map(e => e.getBoundingClientRect());
      return kids.some(k => k.right > r.right + 1 || k.left < r.left - 1) || kids[0].width < 60 || document.getElementById('connSortBtn').getBoundingClientRect().width !== 88 ? ['conn-tools: ' + JSON.stringify(kids.map(k => [k.left | 0, k.right | 0]))] : [];
    }));
    await narrow.evaluate(() => { closeSheet('connections'); openSheet('setauto'); }); await settle(narrow);
    bad.push(...await narrow.evaluate(() => [...document.querySelectorAll('#auto-settings .set-row')].filter(row => {
      const r = row.getBoundingClientRect();
      return row.scrollWidth > row.clientWidth + 1 || [...row.children].some(c => c.getBoundingClientRect().right > r.right + 1);
    }).map(row => 'auto row: ' + row.textContent.trim().slice(0, 30))));
    const title1 = await narrow.evaluate(() => getComputedStyle(document.querySelector('.app-name')).fontSize);
    expect(!bad.length, bad.join(' | '));
    expect(title0 === title1, `title ${title0} -> ${title1}`);
    await narrow.close();
  });

  await check('settings sections close by swiping the header down', async () => {
    await tab(page, 'settings');
    await page.evaluate(() => openSheet('setlook')); await settle(page);
    const h = await page.locator('#sh-setlook .sheet-head').boundingBox();
    await page.mouse.move(h.x + 60, h.y + h.height / 2); await page.mouse.down();
    await page.mouse.move(h.x + 60, h.y + 260, { steps: 8 }); await page.mouse.up(); await settle(page);
    expect(await page.evaluate(() => !document.getElementById('sh-setlook').classList.contains('open')), 'still open');
  });

  await check('nodes: search opens, filters, closes', async () => {
    await tab(page, 'nodes');
    expect(!(await page.isVisible('#nodeSearchBar')), 'search bar visible before opening');
    await page.click('#nodeSearchBtn');
    await page.keyboard.type('tokyo');
    const rows = await page.$$eval('.node-row .node-name', els => els.map(e => e.lastChild.textContent));
    expect(rows.length && rows.every(r => /tokyo/i.test(r)), 'filter: ' + rows.join(','));
    await page.click('#nodeSearchBar button');
    expect(!(await page.isVisible('#nodeSearchBar')) && (await page.inputValue('#nodeSearch')) === '', 'not cleared/closed');
  });

  await check('nodes: tap latency pings that node only', async () => {
    await page.evaluate(() => { expandState[sourceOrder[0]] = true; renderNodes(); });
    await page.click('.node-row >> nth=0 >> .lat');
    const [testing, sheetOpen] = await page.evaluate(() => [
      sourcesData[sourceOrder[0]].nodes.filter(n => ping(n) === 'testing').length,
      document.getElementById('sh-actions').classList.contains('open')]);
    expect(testing === 1, `${testing} nodes testing`);
    expect(!sheetOpen, 'actions sheet opened');
  });

  await check('nodes: update button on subscription', async () => {
    const id = await page.evaluate(() => sourceOrder.find(id => sourcesData[id].kind === 'sub'));
    await page.click(`.src-card[data-id=${id}] button[title=Update]`);
    expect(await page.evaluate(id => sourcesData[id].updating, id), 'not updating');
  });

  await check('nodes: menus hold no ping/update duplicates', async () => {
    await page.click('.src-card >> nth=0 >> button[title=More]');
    const src = await page.$$eval('#actions-body .menu-label', els => els.map(e => e.textContent).join('|'));
    await page.evaluate(() => { closeSheet('actions'); openNodesMore(); });
    const more = await page.$$eval('#nodesmore-body .menu-label', els => els.map(e => e.textContent).join('|'));
    await page.evaluate(() => closeSheet('nodesmore'));
    expect(!/latency|update now/i.test(src), 'source menu: ' + src);
    expect(!/latency/i.test(more), 'more menu: ' + more);
  });

  await check('nodes: drag reorders sources', async () => {
    await page.evaluate(() => { sourceOrder.forEach(id => expandState[id] = false); setNodesEdit(true); });
    const last = await page.evaluate(() => sourceOrder[sourceOrder.length - 1]);
    const g = await page.locator(`#nodes-list .src-card[data-id=${last}]`).locator('.drag-handle').boundingBox();
    const first = await page.locator('.src-card').first().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2);
    await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, first.y - 20, { steps: 8 });
    await page.mouse.up(); await settle(page);
    expect(await page.evaluate(() => sourceOrder[0]) === last, 'order: ' + await page.evaluate(() => sourceOrder.join()));
  });

  await check('nodes: drag first source to the last place', async () => {
    await page.evaluate(() => { sourceOrder.forEach(id => expandState[id] = false); renderNodes(); });
    const first = await page.evaluate(() => sourceOrder[0]);
    const g = await page.locator('.src-card').first().locator('.drag-handle').boundingBox();
    const last = await page.locator('.src-card').last().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2);
    await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, last.y + last.height + 10, { steps: 10 });
    await page.mouse.up(); await settle(page);
    expect(await page.evaluate(() => sourceOrder[sourceOrder.length - 1]) === first, 'order: ' + await page.evaluate(() => sourceOrder.join()));
  });

  await check('nodes: grip centred on subscription block', async () => {
    const off = await page.evaluate(() => [...document.querySelectorAll('.src-card')].map(c => {
      const t = c.querySelector('.src-top').getBoundingClientRect(), g = c.querySelector('.src-top > .drag-handle svg').getBoundingClientRect();
      return Math.abs((t.top + t.height / 2) - (g.top + g.height / 2));
    }));
    expect(off.every(d => d < 1.5), 'offsets ' + off.join());
    await page.evaluate(() => setNodesEdit(false));
  });

  await check('nodes: add subscription', async () => {
    const n = await page.evaluate(() => sourceOrder.length);
    await page.click('.icon-btn.primary'); await settle(page);
    await page.click('#sh-addmenu .menu-row >> nth=0'); await settle(page);
    await page.fill('#sf-url', 'https://sub.test.org/api/sub/abc');
    await page.click('#sfSaveBtn');
    await page.waitForTimeout(1400);
    const [count, nodes] = await page.evaluate(() => [sourceOrder.length, sourcesData[sourceOrder[sourceOrder.length - 1]].nodes.length]);
    expect(count === n + 1 && nodes > 0, `sources ${count}, nodes ${nodes}`);
  });

  await check('nodes: manual server from share link', async () => {
    await page.evaluate(() => openNodeForm());
    await page.fill('#nf-link', 'hy2://pass@5.6.7.8:8443?sni=x#My%20HY2');
    await page.dispatchEvent('#nf-link', 'input');
    await page.click('#nfSaveBtn');
    const found = await page.evaluate(() => Object.values(sourcesData).some(s => s.nodes.some(n => n.name === 'My HY2' && n.protocol === 'hy2' && n.port === '8443')));
    expect(found, 'server not added');
  });

  /* ── Logs, share / QR, manual servers, Data, latency URL, empty catalog, source error,
     live connections, last profile, language ── */
  const stubClipboard = p => p.evaluate(() => {
    window.__copied = null;
    Object.defineProperty(navigator, 'clipboard', { configurable: true,
      value: { writeText: t => { window.__copied = t; return Promise.resolve(); }, readText: () => Promise.resolve('') } });
  });
  const toastText = p => p.textContent('#toast');
  // these checks add servers and restore a backup: the checks after them get the state back
  const stateBefore = await page.evaluate(() => JSON.stringify(liveSnapshot()));

  await check('share: the page reads vmess base64, legacy ss, SIP002, IPv6, anytls, hy2 port ranges', async () => {
    const got = await page.evaluate(links => links.concat([
      'ss://' + btoa('chacha20-ietf-poly1305:pw').replace(/=+$/, '') + '@203.0.113.9:8388#SIP',
      'hysteria2://pw@hy.example:443,20000-30000/?sni=hy.example#Hop',
      'vless://u@[2001:db8::2]:8443?security=reality#V6',
      'nonsense',
    ]).map(l => { const r = parseShareLinkLite(l); return r && [r.protocol, r.address, r.port, r.secret, r.name].join('|'); }), SAMPLE_LINKS);
    const want = [
      'vmess|nl1.example.net|443|11111111-2222-3333-4444-555555555555|🇳🇱 Amsterdam VM',
      'ss|198.51.100.7|8388|aes-256-gcm:pa55|Legacy SS',
      'trojan|2001:db8::1|443|secret|🇩🇪 Berlin v6',
      'anytls|any.example|8443|pw|AnyTLS 1',
      'ss|203.0.113.9|8388|chacha20-ietf-poly1305:pw|SIP',
      'hy2|hy.example|443|pw|Hop',
      'vless|2001:db8::2|8443|u|V6',
      null,
    ];
    const bad = got.map((g, i) => g === want[i] ? null : `${i}: ${g} ≠ ${want[i]}`).filter(Boolean);
    expect(!bad.length, bad.join(' | '));
  });

  await check('share: Copy URL / Copy share link really copy; the mock link reads back as the same server', async () => {
    await stubClipboard(page);
    await tab(page, 'nodes');
    await page.evaluate(() => openSourceActions('src1'));
    await page.click('#actions-body .menu-row:has-text("Copy URL")');
    await page.waitForTimeout(50);
    expect(await page.evaluate(() => window.__copied === sourcesData.src1.url), 'url: ' + await page.evaluate(() => window.__copied));
    const nid = await page.evaluate(() => sourcesData.src1.nodes[0].id);
    await page.evaluate(n => openNodeActions('src1', n), nid);
    await page.click('#actions-body .menu-row:has-text("Copy share link")');
    await page.waitForTimeout(50);
    const r = await page.evaluate(n => {
      const node = sourcesData.src1.nodes.find(x => x.id === n), p = parseShareLinkLite(window.__copied);
      return { link: window.__copied, ok: !!p && p.protocol === node.protocol && p.address === node.address && p.port === String(node.port) };
    }, nid);
    expect(r.ok, 'share link: ' + r.link);
    // every mock server's link reads back as itself
    const bad = await page.evaluate(() => Object.values(sourcesData).flatMap(s => s.nodes).filter(n => {
      const l = mockShareLink(n), p = l && parseShareLinkLite(l);
      return l && !(p && p.protocol === n.protocol && p.address === n.address && p.port === String(n.port));
    }).map(n => n.protocol + ' ' + n.address));
    expect(!bad.length, 'links that do not read back: ' + bad.join(', '));
  });

  await check('share: Show QR code draws the link as a QR in the sheet', async () => {
    const nid = await page.evaluate(() => sourcesData.src1.nodes[0].id);
    await page.evaluate(n => showNodeQr('src1', n), nid);
    await page.waitForSelector('#sh-actions.open .qr-svg');
    const r = await page.evaluate(() => {
      const svg = document.querySelector('#actions-body .qr-svg'), text = document.querySelector('#actions-body .qr-text').textContent;
      const size = +svg.getAttribute('viewBox').split(' ')[2];
      return { size, want: QR.encode(text, 'M').size + 8, path: svg.querySelector('.qr-dark').getAttribute('d').length, text };
    });
    expect(r.size === r.want && r.path > 100 && /:\/\//.test(r.text), JSON.stringify(r));
    await page.evaluate(() => closeSheet('actions'));
  });

  await check('chain editor: tapping the other end swaps entry and exit (two profiles only: no other way to turn it); a chain lists no source under its servers', async () => {
    const r = await page.evaluate(() => {
      setConnectMode('profiles'); openProfiles(); openEditChain('cpdefault');
      const before = [chainDraft.inId, chainDraft.outId];
      document.querySelector(`#cc-in-list .cc-prof[data-id="${before[1]}"] .pick-row`).click();
      const after = [chainDraft.inId, chainDraft.outId];
      closeSheet('createchain');
      return { before, after };
    });
    expect(r.after[0] === r.before[1] && r.after[1] === r.before[0], JSON.stringify(r));
    const src = await page.evaluate(() => { const c = Object.values(chainsData).find(c => sourcesData[c.inId] && sourcesData[c.outId]);
      if (!c) return 'none'; return entryNodeRowsHtml(chainEntryRefs(c), null).includes('node-src') ? 'shown' : 'hidden'; });
    expect(src !== 'shown', 'source repeated in chain rows');
  });

  await check('speed test: the node ⋮ runs it — latency, download, upload fill in, then Done; closing the sheet stops it', async () => {
    const nid = await page.evaluate(() => sourcesData.src1.nodes.find(x => truthOf(x) >= 0).id);
    await page.evaluate(n => openNodeActions('src1', n), nid);
    expect(await page.evaluate(() => /Speed test/.test(document.getElementById('actions-body').textContent)), 'no Speed test row in the node menu');
    await page.evaluate(n => { closeSheet('actions'); openSpeedTest('src1', n); }, nid);
    await page.waitForFunction(() => /Done/.test((document.querySelector('#speed-card .speed-status') || {}).textContent || ''), null, { timeout: 12000 });
    const vals = await page.evaluate(() => [...document.querySelectorAll('#speed-card .speed-big, #speed-card .speed-stat b')].map(e => e.textContent));
    expect(vals.every(v => /^\d/.test(v)), 'numbers missing: ' + vals.join(' | '));
    expect(/Run again/.test(await page.textContent('#speed-card .speed-btn')), 'no Run again when done');
    // Run again restarts in place; Stop keeps the numbers so far and offers Run again
    await page.click('#speed-card .speed-btn');
    await page.waitForTimeout(1200);
    expect(/Stop/.test(await page.textContent('#speed-card .speed-btn')), 'no Stop while running');
    await page.click('#speed-card .speed-btn');
    const stopped = await page.evaluate(() => [document.querySelector('#speed-card .speed-status-text').textContent, document.querySelector('#speed-card .speed-btn').textContent]);
    expect(stopped[0] === 'Stopped' && /Run again/.test(stopped[1]), 'stop: ' + stopped.join(' | '));
    // a Go error shows in plain words, the raw text under it
    await page.evaluate(n => { const m = truthOf; truthOf = x => x.id === n ? -1 : m(x); openSpeedTest('src1', n); truthOf = m; }, nid);
    await page.waitForFunction(() => document.querySelector('#speed-card.failed'), null, { timeout: 4000 });
    const err = await page.textContent('#speed-card .speed-err');
    expect(/did not answer in time/.test(err) && /TLS handshake timeout/.test(err), 'error text: ' + err);
    // a second run closed early must not keep drawing
    await page.evaluate(n => openSpeedTest('src1', n), nid);
    await page.evaluate(() => closeSheet('actions'));
    await page.waitForTimeout(600);
    expect(await page.evaluate(() => !document.querySelector('#sh-actions.open')), 'sheet reopened');
  });

  await check('nodes form: several links add every server once; the same again adds none; an edit keeps the id', async () => {
    await page.evaluate(() => openNodeForm());
    await page.fill('#nf-link', SAMPLE_LINKS.join('\n'));
    await page.dispatchEvent('#nf-link', 'input');
    expect(await page.isHidden('#nf-fields'), 'fields still shown for several links');
    expect(/Add 4 servers/.test(await page.textContent('#nfSaveBtn')), 'button: ' + await page.textContent('#nfSaveBtn'));
    const before = await page.evaluate(() => sourceOrder.length);
    await page.click('#nf-group .chip[data-gid=__new]');
    await page.click('#nfSaveBtn');
    await page.waitForTimeout(100);
    const g = await page.evaluate(() => sourceOrder[sourceOrder.length - 1]);
    const r1 = await page.evaluate(id => ({ n: sourcesData[id].nodes.length, names: sourcesData[id].nodes.map(n => n.flag + n.name), ids: new Set(sourcesData[id].nodes.map(n => n.id)).size }), g);
    expect(await page.evaluate(() => sourceOrder.length) === before + 1 && r1.n === 4 && r1.ids === 4, JSON.stringify(r1));
    expect(r1.names.includes('🇩🇪Berlin v6') && r1.names.includes('🇳🇱Amsterdam VM'), 'names: ' + r1.names.join(', '));
    // the same links into the same group: nothing new
    await page.evaluate(id => openNodeForm(id), g);
    await page.fill('#nf-link', SAMPLE_LINKS.join('\n'));
    await page.dispatchEvent('#nf-link', 'input');
    await page.click('#nfSaveBtn');
    await page.waitForTimeout(100);
    expect(await page.evaluate(id => sourcesData[id].nodes.length, g) === 4, 'duplicates added');
    expect(/already in the group/.test(await toastText(page)), 'toast: ' + await toastText(page));
    await page.evaluate(() => closeSheet('nodeform'));
    // no link, no address: asks for the address; an anytls link alone needs none
    await page.evaluate(() => openNodeForm());
    await page.click('#nfSaveBtn');
    expect(/Address is required/.test(await toastText(page)), 'empty form: ' + await toastText(page));
    await page.fill('#nf-link', 'anytls://pw@any2.example:443#A2');
    await page.dispatchEvent('#nf-link', 'input');
    await page.fill('#nf-addr', '');
    await page.click('#nfSaveBtn');
    await page.waitForTimeout(100);
    expect(await page.evaluate(() => Object.values(sourcesData).some(s => s.nodes.some(n => n.address === 'any2.example'))), 'anytls link not added');
    // edit: new port, same id; the secret field follows the protocol
    const nid = await page.evaluate(id => sourcesData[id].nodes[0].id, g);
    await page.evaluate(([id, n]) => openNodeForm(id, n), [g, nid]);
    expect(await page.textContent('#nf-secret-label') === 'UUID', 'label: ' + await page.textContent('#nf-secret-label'));
    await page.fill('#nf-port', '2053');
    await page.click('#nfSaveBtn');
    await page.waitForTimeout(100);
    const r2 = await page.evaluate(([id, n]) => { const x = sourcesData[id].nodes.find(y => y.id === n); return x && x.port + ' ' + x.name; }, [g, nid]);
    expect(r2 === '2053 Amsterdam VM', 'edited: ' + r2);
  });

  await check('logs (Raw tab): lines, level filter, search, follow / pause, copy, clear', async () => {
    await tab(page, 'logs');
    await page.evaluate(() => setLogTab('raw'));
    await page.waitForTimeout(500);
    expect(await page.isVisible('#view-logs'), 'logs view hidden');
    const n0 = await page.locator('#logList .log-line').count();
    expect(n0 > 40, 'lines: ' + n0);
    await page.evaluate(() => setLogLevel('warn'));
    const lv = await page.evaluate(() => [...document.querySelectorAll('#logList .log-line')].map(l => l.className));
    expect(lv.length && lv.every(c => /warn|error/.test(c)), 'warn filter: ' + lv.join(','));
    await page.evaluate(() => setLogLevel('all'));
    await page.click('#logSearchBtn');
    await page.fill('#logSearch', 'discord');
    const found = await page.evaluate(() => [...document.querySelectorAll('#logList .log-line')].map(l => l.textContent.toLowerCase()));
    expect(found.length && found.every(t => t.includes('discord')) && await page.locator('#logList mark').count() > 0, 'search: ' + found.length);
    await page.click('#logSearchBar .icon-btn');
    // scrolled up: stops following, new lines are counted on the pill; the pill goes back down
    await page.evaluate(() => { document.getElementById('logScroll').scrollTop = 0; });
    await page.waitForTimeout(100);
    await page.evaluate(() => { for (let i = 0; i < 3; i++) mockLogAdd('sing-box', 'info', 'test line ' + i); });
    await page.waitForTimeout(1200);
    expect(await page.isVisible('#logJump') && /new/.test(await page.textContent('#logJump')), 'pill: ' + await page.textContent('#logJump'));
    await page.click('#logJump');
    await page.waitForTimeout(100);
    const atEnd = await page.evaluate(() => { const b = document.getElementById('logScroll'); return logState.follow && b.scrollTop + b.clientHeight >= b.scrollHeight - 2; });
    expect(atEnd, 'not back at the end');
    await stubClipboard(page);
    await page.evaluate(() => copyLogs());
    const copied = await page.evaluate(() => window.__copied || '');
    expect(copied.split('\n').length === await page.locator('#logList .log-line').count() && /test line 2/.test(copied), 'copied ' + copied.split('\n').length + ' lines');
    // new lines may land right after the clear (the mock keeps logging); none from before
    const nAt = await page.evaluate(() => { const n = mockLog.n; clearLogs(); return n; });
    await page.waitForTimeout(100);
    const left = await page.evaluate(n => ({ old: logState.lines.filter(l => l.n < n).length, kept: logState.lines.length,
      dom: document.querySelectorAll('#logList .log-line').length, empty: !!document.querySelector('#logList .log-empty') }), nAt);
    expect(!left.old && left.dom === left.kept && (left.kept || left.empty), 'not cleared: ' + JSON.stringify(left));
  });

  await check('connections: filter by host / app / rule, × closes one, Close all', async () => {
    await tab(page, 'home');
    await page.evaluate(() => { connected = true; return backend.traffic().then(t => { traffic = t; openSheet('connections'); renderTraffic(); }); });
    await page.waitForTimeout(300);
    const rows = () => page.locator('#liveConnList .live-conn-row').count();
    const n0 = await rows();
    await page.fill('#connFilter', 'discord');
    expect(n0 >= 3 && await rows() === 3, `filter: ${n0} → ${await rows()}`);
    await page.fill('#connFilter', 'svchost');
    expect(await rows() === 2, 'by app: ' + await rows());
    await page.fill('#connFilter', '');
    await page.click('#liveConnList .live-conn-row >> nth=0 >> .live-conn-close');
    await page.waitForTimeout(100);
    expect(await rows() === n0 - 1, `× : ${n0} → ${await rows()}`);
    await page.waitForTimeout(1100);   // the next poll keeps it closed
    expect(await rows() === n0 - 1, 'closed one came back: ' + await rows());
    await page.click('#connMoreBtn');
    await page.waitForTimeout(350);
    expect(/Close all/.test(await page.textContent('#actions-body')), 'menu label: ' + await page.textContent('#actions-body'));
    await page.click('#actions-body .menu-row.danger');
    await page.waitForTimeout(150);
    expect(await rows() === 0 && /No open connections/.test(await page.textContent('#liveConnList')), 'close all: ' + await rows());
    await page.evaluate(() => { mockClosed.clear(); closeSheet('connections'); });
  });

  // Live connections tools: sort, filter sheet, pause, close shown, details (76-conns.js)
  await check('connections: sort, filter (OR inside a section, AND across), pause, close shown, details, rule prefill', async () => {
    await tab(page, 'home');
    await page.evaluate(() => { mockClosed.clear(); connected = true; return backend.traffic().then(t => { traffic = t; openSheet('connections'); renderTraffic(); }); });
    await page.waitForTimeout(300);
    const hosts = () => page.evaluate(() => [...document.querySelectorAll('#liveConnList .live-conn-row .live-conn-host')].map(e => e.textContent));
    const n0 = (await hosts()).length;
    // sort by download speed: the fastest first, and the label on the button
    await page.click('#connSortBtn'); await page.waitForTimeout(350);
    await page.click('#actions-body .menu-row >> nth=1'); await page.waitForTimeout(150);
    const bySpeed = await page.evaluate(() => connShown().map(c => c.downRate));
    expect(bySpeed.every((v, i) => !i || bySpeed[i - 1] >= v) && bySpeed[0] === Math.max(...bySpeed) && await page.textContent('#connSortLabel') === '↓ speed', 'sort: ' + bySpeed);
    await page.evaluate(() => { connSort = 'new'; renderLiveConns(); });
    // filter: Chrome or Telegram (OR) and TCP (AND); Back applies nothing, ✓ does
    await page.click('#connFilterBtn'); await page.waitForTimeout(350);
    const tog = (k, v) => page.click(`#cf-body .cf-row[data-k=${k}][data-v="${v}"]`);
    await tog('app', 'chrome.exe'); await tog('app', 'Telegram.exe'); await tog('net', 'tcp');
    await page.evaluate(() => closeSheet('connfilter')); await page.waitForTimeout(350);
    expect((await hosts()).length === n0 && !await page.isVisible('#connFilterBadge'), 'closed without ✓ must apply nothing');
    await page.click('#connFilterBtn'); await page.waitForTimeout(350);
    await tog('app', 'chrome.exe'); await tog('app', 'Telegram.exe'); await tog('net', 'tcp');
    await page.click('#cfApply'); await page.waitForTimeout(350);
    const filtered = await hosts();
    expect(filtered.length === 4 && !filtered.some(h => h === 'www.youtube.com') && await page.textContent('#connFilterBadge') === '3', 'filter: ' + filtered + ' badge ' + await page.textContent('#connFilterBadge'));
    // reopened: a selected value with no connection stays with 0; trash clears the draft
    await page.click('#connFilterBtn'); await page.waitForTimeout(350);
    expect(await page.locator('#cf-body .sub-checkbox.checked').count() === 3, 'the selection is not restored');
    await page.click('#cfClear'); expect(await page.locator('#cf-body .sub-checkbox.checked').count() === 0, 'trash');
    await page.evaluate(() => closeSheet('connfilter')); await page.waitForTimeout(350);
    // close shown: only the 4 filtered ones go
    await page.click('#connMoreBtn'); await page.waitForTimeout(350);
    expect(/Close 4 shown/.test(await page.textContent('#actions-body')), 'label: ' + await page.textContent('#actions-body'));
    await page.click('#actions-body .menu-row.danger'); await page.waitForTimeout(200);
    await page.evaluate(() => { connF = connFNew(); renderLiveConns(); });
    expect((await hosts()).length === n0 - 4, `close shown: ${n0} → ${(await hosts()).length}`);
    await page.evaluate(() => { mockClosed.clear(); });
    // pause: the list freezes, new ones only grow the banner
    await page.evaluate(() => { backend.traffic().then(t => { traffic = t; renderLiveConns(); }); });
    await page.waitForTimeout(150);
    const before = await hosts();
    await page.click('#connMoreBtn'); await page.waitForTimeout(350);
    await page.click('#actions-body .menu-row >> nth=0'); await page.waitForTimeout(150);
    await page.evaluate(() => { traffic.conns.push({ ...traffic.conns[0], id: 'n1', host: 'fresh1.example' }, { ...traffic.conns[0], id: 'n2', host: 'fresh2.example' }); renderLiveConns(); });
    expect(JSON.stringify(await hosts()) === JSON.stringify(before) && /2 new connections/.test(await page.textContent('#connPaused')), 'pause: ' + await page.textContent('#connPaused'));
    await page.click('#connPaused button'); await page.waitForTimeout(100);
    expect(!await page.isVisible('#connPaused') && await page.evaluate(() => !connPaused), 'resume');
    // details and the rule prefill
    await page.click('#liveConnList .live-conn-row[data-id="discord.com"] .live-conn-meta'); await page.waitForTimeout(100);
    expect(await page.locator('#liveConnList .live-conn-detail').count() === 1 && /Discord\.exe/.test(await page.textContent('.live-conn-detail')), 'detail');
    await page.click('.live-conn-detail .chip:has-text("Rule for this host")'); await page.waitForTimeout(400);
    const rd = await page.evaluate(() => JSON.stringify(ruleDraft.groups));
    expect(/"domain":\["discord.com"\]/.test(rd), 'host prefill: ' + rd);
    await page.evaluate(() => { closeSheet('ruleform'); connOpen = '1.1.1.1'; renderLiveConns(); });
    expect(await page.locator('.live-conn-detail .chip:has-text("Rule for this app")').count() === 0, 'no app, no app rule');
    await page.evaluate(() => { connOpen = '224.0.0.251/udp'; renderLiveConns(); });
    await page.click('.live-conn-detail .chip:has-text("Rule for this address")'); await page.waitForTimeout(300);
    expect(/ip_cidr":\["224.0.0.251\/32"\]/.test(await page.evaluate(() => JSON.stringify(ruleDraft.groups))), 'ip prefill');
    await page.evaluate(() => { ruleDraft = newRule({}); renderRuleForm(); closeSheet('ruleform'); mockClosed.clear(); closeSheet('connections'); });
  });

  // The rule a connection went by is the user's rule name; sing-box's raw text stays in the details (76-conns.js)
  await check('connections: rows, the Rule filter and search show rule names, the raw text only in the details; Open rule opens the rule / the app', async () => {
    await tab(page, 'home');
    await page.evaluate(() => { mockClosed.clear(); connected = true; connGroup = 'service'; connFolded.clear(); connF = connFNew(); return backend.traffic().then(t => { traffic = t; openSheet('connections'); renderTraffic(); }); });
    await page.waitForTimeout(300);
    const list = () => page.textContent('#liveConnList');
    const text = await list();
    expect(/Work network/.test(text) && /Discord voice/.test(text) && /My region direct/.test(text) && /Private networks/.test(text) && !/domain_suffix|ip_is_private|package_name|rule_set=/.test(text), 'raw text in rows: ' + text.slice(0, 300));
    // the Rule section of the filter: names (and Default / final), never the raw text
    await page.click('#connFilterBtn'); await page.waitForTimeout(350);
    const secs = await page.textContent('#cf-body');
    expect(/Work network/.test(secs) && /YouTube/.test(secs) && /Private networks/.test(secs) && /Default \/ final/.test(secs) && !/domain_suffix|ip_is_private/.test(secs), 'filter: ' + secs.slice(0, 300));
    await page.evaluate(() => closeSheet('connfilter')); await page.waitForTimeout(350);
    // search: by name, and by the raw text
    const rows = () => page.locator('#liveConnList .live-conn-row').count();
    await page.fill('#connFilter', 'work network');
    expect(await rows() === 1 && /wiki\.corp\.local/.test(await list()), 'search by name: ' + await rows());
    await page.fill('#connFilter', 'intra.example');
    expect(await rows() === 1, 'search by the raw text: ' + await rows());
    await page.fill('#connFilter', '');
    // details: the name, the raw text under it dimmed; Open rule for a user rule
    await page.evaluate(() => { connOpen = 'wiki.corp.local'; renderLiveConns(); });
    const det = await page.textContent('.live-conn-detail');
    expect(/Work network/.test(det) && await page.locator('.live-conn-detail .lcd-raw').textContent() === 'domain_suffix=[corp.local intra.example.com]', 'detail: ' + det);
    await page.click('.live-conn-detail .chip:has-text("Open rule")'); await page.waitForTimeout(400);
    expect(await page.evaluate(() => ruleEditing === 'r1' && document.getElementById('sh-ruleform').classList.contains('open')), 'Open rule did not open the rule form');
    await page.evaluate(() => closeSheet('ruleform')); await page.waitForTimeout(350);
    // an app's own rule: its dialog
    await page.evaluate(() => { connOpen = 'discord.com'; renderLiveConns(); });
    await page.click('.live-conn-detail .chip:has-text("Open rule")'); await page.waitForTimeout(400);
    expect(await page.evaluate(() => appEditing === 'com.discord' && document.getElementById('sh-appact').classList.contains('open')), 'Open rule did not open the app dialog');
    await page.evaluate(() => closeSheet('appact')); await page.waitForTimeout(350);
    // no rule of the user's to open: a service, a quick rule, the final route, an unnamed one (raw text shown)
    for (const id of ['rr3.googlevideo.com', 'mirror.yandex.ru', 'gitlab.com']) {
      await page.evaluate(i => { connOpen = i; renderLiveConns(); }, id);
      expect(await page.locator('.live-conn-detail .chip:has-text("Open rule")').count() === 0, 'Open rule on ' + id);
    }
    await page.evaluate(() => { traffic.conns.push({ ...traffic.conns[0], id: 'raw1', host: 'raw.example', rule: 'port=9999', ruleKind: '', ruleName: '' }); connOpen = 'raw1'; renderLiveConns(); });
    expect(/port=9999/.test(await page.textContent('[data-id="raw1"] .live-conn-meta')) && await page.locator('.live-conn-detail .lcd-raw').count() === 0, 'a rule with no name shows its raw text');
    await page.evaluate(() => { connOpen = null; mockClosed.clear(); closeSheet('connections'); });
  });

  // Groups: Service by default, fold kept, Group by App / None, × closes a group, copy (76-conns.js)
  await check('connections: grouped by service by default, a group folds, Group by App, None restores the flat list', async () => {
    await tab(page, 'home');
    await page.evaluate(() => { mockClosed.clear(); connected = true; connGroup = 'service'; connSort = 'new'; connFolded.clear(); connF = connFNew(); return backend.traffic().then(t => { traffic = t; openSheet('connections'); renderTraffic(); }); });
    await page.waitForTimeout(300);
    const heads = () => page.evaluate(() => [...document.querySelectorAll('#liveConnList .live-group .lg-title')].map(e => e.textContent));
    const rows = () => page.locator('#liveConnList .live-conn-row').count();
    const n0 = await rows();
    const h = await heads();
    for (const g of ['YouTube', 'Telegram', 'Discord', 'github.com', 'yandex.ru', 'gitlab.com', 'corp.local', 'svchost.exe', 'Other']) expect(h.includes(g), 'no group ' + g + ': ' + h);
    expect(h[0] === 'svchost.exe', 'Newest: the group with the newest connection first: ' + h);
    const yt = await page.evaluate(() => { const g = [...document.querySelectorAll('.live-group')].find(x => x.querySelector('.lg-title').textContent === 'YouTube'); return { n: g.querySelector('.lg-n').textContent, rate: g.textContent, rows: [...(function* () { for (let e = g.nextElementSibling; e && !e.classList.contains('live-group'); e = e.nextElementSibling) yield e.dataset.id; })()] }; });
    expect(yt.n === '3' && /MB\/s/.test(yt.rate) && yt.rows.length === 3 && yt.rows.includes('rr3.googlevideo.com'), 'YouTube group: ' + JSON.stringify(yt));
    // sort applies to the groups by their sum, and inside them
    await page.evaluate(() => { connSort = 'down'; renderLiveConns(); });
    const h2 = await heads();
    expect(h2[0] === 'yandex.ru' && h2.indexOf('YouTube') === 1, 'by ↓ speed: ' + h2);
    await page.evaluate(() => { connSort = 'new'; renderLiveConns(); });
    // fold: the rows go, the header stays with its count; the fold survives a redraw and the Sort menu
    await page.click('.live-group:has(.lg-title:text-is("YouTube"))'); await page.waitForTimeout(100);
    expect(await rows() === n0 - 3 && await page.locator('.live-group.folded').count() === 1, 'fold: ' + await rows());
    await page.evaluate(() => renderLiveConns());
    expect(await rows() === n0 - 3, 'the fold did not survive a redraw');
    await page.fill('#connFilter', 'youtube');   // a search shows what it finds, folded or not
    expect(await rows() === 2, 'search inside a folded group: ' + await rows());
    await page.fill('#connFilter', '');
    await page.click('.live-group:has(.lg-title:text-is("YouTube"))'); await page.waitForTimeout(100);
    expect(await rows() === n0, 'unfold: ' + await rows());
    // copy: a header line before each group
    const copied = await page.evaluate(() => { let got = ''; const was = copyText; copyText = t => { got = t; }; connCopyShown(); copyText = was; return got; });
    expect(/^# svchost\.exe · \d+ connections? · ↓ /.test(copied) && /\n# YouTube · 3 connections · ↓ /.test(copied), 'copy: ' + copied.slice(0, 200));
    // Group by App
    await page.click('#connSortBtn'); await page.waitForTimeout(350);
    expect(/Group by/.test(await page.textContent('#actions-body')), 'the Sort menu has Group by');
    await page.click('#actions-body .menu-row >> nth=7'); await page.waitForTimeout(150);
    const ha = await heads();
    expect(ha.includes('chrome.exe') && ha.includes('Discord.exe') && ha.includes('Unknown') && !ha.includes('YouTube') && await rows() === n0, 'by app: ' + ha);
    // None: the flat list again
    await page.click('#connSortBtn'); await page.waitForTimeout(350);
    await page.click('#actions-body .menu-row >> nth=8'); await page.waitForTimeout(150);
    expect(await page.locator('.live-group').count() === 0 && await rows() === n0, 'None: ' + await page.locator('.live-group').count());
    // back to Service; × on a header closes the group's connections
    await page.click('#connSortBtn'); await page.waitForTimeout(350);
    await page.click('#actions-body .menu-row >> nth=6'); await page.waitForTimeout(150);
    await page.click('.live-group:has(.lg-title:text-is("Telegram")) .live-conn-close'); await page.waitForTimeout(150);
    const after = await heads();
    expect(!after.includes('Telegram') && await rows() === n0 - 2, 'close group: ' + after + ' ' + await rows());
    await page.evaluate(() => { connFolded.clear(); mockClosed.clear(); closeSheet('connections'); });
  });

  await check('nodes: a failed update shows the error on the card; Retry clears it', async () => {
    await tab(page, 'nodes');
    const url = await page.evaluate(() => { const u = sourcesData.src1.url; sourcesData.src1.url = 'https://fail.example/sub'; updateSource('src1'); return u; });
    await page.waitForFunction(() => !sourcesData.src1.updating, null, { timeout: 4000 });
    const err = await page.textContent('.src-card[data-id=src1] .src-error').catch(() => '');
    expect(/Update failed/.test(err) && /timed out/.test(err) && await page.evaluate(() => !!sourcesData.src1.lastError), 'error strip: ' + err);
    await page.evaluate(u => { sourcesData.src1.url = u; }, url);
    await page.click('.src-card[data-id=src1] .src-error-retry');
    await page.waitForFunction(() => !sourcesData.src1.updating, null, { timeout: 4000 });
    expect(await page.locator('.src-card[data-id=src1] .src-error').count() === 0 && await page.evaluate(() => !sourcesData.src1.lastError), 'still shows the error');
  });

  await check('settings: latency test URL — a preset or a custom address goes to connCfg.testUrl', async () => {
    await tab(page, 'settings');
    await page.evaluate(() => openSheet('setconn'));
    await page.click('#conn-testurl');
    await page.click('#actions-body .menu-row:has-text("Cloudflare")');
    expect(await page.evaluate(() => connCfg.testUrl) === 'https://cp.cloudflare.com/generate_204' && /Cloudflare/.test(await page.textContent('#conn-testurl')), 'preset: ' + await page.evaluate(() => connCfg.testUrl));
    await page.click('#conn-testurl');
    await page.fill('#testurl-input', 'ftp://nope');
    await page.click('.testurl-custom .btn-primary');
    expect(await page.evaluate(() => connCfg.testUrl) === 'https://cp.cloudflare.com/generate_204', 'bad URL taken');
    await page.fill('#testurl-input', 'https://probe.example.org/204');
    await page.click('.testurl-custom .btn-primary');
    expect(await page.evaluate(() => connCfg.testUrl) === 'https://probe.example.org/204' && /probe\.example\.org/.test(await page.textContent('#conn-testurl')), 'custom: ' + await page.evaluate(() => connCfg.testUrl));
    await page.evaluate(() => { setTestUrl(''); closeSheet('setconn'); });
  });

  await check('settings: TUN stack — Mixed by default, a choice goes to connCfg, the snapshot and the plan; proxy mode keeps the plan signature', async () => {
    const p = await openPage(browser);
    await p.evaluate(() => Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { n.outbound = { type: 'socks', server: '127.0.0.1', server_port: 1 }; n.unsupported = false; })));
    await tab(p, 'settings');
    await p.evaluate(() => openSheet('setconn'));
    const row = await p.evaluate(() => { const r = document.querySelector('[data-key=tunStack]'); return { soon: r.classList.contains('soon') || !!r.querySelector('.soon-tag'), btn: document.getElementById('conn-tunstack').textContent.trim(), hint: r.querySelector('.set-hint').textContent };
    });
    expect(!row.soon && row.btn === 'Mixed' && /TCP through the system stack/.test(row.hint), 'default row: ' + JSON.stringify(row));
    expect(await p.evaluate(() => connCfg.tunStack === 'mixed' && livePlan().tunStack === 'mixed'), 'default mixed');
    await p.click('#conn-tunstack');
    expect(await p.locator('#actions-body .menu-row').count() === 3, 'three options');
    await p.click('#actions-body .menu-row >> nth=1');   // System (the Mixed hint also says system)
    const r = await p.evaluate(() => ({ cfg: connCfg.tunStack, snap: liveSnapshot().connCfg.tunStack, plan: livePlan().tunStack, btn: document.getElementById('conn-tunstack').textContent.trim(), hint: document.querySelector('[data-key=tunStack] .set-hint').textContent }));
    expect(r.cfg === 'system' && r.snap === 'system' && r.plan === 'system' && r.btn === 'System' && /Fastest/.test(r.hint), JSON.stringify(r));
    // TUN mode: the signature follows the stack; proxy mode: it does not
    const sig = await p.evaluate(() => { const m = segState.mode, out = {};
      segState.mode = 'tun'; connCfg.tunStack = 'system'; const a = planSig(); connCfg.tunStack = 'gvisor'; out.tunDiffers = planSig() !== a;
      segState.mode = 'proxy'; connCfg.tunStack = 'system'; const b = planSig(); connCfg.tunStack = 'gvisor'; out.proxySame = planSig() === b;
      segState.mode = m; connCfg.tunStack = 'mixed'; renderConnSettings(); return out; });
    expect(sig.tunDiffers && sig.proxySame, JSON.stringify(sig));
    await p.evaluate(() => closeSheet('setconn'));
    await p.close();
  });

  await check('settings: IPv6 — off by default, the toggle goes to connCfg, the snapshot and the plan; it reconnects in TUN and in proxy mode; the row fits 320 px at 120 %', async () => {
    const p = await openPage(browser, { width: 320 });
    await p.evaluate(() => { applyScale(UI_SCALE_MAX); Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { n.outbound = { type: 'socks', server: '127.0.0.1', server_port: 1 }; n.unsupported = false; })); });
    await tab(p, 'settings');
    await p.evaluate(() => openSheet('setconn'));
    const row = await p.evaluate(() => { const r = document.querySelector('[data-key=ipv6]'); return { on: r.querySelector('.mini-toggle').classList.contains('on'), hint: r.querySelector('.set-hint').textContent }; });
    expect(!row.on && /Leave off unless/.test(row.hint), 'default off: ' + JSON.stringify(row));
    expect(await p.evaluate(() => connCfg.ipv6 === false && livePlan().ipv6 === false), 'plan default false');
    await p.click('[data-key=ipv6] .mini-toggle');
    const r = await p.evaluate(() => ({ cfg: connCfg.ipv6, snap: liveSnapshot().connCfg.ipv6, plan: livePlan().ipv6, on: document.querySelector('[data-key=ipv6] .mini-toggle').classList.contains('on') }));
    expect(r.cfg === true && r.snap === true && r.plan === true && r.on, JSON.stringify(r));
    // the DNS strategy counts in proxy mode too: the signature follows it in both modes
    const sig = await p.evaluate(() => { const m = segState.mode, out = {};
      for (const mode of ['tun', 'proxy']) { segState.mode = mode; connCfg.ipv6 = false; const a = planSig(); connCfg.ipv6 = true; out[mode] = planSig() !== a; }
      segState.mode = m; renderConnSettings(); return out; });
    expect(sig.tun && sig.proxy, JSON.stringify(sig));
    // 320 px at 120 %: the row stays inside the sheet
    const fit = await p.evaluate(() => { const r = document.querySelector('[data-key=ipv6]'), l = r.querySelector('.set-label').getBoundingClientRect(), t = r.querySelector('.mini-toggle').getBoundingClientRect(), b = r.getBoundingClientRect();
      return { labelRight: l.right, toggleLeft: t.left, toggleRight: t.right, rowRight: b.right, scroll: r.scrollWidth - r.clientWidth, w: innerWidth }; });
    expect(fit.labelRight <= fit.toggleLeft + 1 && fit.toggleRight <= fit.rowRight + 1 && fit.rowRight <= fit.w + 1 && fit.scroll <= 1, 'fit: ' + JSON.stringify(fit));
    await p.evaluate(() => { connCfg.ipv6 = false; closeSheet('setconn'); });
    await p.close();
  });

  await check('settings: backup checks — presets toggle, a custom address is added, bad ones are refused; they go with the Auto settings and every ping', async () => {
    await tab(page, 'settings');
    await page.evaluate(() => openSheet('setconn'));
    const n0 = await page.evaluate(() => connCfg.checkers.length);
    expect(n0 === 4 && (await page.textContent('#conn-checkers')).includes('4'), 'default: ' + n0);
    await page.click('#conn-checkers');
    await page.click('#actions-body .menu-row:has-text("Mozilla")');
    expect(await page.evaluate(() => connCfg.checkers.includes('http://detectportal.firefox.com/success.txt') && connCfg.checkers.length === 5), 'toggle on');
    await page.click('#actions-body .menu-row:has-text("Apple")');
    expect(await page.evaluate(() => !connCfg.checkers.includes('http://captive.apple.com/hotspot-detect.html')), 'toggle off');
    await page.fill('#checker-input', 'nope');
    await page.click('.testurl-custom .btn-primary');
    await page.fill('#checker-input', 'https://mine.example.org/ok');
    await page.click('.testurl-custom .btn-primary');
    const r = await page.evaluate(() => ({ list: connCfg.checkers.slice(), auto: planAuto().checkers }));
    expect(r.list.length === 5 && r.list.includes('https://mine.example.org/ok') && JSON.stringify(r.auto) === JSON.stringify(r.list), JSON.stringify(r));
    await page.evaluate(() => { connCfg.checkers = DEFAULT_CHECKERS.slice(); closeSheet('actions'); closeSheet('setconn'); });
  });

  await check('settings: Data — export downloads the snapshot; restore asks, then replaces the state', async () => {
    await page.evaluate(() => openDataSettings());
    await page.waitForTimeout(300);
    expect(/0\.1\.0/.test(await page.textContent('#data-settings')), 'about: ' + await page.textContent('#data-settings'));
    const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#data-export')]);
    expect(/^jormungand-backup-\d{4}-\d\d-\d\d\.json$/.test(dl.suggestedFilename()), 'file: ' + dl.suggestedFilename());
    const file = JSON.parse(readFileSync(await dl.path(), 'utf8'));
    const order = await page.evaluate(() => sourceOrder.join());
    expect(file.backup === 1 && file.snapshot.sourceOrder.join() === order, 'backup content: ' + Object.keys(file).join());
    // the whole state: settings, rules and DNS too
    const lacks = ['genCfg', 'rulesData', 'ruleOrder', 'appRules', 'quickCfg', 'dnsServers', 'dnsCfg'].filter(k => !(k in file.snapshot));
    expect(!lacks.length, 'backup lacks ' + lacks.join());
    // restore a changed copy: one source fewer, another renamed, a rule fewer, settings changed
    const gone = file.snapshot.sourceOrder.pop();
    delete file.snapshot.sourcesData[gone];
    file.snapshot.sourcesData[file.snapshot.sourceOrder[0]].name = 'Restored name';
    delete file.snapshot.rulesData[file.snapshot.ruleOrder.pop()];
    file.snapshot.genCfg.connectOnLaunch = true;
    file.snapshot.dnsCfg.fakeip = !file.snapshot.dnsCfg.fakeip;
    await page.setInputFiles('#restoreFile', { name: 'backup.json', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(file)) });
    await page.waitForSelector('#sh-actions.open .restore-card');
    expect(await page.evaluate(() => sourceOrder.length) === file.snapshot.sourceOrder.length + 1, 'replaced before the confirm');
    await page.click('#actions-body .menu-row:has-text("Restore")');
    await page.waitForTimeout(200);
    const r = await page.evaluate(() => ({ order: sourceOrder.join(), name: sourcesData[sourceOrder[0]].name,
      rules: ruleOrder.join(), launch: genCfg.connectOnLaunch, fakeip: dnsCfg.fakeip }));
    expect(r.order === file.snapshot.sourceOrder.join() && r.name === 'Restored name', JSON.stringify(r));
    expect(r.rules === file.snapshot.ruleOrder.join() && r.launch === true && r.fakeip === file.snapshot.dnsCfg.fakeip, 'rules / settings: ' + JSON.stringify(r));
    // not a backup: refused
    await page.setInputFiles('#restoreFile', { name: 'x.json', mimeType: 'application/json', buffer: Buffer.from('{"a":1}') });
    await page.waitForTimeout(200);
    expect(/Cannot restore/.test(await toastText(page)), 'toast: ' + await toastText(page));
  });
  await check('settings: Data — App updates: check, notes, download with progress and cancel, failure and retry, install, channel, auto-check, up to date, ru', async () => {
    const waitPhase = ph => page.waitForFunction(x => upd.phase === x, ph);
    const text = sel => page.textContent(sel);
    await page.evaluate(() => { Object.assign(mockUpdate, { find: true, checkFails: null, downloadFails: null, pauseAt: null }); Object.assign(upd, { phase: 'idle', offer: null, file: false, error: null, checkedAt: null }); genCfg.updChannel = 'stable'; genCfg.updates = true; openDataSettings(); });
    await page.waitForTimeout(300);
    let r = await page.evaluate(() => ({ t: document.getElementById('upd-block').textContent, ch: document.getElementById('upd-channel').textContent.trim(), on: document.getElementById('upd-auto').classList.contains('on'), card: !!document.getElementById('upd-card') }));
    expect(/0\.1\.0/.test(r.t) && /Not checked yet/.test(r.t) && r.ch === 'Stable' && r.on && !r.card, 'start: ' + JSON.stringify(r));
    expect(!/Check for app updates/.test(await page.textContent('#general-settings')), 'the General row moved to Data');
    // check: busy, then the offer with notes and the size
    await page.click('#upd-check');
    expect(/Checking/.test(await text('#upd-status')) && await page.isDisabled('#upd-check'), 'checking: ' + await text('#upd-status'));
    await waitPhase('available');
    r = await page.evaluate(() => ({ title: document.querySelector('.upd-title').textContent, notes: document.querySelector('.upd-notes').textContent, size: document.querySelector('.upd-size').textContent, btn: document.getElementById('upd-download').textContent }));
    expect(/Update 0\.2\.0 available/.test(r.title) && /switches faster/.test(r.notes) && /58/.test(r.size) && /Download & install/.test(r.btn), 'offer: ' + JSON.stringify(r));
    // download: progress stands at 50 %, Cancel keeps the offer
    await page.evaluate(() => { mockUpdate.pauseAt = 50; });
    await page.click('#upd-download');
    await page.waitForFunction(() => upd.received >= upd.offer.size * .5 - 1);
    r = await page.evaluate(() => ({ w: document.querySelector('.upd-bar div').style.width, line: document.getElementById('upd-pct').textContent, dis: document.getElementById('upd-check').disabled }));
    expect(r.w === '50%' && /50%/.test(r.line) && r.dis, 'progress: ' + JSON.stringify(r));
    await page.click('.upd-cancel');
    await waitPhase('available');
    expect(await page.isVisible('#upd-download'), 'cancel: back to Download & install');
    // a damaged file: error, Retry downloads again and gets through
    await page.evaluate(() => { mockUpdate.pauseAt = null; mockUpdate.downloadFails = 'hash'; });
    await page.click('#upd-download');
    await waitPhase('failed');
    r = await page.evaluate(() => ({ hint: document.getElementById('upd-status').textContent, line: document.querySelector('.upd-line.warn').textContent }));
    expect(/Download failed/.test(r.hint) && /damaged/.test(r.line) && await page.isVisible('#upd-retry'), 'failed: ' + JSON.stringify(r));
    await page.evaluate(() => { mockUpdate.downloadFails = null; });
    await page.click('#upd-retry');
    await waitPhase('ready');
    expect(/Ready to install/.test(await text('#upd-status')) && await page.isVisible('#upd-install'), 'ready');
    await page.click('#upd-install');
    await page.waitForTimeout(500);
    expect(/Installing the update/.test(await toastText(page)), 'install toast: ' + await toastText(page));
    // another check does not lose the downloaded file
    await page.click('#upd-check');
    await waitPhase('ready');
    // channel: Beta finds the beta build and drops the stable offer first
    await page.click('#upd-channel');
    await page.locator('#actions-body .menu-row').nth(1).click();
    await page.waitForTimeout(200);
    r = await page.evaluate(() => ({ ch: genCfg.updChannel, phase: upd.phase, card: !!document.getElementById('upd-card'), btn: document.getElementById('upd-channel').textContent.trim() }));
    expect(r.ch === 'beta' && r.phase === 'idle' && !r.card && r.btn === 'Beta', 'channel: ' + JSON.stringify(r));
    await page.click('#upd-check');
    await waitPhase('available');
    expect(/Update 0\.3\.0-beta\.1 available/.test(await text('.upd-title')) && /beta/i.test(await text('.upd-beta')), 'beta offer: ' + await text('.upd-title'));
    // auto-check
    await page.click('#upd-auto');
    expect(await page.evaluate(() => genCfg.updates === false && !document.getElementById('upd-auto').classList.contains('on')), 'auto-check off');
    await page.click('#upd-auto');
    expect(await page.evaluate(() => genCfg.updates === true), 'auto-check on');
    // up to date, a failed check with Retry
    await page.evaluate(() => { genCfg.updChannel = 'stable'; mockUpdate.find = false; });
    await page.click('#upd-check');
    await waitPhase('upToDate');
    expect(/up to date/i.test(await text('#upd-status')) && !await page.isVisible('#upd-card'), 'up to date: ' + await text('#upd-status'));
    await page.evaluate(() => { mockUpdate.checkFails = 'network'; });
    await page.click('#upd-check');
    await waitPhase('failed');
    r = await page.evaluate(() => ({ hint: document.getElementById('upd-status').textContent, warn: document.getElementById('upd-status').classList.contains('warn'), btn: document.getElementById('upd-check').textContent.trim() }));
    expect(/No update server answered/.test(r.hint) && r.warn && r.btn === 'Retry', 'check failed: ' + JSON.stringify(r));
    // Russian: the block, the notes in the manifest's own Russian
    await page.evaluate(() => { mockUpdate.checkFails = null; mockUpdate.find = true; });
    await page.click('#upd-check');
    await waitPhase('available');
    await page.evaluate(() => setGenCfg('lang', 'ru'));
    await page.waitForTimeout(200);
    r = await page.evaluate(() => ({ cap: document.querySelector('#upd-block .set-caption').textContent, title: document.querySelector('.upd-title').textContent, notes: document.querySelector('.upd-notes').textContent, btn: document.getElementById('upd-download').textContent, ch: document.getElementById('upd-channel').textContent.trim() }));
    expect(r.cap === 'Обновления приложения' && /Доступна версия 0\.2\.0/.test(r.title) && /Режим Auto быстрее/.test(r.notes) && r.btn === 'Скачать и установить' && r.ch === 'Стабильный', 'ru: ' + JSON.stringify(r));
    await page.evaluate(() => { setGenCfg('lang', 'en'); Object.assign(mockUpdate, { find: true, checkFails: null, downloadFails: null, pauseAt: null }); Object.assign(upd, { phase: 'idle', offer: null, file: false, error: null, checkedAt: null }); genCfg.updChannel = 'stable'; renderUpdates(); });
  });
  await check('settings: Data — state put back for the next checks', () => page.evaluate(s => { liveApply(JSON.parse(s)); renderAfterRestore(); closeSheet('setdata'); }, stateBefore));

  await check('general: Language — Русский switches every text live and English brings it back', async () => {
    await page.evaluate(() => openLangPicker());
    const rows = await page.locator('#actions-body .menu-row').allTextContents();
    expect(rows.length === 2 && /English/.test(rows[0]) && /Русский/.test(rows[1]) && !/soon/.test(rows[1]), 'rows: ' + rows.join(' | '));
    await page.locator('#actions-body .menu-row').nth(1).click(); await settle(page);
    const ru = await page.evaluate(() => ({ lang: genCfg.lang, tabs: [...document.querySelectorAll('.nav-btn')].map(b => b.textContent.trim()), set: document.querySelector('#view-settings .app-name').textContent.trim(), html: document.documentElement.lang,
      title: document.getElementById('evFilterBtn').title, toast: I18N.tr('Copied'), t: t('{0} nodes', 3) }));
    expect(ru.lang === 'ru' && ru.set === 'Настройки' && ru.html === 'ru' && ru.title === 'Фильтр событий' && ru.toast === 'Скопировано' && ru.t === '3 узла' && ru.tabs.join() !== '', 'ru: ' + JSON.stringify(ru));
    // text that JS writes later is translated too; the English original comes back with the language
    await page.evaluate(() => { const d = document.createElement('div'); d.id = 'i18nProbe'; d.textContent = 'No events yet'; document.body.appendChild(d); }); await settle(page);
    expect(await page.textContent('#i18nProbe') === 'Событий пока нет', 'live text: ' + await page.textContent('#i18nProbe'));
    await page.evaluate(() => { document.getElementById('i18nProbe').textContent = 'No rules yet'; }); await settle(page);
    expect(await page.textContent('#i18nProbe') === 'Правил пока нет', 'rewritten text: ' + await page.textContent('#i18nProbe'));
    await page.evaluate(() => setGenCfg('lang', 'en')); await settle(page);
    const en = await page.evaluate(() => ({ set: document.querySelector('#view-settings .app-name').textContent.trim(), probe: document.getElementById('i18nProbe').textContent, title: document.getElementById('evFilterBtn').title }));
    expect(en.set === 'Settings' && en.probe === 'No rules yet' && en.title === 'Filter events', 'en: ' + JSON.stringify(en));
    await page.evaluate(() => { document.getElementById('i18nProbe').remove(); closeSheet('actions'); });
  });

  await check('home: empty catalog — the dock says No servers yet, a tap (or power) goes to Nodes → +', async () => {
    const p = await openPage(browser);
    await p.evaluate(() => { liveApply(null); connected = false; renderAll(); renderConnState(); updateMainConnectCard(); });
    const dock = async () => (await p.textContent('#profCardName')) + ' / ' + (await p.textContent('#profModeDetail'));
    expect(/No servers yet \/ Add in Nodes/.test(await dock()), 'dock: ' + await dock());
    await p.click('.dock-profile');
    await p.waitForTimeout(300);
    expect(await p.isVisible('#view-nodes') && await p.evaluate(() => document.getElementById('sh-addmenu').classList.contains('open')), 'not at Nodes → +');
    await p.evaluate(() => { switchTab('home'); setConnectMode('profiles'); });
    expect(/No profiles yet \/ Create one in Nodes/.test(await dock()), 'profiles dock: ' + await dock());
    await p.evaluate(() => setConnectMode('simple'));
    await p.click('#powerBtn');
    await p.waitForTimeout(300);
    expect(await p.evaluate(() => !connected && !connecting) && await p.isVisible('#view-nodes'), 'power with nothing: ' + await p.evaluate(() => connected + ' ' + connecting));
    expect(!p.errors.length, p.errors.join(' | '));
    await p.close();
  });

  await check('profiles: the last profile can be deleted — No profiles yet is a normal state', async () => {
    const p = await openPage(browser);
    await p.evaluate(() => { setConnectMode('profiles'); getProfileIds().forEach(id => deleteEntry(id)); });
    await p.waitForTimeout(300);
    const r = await p.evaluate(() => ({ left: getProfileIds().length, chains: Object.values(chainsData).filter(c => !connectEntry(c.inId) || !connectEntry(c.outId)).length, dock: document.getElementById('profCardName').textContent }));
    expect(r.left === 0 && r.chains === 0 && r.dock === 'No profiles yet', JSON.stringify(r));
    await p.evaluate(() => { openProfiles(); switchTab('nodes'); setNodesTab('profiles'); });
    await p.waitForTimeout(200);
    expect(!p.errors.length, p.errors.join(' | '));
    await p.close();
  });

  await check('home: power off → connecting → on', async () => {
    await tab(page, 'home');
    const state = () => page.evaluate(() => document.getElementById('powerBtn').className + ' / ' + document.getElementById('connLabel').textContent);
    await page.click('#powerBtn');
    expect(/Tap to connect/.test(await state()), 'off: ' + await state());
    await page.click('#powerBtn');
    expect(/busy/.test(await state()), 'busy: ' + await state());
    await page.waitForTimeout(1300);
    expect(/\bon\b.*Connected/.test(await state()), 'on: ' + await state());
  });

  await check('home: Exit IP card shows the mock IP while connected', async () => {
    expect(/DE/.test(await page.textContent('#exitLoc')), 'exitLoc: ' + await page.textContent('#exitLoc'));
    expect((await page.textContent('#exitIp')).trim() !== '—', 'exitIp: ' + await page.textContent('#exitIp'));
  });

  await check('home: disconnected, the card turns to Direct IP and shows the own IP; connected again, the exit', async () => {
    await page.evaluate(() => toggleMain());
    const at = async () => [await page.textContent('#exitLabel'), await page.textContent('#exitLoc')].join(' / ');
    expect(/^Direct IP \/ Checking…$/.test(await at()), 'right after disconnect: ' + await at());
    await page.waitForTimeout(700);
    expect(/^Direct IP \/ .*RU$/.test(await at()), 'direct IP: ' + await at());
    await page.evaluate(() => toggleMain());
    expect(/Checking…$/.test(await at()), 'while connecting: ' + await at());
    await page.waitForTimeout(1300);   // back to connected for the checks that follow
    expect(/^Exit IP \/ .*DE$/.test(await at()), 'exit after connect: ' + await at());
  });

  await check('home: tapping the card checks again — Checking… at once, the IP after ~600ms', async () => {
    await page.click('#exitIp');
    expect(await page.textContent('#exitLoc') === 'Checking…', 'not "Checking…" right after the tap');
    await page.waitForTimeout(700);
    expect(/DE/.test(await page.textContent('#exitLoc')), 'IP did not come back: ' + await page.textContent('#exitLoc'));
  });

  await check('home: dock opens profiles', async () => {
    await page.click('.dock-profile'); await settle(page);
    expect(await page.evaluate(() => document.getElementById('sh-profiles').classList.contains('open')), 'profiles sheet closed');
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('profiles: Auto picks first usable entry in priority order', async () => {
    await page.click('.dock-profile'); await settle(page);
    const first = await page.evaluate(() => connectOrder.find(id => connectEntry(id).inAuto && isUsable(id)));
    expect(await page.evaluate(() => autoConnect && effectiveConnectId()) === first, 'auto pick mismatch');
    expect(await page.$eval('.conn-row.current', el => el.dataset.id) === first, 'highlighted row is not the auto pick');
    expect(/AUTO/.test(await page.textContent('#profModeBadge')), 'dock badge not AUTO');
  });

  await check('route: ✎ shows the ⋮⋮ grips and the Fastest / Priority switch, reopening turns it off', async () => {
    const r = await page.evaluate(() => {
      const out = {}, id = visibleOrder().find(x => sourcesData[x]);
      const q = s => document.querySelectorAll('#connects-list ' + s).length;
      toggleRouteRow(id);
      out.offPlain = !q('.drag-handle') && !q('.seg-switch') && q('.conn-pick-hint') === 1 && /= ping its servers/.test(document.getElementById('connectsCaption').textContent);
      setRouteEdit(true);
      out.onGrips = q('> .conn-row > .drag-handle') === visibleOrder().length && q('.seg-switch') === 1 && document.getElementById('routeEditBtn').classList.contains('on');
      out.swH = document.querySelector('#connects-list .seg-switch').getBoundingClientRect().height;
      out.lower = out.swH > 20 && out.swH <= 30;
      toggleRouteRow(id); openProfiles();
      out.reset = !routeEdit && !q('.drag-handle');
      return out;
    });
    expect(['offPlain', 'onGrips', 'lower', 'reset'].every(k => r[k]), JSON.stringify(r));
  });

  await check('route: tapping a server pins the entry and that server (Manual); again unpins the server', async () => {
    const r = await page.evaluate(() => {
      const out = {}, id = visibleOrder().filter(x => sourcesData[x] && unitRefs(x).length > 1)[0];
      const refs = unitRefs(id), last = refs[refs.length - 1], key = refKey(last);
      toggleRouteRow(id);
      document.querySelector(`#connects-list .conn-body .node-row[data-id="${key}"]`).click();
      out.pinned = !autoConnect && activeConnectId === id && pinnedNode === key && unitNode(id) === last.node && effectiveConnectId() === id;
      out.marked = !!document.querySelector(`#connects-list .conn-body .node-row.pinned[data-id="${key}"]`);
      out.dock = /MANUAL/.test(document.getElementById('profModeBadge').textContent) && document.getElementById('profModeDetail').textContent.includes(last.node.name);
      document.querySelector(`#connects-list .conn-body .node-row[data-id="${key}"]`).click();
      out.unpinned = !autoConnect && activeConnectId === id && pinnedNode === null && !document.querySelector('#connects-list .node-row.pinned');
      pinRouteNode(id, key); setAutoConnect(true);
      out.autoClears = autoConnect && pinnedNode === null;
      toggleRouteRow(id);
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('route: dragging a server grip reorders it without pinning it', async () => {
    const id = await page.evaluate(() => {
      const id = visibleOrder().filter(x => sourcesData[x] && unitRefs(x).length > 2)[0];
      unitOwner(id).pickMode = 'priority'; setRouteEdit(true); toggleRouteRow(id);
      return id;
    });
    await settle(page);
    const rows = page.locator(`#connects-list .conn-row[data-id=${id}] .conn-body .node-row`);
    const g = await rows.nth(0).locator('.drag-handle').boundingBox(), t = await rows.nth(2).boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, t.y + t.height - 4, { steps: 8 }); await page.mouse.up(); await settle(page);
    const r = await page.evaluate(id => {
      const out = { notPinned: pinnedNode === null && autoConnect, moved: (unitOwner(id).pickOrder || []).length > 0 };
      unitOwner(id).pickMode = 'fastest'; toggleRouteRow(id); setRouteEdit(false);
      return out;
    }, id);
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('route on Home: ends at the dock, tucked under the power tab; dock and nav stay on top', async () => {
    await page.evaluate(() => closeSheet('profiles')); await settle(page);
    await page.click('.dock-profile'); await settle(page);
    const r = await page.evaluate(() => {
      const sh = document.getElementById('sh-profiles').getBoundingClientRect(), dock = document.querySelector('.dock').getBoundingClientRect();
      const tab = document.getElementById('powerBtn').getBoundingClientRect(), nav = document.querySelector('.bottomnav').getBoundingClientRect();
      const bar = document.querySelector('#sh-profiles .route-bar').getBoundingClientRect(), body = document.querySelector('#sh-profiles .sheet-body').getBoundingClientRect();
      const hit = (x, y, sel) => !!document.elementFromPoint(x, y).closest(sel);
      return { open: document.getElementById('sh-profiles').classList.contains('open'), bottom: Math.abs(sh.bottom - dock.top) <= 1,
        tabOnTop: hit(tab.left + tab.width / 2, tab.top + tab.height / 2, '#powerBtn'), sheetUnderTab: sh.bottom > tab.top + 20,
        dockOnTop: hit(dock.left + 40, dock.bottom - 20, '.dock-profile'), navOnTop: hit(nav.left + nav.width / 2, nav.top + nav.height / 2, '.bottomnav'),
        gap: body.top - (bar.bottom - 8) >= 7 };
    });
    await page.click('.dock-profile'); await settle(page);
    r.dockCloses = await page.evaluate(() => !document.getElementById('sh-profiles').classList.contains('open') && !document.querySelector('.phone.route-docked'));
    await page.click('.dock-profile'); await settle(page);
    await page.evaluate(() => switchTab('nodes')); await settle(page);
    r.tabCloses = await page.evaluate(() => !document.getElementById('sh-profiles').classList.contains('open'));
    await page.evaluate(() => switchTab('home')); await settle(page);
    await page.click('.dock-profile'); await settle(page);   // leave it open, as the checks below expect
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('profiles: dragging changes the Auto pick', async () => {
    await page.evaluate(() => setRouteEdit(true));
    const target = await page.evaluate(() => connectOrder.filter(id => connectEntry(id).inAuto && isUsable(id))[1]);
    const g = await page.locator(`.conn-row[data-id=${target}] .drag-handle`).boundingBox();
    const top = await page.locator('.conn-row').first().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, top.y - 10, { steps: 8 }); await page.mouse.up(); await settle(page);
    expect(await page.evaluate(() => effectiveConnectId()) === target, 'auto pick did not follow the new order');
  });

  await check('route: own order after a drag, Nodes order stays, "Follow Nodes order" resets', async () => {
    const r = await page.evaluate(() => {
      const out = {}, m = connectMode;
      out.custom = routeCustom[m] && /Own priority order/.test(document.getElementById('routeOrderNote').textContent);
      out.nodesKept = connectOrder.join() !== catalogOrder[m].join();
      document.querySelector('#routeOrderNote .am-link').click();
      out.reset = !routeCustom[m] && connectOrder.join() === catalogOrder[m].join();
      const id = connectOrder.find(x => !isBroken(x)), was = connectEntry(id).inAuto;
      const ed = routeEdit; setRouteEdit(false);
      const row = () => document.querySelector(`#connects-list .conn-row[data-id=${id}]`);
      out.pingNotToggle = !row().querySelector('.mini-toggle') && !!row().querySelector('.route-ping .seg-ping')
        && !!row().querySelector('.conn-name > .conn-state:first-child');
      setRouteEdit(true);
      out.editBoth = !!row().querySelector('.conn-name .route-auto .mini-toggle') && !!row().querySelector('.route-ping .seg-ping');
      const open = routeOpen.has(id);
      row().querySelector('.conn-name .mini-toggle').click();
      out.noUnfold = routeOpen.has(id) === open;
      out.autoToggle = connectEntry(id).inAuto === !was;
      toggleEntryAuto(id); setRouteEdit(ed);
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('route: a source row unfolds to its servers, Fastest / Priority, order by grips', async () => {
    const r = await page.evaluate(() => {
      const out = {}, id = visibleOrder().find(x => sourcesData[x]), s = sourcesData[id], was = s.pickMode;
      out.noChainExpand = [...document.querySelectorAll('#connects-list .conn-row')].every(el => !chainsData[el.dataset.id] || !el.querySelector('.conn-main').hasAttribute('onclick'));
      const states = [...document.querySelectorAll('#connects-list .conn-state')].map(el => Math.round(el.getBoundingClientRect().width));
      out.sameWidth = states.length > 1 && new Set(states).size === 1 && !document.querySelector('#connects-list .conn-expand');
      const n0 = unitRefs(id)[0].node, name0 = n0.name;
      n0.name = 'A very long server name that would push the row wider than the screen';
      document.querySelector(`#connects-list .conn-row[data-id=${id}] .conn-main`).click();
      const body = () => document.querySelector(`#connects-list .conn-row[data-id=${id}] .conn-body`);
      out.open = !!body() && body().querySelectorAll('.node-row').length === unitRefs(id).length;
      const row = document.querySelector(`#connects-list .conn-row[data-id=${id}]`);
      out.fits = row.scrollWidth <= row.clientWidth;
      n0.name = name0;
      setRouteRowMode('priority');
      out.priority = s.pickMode === 'priority' && body().querySelectorAll('.cc-grip').length === unitRefs(id).length;
      out.order = [...body().querySelectorAll('.node-row')].map(el => el.dataset.id).join() === unitPickRefs(id).map(refKey).join();
      setRouteRowMode('fastest');
      out.fastest = s.pickMode === 'fastest' && !body().querySelector('.cc-grip');
      s.pickMode = was;
      toggleRouteRow(id);
      out.closed = !body();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('simple mode is the default: sources and source chains in the list', async () => {
    expect(await page.evaluate(() => connectMode === 'simple'), 'not simple by default');
    const ids = await page.$$eval('.conn-row', r => r.map(el => el.dataset.id));
    expect(ids.includes('src1') && ids.includes('sc1') && !ids.includes('default') && !ids.includes('cpdefault'), ids.join());
    expect(/Simple/.test(await page.textContent('#routeModes .on')), 'mode switch');
  });

  await check('simple mode: conn-state sets Manual, second tap back to Auto', async () => {
    await page.click('.conn-row[data-id=src2] .conn-state'); await settle(page);
    expect(await page.evaluate(() => !autoConnect && effectiveConnectId() === 'src2'), 'source not pinned');
    await page.click('.conn-row[data-id=src2] .conn-state'); await settle(page);
    expect(await page.evaluate(() => autoConnect), 'second tap did not re-enable auto');
  });

  await check('simple mode: ⋯ opens the source entry — servers on/off, all/none, Auto', async () => {
    await page.evaluate(() => openSourceActions('src2')); await settle(page);
    await page.click('#actions-body .menu-row >> text=Route settings'); await settle(page);
    const total = await page.evaluate(() => liveNodes(sourcesData.src2).length);
    await page.click('#se-nodes .node-row >> nth=0');
    expect(await page.evaluate(n => unitRefs('src2').length === n - 1, total), 'node not switched off');
    expect(await page.$eval('.conn-row[data-id=src2]', el => /1 off/.test(el.textContent)), 'row has no "1 off" tag');
    await page.click('#se-all');
    expect(await page.evaluate(() => unitRefs('src2').length === liveNodes(sourcesData.src2).length), '"All" did not switch all on');
    await page.click('#se-all');
    expect(await page.evaluate(() => unitRefs('src2').length === 0 && !isUsable('src2')), '"None" left nodes on');
    await page.click('#se-all');
    await page.click('#se-inauto');
    expect(await page.evaluate(() => !sourcesData.src2.inAuto), 'inAuto not toggled');
    await page.click('#se-inauto');
    await page.evaluate(() => closeSheet('sourceentry')); await settle(page);
  });

  await check('simple mode: a one-server entry has no expander in the chain editor', async () => {
    await page.evaluate(() => { sourcesData.src3.offNodes = sourcesData.src3.nodes.slice(1).map(n => n.id); openEditChain('sc1'); }); await settle(page);
    const r = await page.evaluate(() => [unitRefs('src3').length, !!document.querySelector('#cc-in-list .cc-prof[data-id=src3] button.cc-expand'), !!document.querySelector('#cc-in-list .cc-prof[data-id=src2] button.cc-expand')]);
    await page.evaluate(() => { sourcesData.src3.offNodes = []; closeSheet('createchain'); }); await settle(page);
    expect(r[0] === 1 && !r[1] && r[2], 'expanders: ' + r);
  });

  await check('simple mode: chain of two sources, route check works', async () => {
    await page.evaluate(() => { closeSheet('profiles'); switchTab('nodes'); setNodesTab('simple'); openNodesAdd(); }); await settle(page);
    await page.click('#addChainRow'); await settle(page);
    expect(await page.evaluate(() => document.getElementById('sh-createchain').classList.contains('open') && !!sourcesData[chainDraft.inId] && !!sourcesData[chainDraft.outId]), 'chain ends are not sources');
    await page.evaluate(() => testChainRoute());
    await page.waitForFunction(() => !chainTest.running, null, { timeout: 30000 });
    expect(await page.evaluate(() => chainTest.pairs.length > 0), 'no pairs');
    await page.click('#ccSaveBtn'); await settle(page);
    const n = await page.evaluate(() => connectOrder.filter(id => chainsData[id]).length);
    expect(n === 2, 'chain not added: ' + n);
    await page.evaluate(() => { switchTab('home'); openProfiles(); }); await settle(page);
  });

  await check('deleting a source drops it and its chains from the list', async () => {
    await page.evaluate(() => deleteSource('src4')); await settle(page);
    expect(await page.evaluate(() => !connectOrder.includes('src4') && !chainsData.sc1 && !modeState.profiles.order.includes('src4')), 'leftovers');
  });

  await check('mode switch under the header goes to profiles mode, each mode keeps its own list', async () => {
    await page.click('#routeModes button[data-mode=profiles]'); await settle(page);
    const ids = await page.$$eval('.conn-row', r => r.map(el => el.dataset.id));
    expect(ids.includes('default') && ids.includes('cpdefault') && !ids.includes('src1'), ids.join());
    expect(/Profiles/.test(await page.textContent('#routeModes .on')) && /profile|chain/.test(await page.textContent('#profCardLabel')), 'titles');
  });

  await check('profiles: conn-state sets Manual (sheet stays), second tap / badge back to Auto', async () => {
    expect(await page.evaluate(() => autoConnect), 'auto is not the default');
    await page.click('.conn-row[data-id=work] .conn-state'); await settle(page);
    expect(await page.evaluate(() => !autoConnect && effectiveConnectId() === 'work'), 'not pinned');
    expect(/MANUAL/.test(await page.textContent('#profModeBadge')), 'dock badge not MANUAL');
    expect(/Manual/.test(await page.textContent('#autoBadge')), 'sheet badge not Manual');
    expect(await page.evaluate(() => document.getElementById('sh-profiles').classList.contains('open')), 'sheet closed on pin');
    await page.click('.conn-row[data-id=work] .conn-state'); await settle(page);
    expect(await page.evaluate(() => autoConnect), 'second tap did not re-enable auto');
    await page.click('.conn-row[data-id=work] .conn-state'); await settle(page);
    await page.click('#autoBadge');
    expect(await page.evaluate(() => autoConnect), 'auto not re-enabled');
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('profiles: tapping the card only unfolds the row, it never pins', async () => {
    await page.evaluate(() => openProfiles()); await settle(page);
    const before = await page.evaluate(() => JSON.stringify([autoConnect, activeConnectId]));
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    const after = await page.evaluate(() => JSON.stringify([autoConnect, activeConnectId]));
    expect(before === after, `pin changed on card tap: ${before} -> ${after}`);
    expect(await page.evaluate(() => routeOpen.has('work')), 'card tap did not unfold the row');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page); // fold back
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('route: the unfolded row updates its subscription(s) and ⚡ pings only its own servers', async () => {
    // src2, not src1: src1 is the demo-churn source (see demoProviderChurn) — updating it
    // a second time here would race the node-count assumptions of later checks.
    await page.evaluate(() => { setConnectMode('simple'); openProfiles(); toggleRouteRow('src2'); }); await settle(page);
    await page.click('.conn-row[data-id=src2] .conn-acts .icon-btn[title=Update]');
    expect(await page.evaluate(() => sourcesData.src2.updating), 'Update did not mark the subscription updating');
    await page.evaluate(() => { toggleRouteRow('src2'); toggleRouteRow('src3'); }); await settle(page);
    expect(await page.evaluate(() => !document.querySelector('.conn-row[data-id=src3] .conn-acts .icon-btn[title=Update]')), 'manual-only row shows an Update button');
    await page.click('.conn-row[data-id=src3] .seg-ping');
    const [pinged, leaked] = await page.evaluate(() => [
      unitRefs('src3').every(r => ping(r.node) === 'testing'),
      sourceOrder.filter(s => s !== 'src3').some(s => sourcesData[s].nodes.some(n => ping(n) === 'testing')),
    ]);
    expect(pinged, 'not every server of the row was pinged');
    expect(!leaked, 'ping leaked to servers outside the unfolded row');
    await page.evaluate(() => { toggleRouteRow('src3'); closeSheet('profiles'); setConnectMode('profiles'); });
  });

  await check('profiles: editor picks single nodes and Auto participation', async () => {
    await page.evaluate(() => { openProfiles(); openEditProfile('work'); }); await settle(page);
    await page.click('.ps-card[data-id=src2] .ps-check');           // whole src2 -> off
    await page.click('.ps-card[data-id=src1] .ps-main');
    await page.click('.ps-card[data-id=src1] .node-row >> nth=2');  // one single server
    expect(await page.$eval('.ps-card[data-id=src1] .ps-check .sub-checkbox', el => el.classList.contains('partial')), 'source not partial');
    await page.click('#cp-inauto');
    await page.click('#cpSaveBtn');
    const p = await page.evaluate(() => profilesData.work);
    expect(p.sources.length === 0 && p.nodes.length === 1 && p.nodes[0].startsWith('src1::') && !p.inAuto, JSON.stringify(p));
    expect(await page.evaluate(() => profileNodeCount(profilesData.work)) === 1, 'node count is not 1');
    expect(await page.$eval('.conn-row[data-id=work]', el => /not in auto/i.test(el.textContent) && !/fixed/i.test(el.textContent)), 'row state wrong');
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('profile editor: expand, ping, untick a node of a whole source, re-tick it', async () => {
    await page.evaluate(() => { openProfiles(); openEditProfile('default'); }); await settle(page);
    await page.click('.ps-card[data-id=src1] .ps-main');
    expect(await page.$$eval('.ps-card[data-id=src1] .node-row', r => r.length) > 0, 'nodes not shown');
    await page.click('.ps-card[data-id=src1] button[title="Ping all"]');
    expect(await page.$$eval('.ps-card[data-id=src1] .lat.testing', r => r.length) > 0, 'ping did not start');
    await page.waitForFunction(() => !document.querySelector('.ps-card[data-id=src1] .lat.testing'));
    await page.click('.ps-card[data-id=src1] .node-row >> nth=1');
    expect(await page.evaluate(() => cpSourceState('src1') === 'some' && cpNodes.size === sourcesData.src1.nodes.length - 1), 'untick did not make the source partial');
    await page.click('.ps-card[data-id=src1] .node-row >> nth=1');
    expect(await page.evaluate(() => cpSourceState('src1') === 'all' && cpNodes.size === 0), 're-tick did not restore the whole source');
    await page.evaluate(() => { closeSheet('createprofile'); closeSheet('profiles'); });
  });

  await check('chain editor: same entry/exit blocked, route check lists working pairs', async () => {
    await page.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditChain('cpdefault'); }); await settle(page);
    const idx = await page.evaluate(() => getProfileIds().indexOf(chainDraft.inId));
    await page.click(`#cc-out-list .pick-row >> nth=${idx}`, { force: true });
    expect(await page.evaluate(() => chainDraft.inId !== chainDraft.outId), 'exit could be set to the entry');
    await page.click('#cc-test .btn-secondary');
    await page.waitForFunction(() => chainTest && !chainTest.running, null, { timeout: 30000 });
    const r = await page.evaluate(() => ({ n: chainTest.pairs.length, sorted: chainTest.pairs.every((p, i, a) => !i || a[i-1].ms <= p.ms), rows: document.querySelectorAll('#cc-test .route-pair').length }));
    expect(r.sorted, 'pairs not sorted by latency');
    expect(r.rows === Math.min(4, r.n), `shows ${r.rows} rows for ${r.n} pairs`);
    if (r.n) {
      await page.click('#cc-test .route-views .chip >> nth=1');
      await page.click('#cc-test .route-group >> nth=0');
      const g = await page.evaluate(() => ({ groups: document.querySelectorAll('#cc-test .route-group').length, sub: document.querySelectorAll('#cc-test .route-sub .route-pair').length }));
      expect(g.groups > 0 && g.sub > 0, 'by-entry view: ' + JSON.stringify(g));
    }
    await page.evaluate(() => { closeSheet('createchain'); closeSheet('profiles'); });
  });

  await check('chain editor: untick servers on both ends', async () => {
    await page.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditChain('cpdefault'); pickChainSide('in', 'default'); pickChainSide('out', 'default'); }); await settle(page);
    const outId = await page.evaluate(() => chainDraft.outId);
    await page.click(`#cc-out-list .cc-prof[data-id=${outId}] button.cc-expand`);
    await page.click('#cc-out-list .cc-nodes .node-row >> nth=0');
    expect(await page.evaluate(() => chainDraft.outOff.length === 1), 'exit untick: ' + await page.evaluate(() => JSON.stringify(chainDraft.outOff)));
    await page.click('#cc-out-list .cc-nodes .node-row >> nth=0');
    expect(await page.evaluate(() => chainDraft.outOff.length === 0), 'second tap did not re-tick');
    await page.click('#cc-in-list .cc-prof[data-id=default] button.cc-expand');
    await page.click('#cc-in-list .cc-nodes .node-row >> nth=1');
    expect(await page.evaluate(() => chainDraft.inOff.length === 1), 'entry untick');
    await page.evaluate(() => { closeSheet('createchain'); closeSheet('profiles'); });
  });

  await check('chain editor: opens collapsed, All/None toggles every node', async () => {
    await page.evaluate(() => { setConnectMode('simple'); openProfiles(); openCreateChain(); pickChainSide('in', 'src2'); pickChainSide('out', 'src1'); setChainExitMode('priority'); saveCreateChain(); }); await settle(page);
    const id = await page.evaluate(() => Object.keys(chainsData).pop());
    await page.evaluate(id => openEditChain(id), id); await settle(page);
    expect(await page.$$eval('#cc-out-list .cc-nodes, #cc-in-list .cc-nodes', e => e.length) === 0, 'nodes expanded on open');
    await page.click('#cc-in-list .cc-prof[data-id=src2] button.cc-expand');
    await page.click('#cc-in-list .cc-bar .chip');
    const n = await page.evaluate(() => [chainDraft.inOff.length, unitRefs(chainDraft.inId).length]);
    expect(n[0] === n[1] && n[0] > 1, 'None: ' + n);
    await page.click('#cc-in-list .cc-bar .chip');
    expect(await page.evaluate(() => chainDraft.inOff.length === 0), 'All did not re-tick');
    await page.evaluate(id => { closeSheet('createchain'); closeSheet('profiles'); dropConnectEntry(id); delete chainsData[id]; renderConnects(); }, id);
  });

  await check('chain editor: priority exit uses the top working server, drag reorders', async () => {
    await page.evaluate(() => { setConnectMode('simple'); openProfiles(); openCreateChain(); pickChainSide('in', 'src2'); pickChainSide('out', 'src1'); setChainExitMode('fastest'); }); await settle(page);
    await page.click('#cc-out-hint .seg-switch button >> nth=1'); await settle(page);
    const r = await page.evaluate(() => { const refs = chainExitRefs(chainDraft), n = chainExitNode(chainDraft);
      return { mode: chainDraft.exitMode, ok: n === (refs.map(x => x.node).find(isAlive) || null), grips: document.querySelectorAll('#cc-out-list .cc-grip').length }; });
    expect(r.mode === 'priority' && r.ok && r.grips > 1, JSON.stringify(r));
    const before = await page.evaluate(() => chainExitOrder(chainDraft).map(refKey).join());
    const g = await page.locator('#cc-out-list .cc-grip').first().boundingBox();
    const rows = page.locator('#cc-out-list .cc-nodes .node-row');
    const last = await rows.last().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, last.y + last.height + 20, { steps: 10 });
    await page.mouse.up(); await settle(page);
    const after = await page.evaluate(() => chainExitOrder(chainDraft).map(refKey));
    const first = before.split(',')[0];
    await page.evaluate(() => { closeSheet('createchain'); closeSheet('profiles'); });
    expect(after[after.length - 1] === first, 'order after drag: ' + after.join());
  });

  await check('provider drops servers: settings kept, back with them, Forget purges', async () => {
    const r = await page.evaluate(() => {
      setConnectMode('simple');
      const s = sourcesData.src1, out = {};
      if (s.gone.length) demoProviderChurn(s);
      s.offNodes = ['n1'];
      chainsData.tc = { id:'tc', name:'t', inId:'src2', outId:'src1', inAuto:true, inOff:[], outOff:['src1::n3'], exitMode:'priority', exitOrder:['src1::n3','src1::n0'] };
      demoProviderChurn(s);
      out.dropped = s.gone.map(n => n.id).join() === 'n1,n3' && !unitRefs('src1').some(r => ['n1','n3'].includes(r.node.id));
      out.orderSkips = refKey(chainExitOrder(chainsData.tc)[0]) === 'src1::n0';
      s.offNodes.push('n0');
      openSourceEntry('src1'); setSourceEntryAll();   // one live server off -> "All" ticks the live ones only
      out.allKeepsGone = isNodeOff(s, 'n1') && offCount(s) === 0;
      return out;
    });
    await page.click('#se-nodes .gone-head'); await settle(page);
    const rows = await page.$$eval('#se-nodes .node-row.gone', r => r.length);
    const r2 = await page.evaluate(() => {
      closeSheet('sourceentry');
      const s = sourcesData.src1, out = {};
      demoProviderChurn(s);
      out.back = isNodeOff(s, 'n1') && refKey(chainExitOrder(chainsData.tc)[0]) === 'src1::n3' && !chainExitRefs(chainsData.tc).some(r => r.node.id === 'n3');
      demoProviderChurn(s); forgetGone('src1');
      out.forgot = !s.gone.length && !s.offNodes.includes('n1') && !chainsData.tc.exitOrder.includes('src1::n3') && !chainsData.tc.outOff.length;
      delete chainsData.tc;
      return out;
    });
    expect(Object.values(r).every(Boolean) && rows === 2 && Object.values(r2).every(Boolean), JSON.stringify({ r, rows, r2 }));
  });

  await check('nothing ticked: warning, save blocked, source entry reverts on close', async () => {
    const r = await page.evaluate(() => {
      setConnectMode('simple'); const out = {};
      const s = sourcesData.src2; s.offNodes = [];
      openSourceEntry('src2'); setSourceEntryAll();
      out.seWarn = !document.getElementById('se-warn').hidden && document.getElementById('se-done').disabled;
      closeSheet('sourceentry');
      out.seReverted = offCount(s) === 0;
      openCreateChain(); pickChainSide('in', 'src2'); pickChainSide('out', 'src3'); setChainNodesAll('in');
      out.ccWarn = !document.getElementById('cc-warn').hidden && document.getElementById('ccSaveBtn').disabled && /entry/.test(document.getElementById('cc-warn').textContent);
      const n = Object.keys(chainsData).length; saveCreateChain();
      out.ccBlocked = Object.keys(chainsData).length === n;
      closeSheet('createchain');
      setConnectMode('profiles'); openCreateProfile();
      out.cpWarn = !document.getElementById('cp-warn').hidden && document.getElementById('cpSaveBtn').disabled;
      toggleCreateProfileSource('src2');
      out.cpOk = document.getElementById('cp-warn').hidden;
      closeSheet('createprofile'); setConnectMode('simple');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('source off in Nodes: own entry hidden, users marked off below, settings back when on', async () => {
    const r = await page.evaluate(() => {
      setConnectMode('simple'); const out = {};
      const s2 = sourcesData.src2; s2.offNodes = ['n2'];
      chainsData.tc2 = { id:'tc2', name:'t2', inId:'src2', outId:'src3', inAuto:true, inOff:['src2::n4'], outOff:[], exitMode:'fastest', exitOrder:[] };
      catalogOrder.simple.unshift('tc2');
      s2.enabled = false; openProfiles();
      const top = [...document.querySelectorAll('#connects-list > .conn-row')].map(e => e.dataset.id);
      const broken = [...document.querySelectorAll('#connects-list .conn-broken-list .conn-row.broken')].map(e => e.dataset.id);
      out.list = !top.includes('src2') && !top.includes('tc2') && broken[0] === 'tc2' && connectOrder[0] === 'tc2';
      out.auto = effectiveConnectId() !== 'tc2';
      document.querySelector('.conn-row.broken').click();
      out.explain = /Work Servers/.test(document.getElementById('actions-body').textContent) && /Switch on/.test(document.getElementById('actions-body').textContent);
      closeSheet('actions');
      openCreateChain(); out.picker = !document.querySelector('#cc-in-list .cc-prof[data-id=src2]'); closeSheet('createchain');
      openEditChain('tc2'); out.chainWarn = !document.getElementById('cc-warn').hidden && /off in Nodes/.test(document.getElementById('cc-warn').textContent); closeSheet('createchain');
      setConnectMode('profiles');
      profilesData.tp = { id:'tp', name:'tp', sources:['src2'], nodes:[], inAuto:true }; catalogOrder.profiles.push('tp');
      renderConnects();
      out.profile = !!document.querySelector('.conn-broken-list .conn-row[data-id=tp]') && !document.querySelector('#connects-list > .conn-row[data-id=tp]');
      openEditProfile('tp'); out.cpOff = !!document.querySelector('#cp-source-list .ps-card.off[data-id=src2]') && /off in Nodes/.test(document.getElementById('cp-warn').textContent); closeSheet('createprofile');
      delete profilesData.tp; connectOrder = connectOrder.filter(x => x !== 'tp');
      setConnectMode('simple');
      enableSource('src2');
      out.back = isNodeOff(s2, 'n2') && chainsData.tc2.inOff[0] === 'src2::n4' && !!document.querySelector('#connects-list > .conn-row[data-id=tc2]');
      delete chainsData.tc2; connectOrder = connectOrder.filter(x => x !== 'tc2'); s2.offNodes = [];
      closeSheet('profiles'); renderAll();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('dock shows the route: source + node, profile + source + node, chain entry → exit', async () => {
    const r = await page.evaluate(() => {
      const out = {}, was = autoConnect, det = () => document.getElementById('profModeDetail');
      setConnectMode('simple'); autoConnect = false; activeConnectId = 'src1'; updateMainConnectCard();
      out.src = document.getElementById('profCardLabel').textContent === 'sub' && !!det().querySelector('.dock-node') && !det().querySelector('.dock-src')
        && det().firstElementChild.classList.contains('dock-proto') && /\S/.test(det().firstElementChild.textContent);   // protocol first
      chainsData.tc3 = { id:'tc3', name:'t3', inId:'src2', outId:'src1', inAuto:true, inOff:[], outOff:[], exitMode:'fastest', exitOrder:[] };
      catalogOrder.simple.push('tc3'); syncCatalog(); activeConnectId = 'tc3'; updateMainConnectCard();
      out.chain = document.getElementById('profCardLabel').textContent === 'chain' && det().querySelectorAll('.dock-node').length === 2 && !!det().querySelector('.dock-arrow');
      delete chainsData.tc3; connectOrder = connectOrder.filter(x => x !== 'tc3'); activeConnectId = 'src1'; autoConnect = was;
      setConnectMode('profiles'); const pw = autoConnect; autoConnect = false; activeConnectId = 'default'; updateMainConnectCard();
      out.profile = document.getElementById('profCardLabel').textContent === 'profile' && !!det().querySelector('.dock-src');
      autoConnect = pw; setConnectMode('simple'); updateMainConnectCard();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('server off in Nodes: hidden everywhere, users with nothing left marked off, settings back when on', async () => {
    const r = await page.evaluate(() => {
      setConnectMode('simple'); const out = {}, s2 = sourcesData.src2;
      s2.offNodes = []; s2.disabledNodes = ['n8'];
      out.hidden = !unitRefs('src2').some(r => r.node.id === 'n8');
      openSourceEntry('src2'); out.se = document.querySelectorAll('#se-nodes > .node-row').length === s2.nodes.length - 1; closeSheet('sourceentry');
      // a chain whose entry uses only n0 of src2
      chainsData.tc4 = { id:'tc4', name:'t4', inId:'src2', outId:'src3', inAuto:true, inOff: s2.nodes.filter(n => n.id !== 'n0').map(n => 'src2::' + n.id), outOff:[], exitMode:'fastest', exitOrder:[] };
      catalogOrder.simple.unshift('tc4');
      return out;
    });
    await tab(page, 'nodes');
    await page.evaluate(() => { expandState.src2 = true; setNodesEdit(true); });
    await page.click('.src-card[data-id=src2] .node-row[data-nid=n0] .node-name');   // edit mode: tap = on / off
    await page.evaluate(() => setNodesEdit(false));
    const r2 = await page.evaluate(() => {
      const out = {}, s2 = sourcesData.src2;
      out.toggled = isNodeDisabled(s2, 'n0') && !!document.querySelector('.src-card[data-id=src2] .node-row.disabled[data-nid=n0]');
      openProfiles();
      out.broken = !!document.querySelector('.conn-broken-list .conn-row[data-id=tc4]') && brokenBy('tc4')[0].nid === 'n0';
      document.querySelector('.conn-row.broken[data-id=tc4]').click();
      out.explain = /Switch on/.test(document.getElementById('actions-body').textContent);
      document.querySelector('#actions-body .menu-row').click();   // Switch on 🇩🇪 …
      out.back = !isNodeDisabled(s2, 'n0') && chainsData.tc4.inOff.length === s2.nodes.length - 1 && !!document.querySelector('#connects-list > .conn-row[data-id=tc4]');
      // simple entry: only n1 ticked, then n1 switched off → the entry itself is broken
      s2.offNodes = s2.nodes.filter(n => n.id !== 'n1').map(n => n.id);
      toggleNodeEnabled('src2', 'n1');
      out.entry = !!document.querySelector('.conn-broken-list .conn-row[data-id=src2]') && effectiveConnectId() !== 'src2';
      toggleNodeEnabled('src2', 'n1'); s2.offNodes = [];
      // profiles: a profile of one picked server that is switched off
      setConnectMode('profiles');
      profilesData.tp3 = { id:'tp3', name:'tp3', sources:[], nodes:['src2::n8'], inAuto:true }; catalogOrder.profiles.push('tp3'); renderConnects();
      out.profile = !!document.querySelector('.conn-broken-list .conn-row[data-id=tp3]');
      openEditProfile('tp3'); out.cpWarn = /off in Nodes/.test(document.getElementById('cp-warn').textContent) && document.getElementById('cpSaveBtn').disabled; closeSheet('createprofile');
      delete profilesData.tp3; connectOrder = connectOrder.filter(x => x !== 'tp3');
      setConnectMode('simple');
      delete chainsData.tc4; connectOrder = connectOrder.filter(x => x !== 'tc4');
      closeSheet('actions'); closeSheet('profiles'); renderAll();
      return out;
    });
    await tab(page, 'home');
    expect(Object.values(r).concat(Object.values(r2)).every(Boolean), JSON.stringify([r, r2]));
  });

  await check('delete asks first and lists what it breaks; cancel keeps everything', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      sourcesData.tmp = { id:'tmp', kind:'node', name:'Tmp', enabled:true, inAuto:true, offNodes:[], disabledNodes:[], nodes: genNodes(3, 'node') };
      sourceOrder.push('tmp'); sourceAdded('tmp');
      chainsData.tc5 = { id:'tc5', name:'Tmp chain', inId:'src2', outId:'tmp', inAuto:true, inOff:[], outOff:[], exitMode:'fastest', exitOrder:[] };
      catalogOrder.simple.push('tc5');
      catalogOrder.profiles.push('tp4');
      const keep = rulesData.r2.target; rulesData.r2.target = 'chain:tc5';
      profilesData.tp4 = { id:'tp4', name:'Only tmp', sources:[], nodes:['tmp::n0'], inAuto:true };
      openSourceActions('tmp');
      [...document.querySelectorAll('#actions-body .menu-row')].find(e => /Delete/.test(e.textContent)).click();
      const body = () => document.getElementById('actions-body').textContent;
      out.asks = !!sourcesData.tmp && /Delete Tmp\?/.test(document.getElementById('actionsTitle').textContent);
      out.impact = /Tmp chain.*deleted with it/.test(body()) && /Only tmp.*no servers/.test(body()) && /Discord voice.*rule #2.*loses its target/.test(body());
      [...document.querySelectorAll('#actions-body .menu-row')].find(e => /Cancel/.test(e.textContent)).click();
      out.cancel = !!sourcesData.tmp && !!chainsData.tc5;
      confirmDeleteNode('tmp', 'n0');
      out.node = /Only tmp.*no servers/.test(body()) && /Tmp chain.*exit loses 1 server/.test(body());
      document.querySelector('#actions-body .menu-row.danger').click();
      out.nodeGone = sourcesData.tmp.nodes.length === 2 && !profilesData.tp4.nodes.length;
      confirmDeleteSource('tmp');
      document.querySelector('#actions-body .menu-row.danger').click();
      out.gone = !sourcesData.tmp && !chainsData.tc5 && !connectOrder.includes('tc5');
      out.ruleKept = rulesData.r2.target === 'chain:tc5' && /deleted chain/.test(targetName(rulesData.r2.target)) && !targetInfo(rulesData.r2.target).ok;
      rulesData.r2.target = keep;
      delete profilesData.tp4; modeState.profiles.order = modeState.profiles.order.filter(x => x !== 'tp4');
      renderAll();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('unavailable servers are kept 15 days each, then forgotten with their settings', async () => {
    const r = await page.evaluate(() => {
      const out = {}, s = sourcesData.src1, day = 864e5;
      const [a, b] = genNodes(40, 'sub').slice(30, 32).map((n, i) => Object.assign(n, { id: 'x' + i, goneAt: Date.now() - (i ? 16 : 13) * day }));
      s.gone = (s.gone || []).concat(a, b);
      profilesData.default.nodes.push('src1::x0', 'src1::x1');
      purgeExpiredGone();
      out.purged = !s.gone.some(n => n.id === 'x1') && !profilesData.default.nodes.includes('src1::x1');
      out.kept = s.gone.some(n => n.id === 'x0') && profilesData.default.nodes.includes('src1::x0');
      expandState.src1 = true; goneOpen.add('nodes:src1'); renderNodes();
      out.left = /2 d left/.test(document.querySelector('.src-card[data-id=src1] .gone-block').textContent);
      openGoneActions('src1', 'x0'); document.querySelector('#actions-body .menu-row.danger').click();
      out.forgot = !s.gone.some(n => n.id === 'x0') && !profilesData.default.nodes.includes('src1::x0');
      goneOpen.delete('nodes:src1'); renderNodes();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('edit modes: Nodes shows grips / switches only while editing', async () => {
    const r = await page.evaluate(() => {
      const out = {}; switchTab('nodes'); expandState.src2 = true; renderNodes();
      const q = s => document.querySelector(s);
      out.viewClean = !q('#nodes-list .drag-handle') && !q('#nodes-list .mini-toggle') && !q('#nodes-list .node-row.pick');
      q('.src-card[data-id=src2] .node-row[data-nid=n0]').click();
      out.tapMenu = q('#sh-actions').classList.contains('open') && !isNodeDisabled(sourcesData.src2, 'n0'); closeSheet('actions');
      setNodesEdit(true);
      out.edit = !!q('#nodes-list .drag-handle') && !!q('#nodes-list .mini-toggle') && !!q('#nodes-list .node-row.pick') && q('#nodesEditBtn').classList.contains('on') && [...document.querySelectorAll('#view-nodes .head-actions .icon-btn')].every(b => b.offsetWidth > 0);
      const cid = catalogOrder.simple.find(x => chainsData[x]), ch = chainsData[cid];
      const card = () => q(`#nodes-list .entry-card[data-id=${cid}]`);
      out.chainGrip = !!card().querySelector('.drag-handle') && card().querySelectorAll('.node-row.pick').length > 0;
      const offs = () => (ch.inOff || []).concat(ch.outOff || []);
      const row = card().querySelector('.node-row.pick.on'), key = row.dataset.key, before = offs().length;
      row.click();
      out.chainOff = offs().includes(key) && card().querySelector(`.node-row[data-key="${key}"]`).classList.contains('disabled');
      card().querySelector(`.node-row[data-key="${key}"]`).click();
      out.chainBack = offs().length === before;
      setNodesEdit(false); switchTab('home');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('Priority on entries: first working server by order; drag reorders', async () => {
    const r = await page.evaluate(() => {
      const out = {}, s = sourcesData.src2, live = liveNodes(s).filter(isAlive);
      openProfiles(); openSourceEntry('src2');
      out.fastest = unitNode('src2') === bestAlive(live);
      document.querySelectorAll('#se-mode .seg-switch button')[1].click();
      s.pickOrder = [live[live.length - 1], live[0]].map(n => 'src2::' + n.id); renderSourceEntry();
      out.priority = s.pickMode === 'priority' && unitNode('src2') === live[live.length - 1];
      out.tag = /priority/.test(document.querySelector('.conn-row[data-id=src2]').textContent);
      out.grips = document.querySelectorAll('#se-nodes > .node-row .cc-grip').length === liveNodes(s).length;
      return out;
    });
    await settle(page);
    const rows = page.locator('#se-nodes > .node-row');
    const g = await rows.nth(1).locator('.cc-grip').boundingBox(), top = await rows.first().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, top.y - 10, { steps: 8 }); await page.mouse.up(); await settle(page);
    const r2 = await page.evaluate(() => {
      const out = {}, s = sourcesData.src2, live = liveNodes(s).filter(isAlive);
      out.dragged = unitNode('src2') === live[0];
      s.pickMode = 'fastest'; s.pickOrder = []; closeSheet('sourceentry'); closeSheet('profiles');
      setConnectMode('profiles'); openProfiles(); openEditProfile('default');
      out.cpFastest = !document.querySelector('#cp-order .node-row');
      document.querySelectorAll('#cp-mode .seg-switch button')[1].click();
      out.cpOrder = document.querySelectorAll('#cp-order .node-row').length === cpDraftRefs().length;
      document.getElementById('cpSaveBtn').click();
      out.saved = profilesData.default.pickMode === 'priority' && unitNode('default') === unitPickRefs('default').map(r => r.node).find(isAlive);
      profilesData.default.pickMode = 'fastest';
      closeSheet('profiles'); setConnectMode('simple'); renderAll();
      return out;
    });
    expect(Object.values(r).concat(Object.values(r2)).every(Boolean), JSON.stringify([r, r2]));
  });

  await check('Fastest / Priority is a swipeable switch: the pill slides, ping all sits beside it', async () => {
    await page.evaluate(() => { switchTab('nodes'); setNodesTab('profiles'); openEditProfile('default'); cpPickMode = 'fastest'; renderCpOrder(); });
    await settle(page);
    const sw = await page.locator('#cp-mode .seg-switch').boundingBox();
    await page.mouse.move(sw.x + 30, sw.y + sw.height / 2); await page.mouse.down();
    await page.mouse.move(sw.x + sw.width - 20, sw.y + sw.height / 2, { steps: 6 }); await page.mouse.up(); await settle(page);
    const r = await page.evaluate(() => {
      const el = document.querySelector('#cp-mode .seg-switch'), ping = document.querySelector('#cp-mode .seg-ping');
      const out = { swiped: cpPickMode === 'priority', pill: el.dataset.mode === 'priority', ping: !!ping && ping.getBoundingClientRect().left > el.getBoundingClientRect().right };
      ping.click(); out.pinging = cpDraftRefs().some(r => (pingCache.get(pingKey(r.node)) || {}).ms === 'testing');
      closeSheet('createprofile'); setNodesTab('simple'); switchTab('home');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('Fastest lists are sorted by ping, the quickest on top', async () => {
    const r = await page.evaluate(() => {
      const ms = sel => [...document.querySelectorAll(sel)].map(row => { const n = row.querySelector('.lat'); const v = parseInt(n ? n.textContent : ''); return isNaN(v) ? 1e9 : v; });
      const sorted = a => a.length > 1 && a.every((v, i) => !i || a[i - 1] <= v);
      switchTab('nodes'); setNodesTab('profiles'); profilesData.default.pickMode = 'fastest'; expandState.default = true; renderNodes();
      const out = { card: sorted(ms('#nodes-profiles .entry-card[data-id=default] .src-body .node-row')) };
      openSourceEntry('src1'); sourcesData.src1.pickMode = 'fastest'; renderSourceEntry();
      out.entry = sorted(ms('#se-nodes .node-row')); closeSheet('sourceentry');
      expandState.default = false; setNodesTab('simple'); switchTab('home'); renderAll();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('launch: pings the top Auto entries by priority and the rules\' targets; General settings', async () => {
    const r = await page.evaluate(async () => {
      const out = {}, ids = launchPingEntries(), order = visibleOrder(), auto = order.filter(id => connectEntry(id).inAuto);
      out.fromTop = autoConnect && ids.join() === auto.slice(0, autoCfg.standby + 1).join() && ids.length > 1;
      const keys = new Set(ids.flatMap(id => entryRefs(id).map(r => pingKey(r.node))).concat(ruleTargets().flatMap(t => targetRefs(t).map(r => pingKey(r.node)))));
      out.rules = ruleTargets().includes('chain:sc1');
      // Pings of earlier checks may still be in flight: forget them, count only this call's.
      const inFlight = () => [...pingCache.entries()].filter(([, v]) => v.ms === 'testing').map(([k]) => k);
      inFlight().forEach(k => pingCache.delete(k));
      const p = pingOnLaunch();
      const testing = inFlight();
      out.onlyThose = testing.length > 0 && testing.every(k => keys.has(k));
      await p;
      switchTab('settings'); openSheet('setgeneral');
      out.rows = document.querySelectorAll('#general-settings .set-row').length >= 6;   // the update rows live in Settings → Data now
      document.querySelector('#general-settings [data-key=connectOnLaunch] .mini-toggle').click();
      out.toggled = genCfg.connectOnLaunch && /connects on launch/.test(document.getElementById('setGeneralSub').textContent);
      document.querySelector('#general-settings [data-key=connectOnLaunch] .mini-toggle').click();
      setAutoCfg('standby', 3); out.hint = /next 3 by priority/.test(document.getElementById('general-settings').textContent); setAutoCfg('standby', 2);
      closeSheet('setgeneral'); switchTab('home');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('[?] opens a tip sheet above nested sheets', async () => {
    await page.evaluate(() => {
      openProfiles(); openSourceEntry('src1');
      document.querySelector('#sh-sourceentry .help-btn').click();
    });
    await settle(page);
    const r = await page.evaluate(() => {
      const h = document.getElementById('sh-help'), top = document.elementFromPoint(200, h.getBoundingClientRect().top + 40);
      const out = { open: h.classList.contains('open') && document.querySelectorAll('#help-body .help-item').length > 2,
        above: h.contains(top), padded: (() => { const b = document.getElementById('help-body').getBoundingClientRect(), i = document.querySelector('#help-body .help-item').getBoundingClientRect(); return i.left - b.left >= 14 && b.right - i.right >= 14; })(), all: [...document.querySelectorAll('.help-btn')].every(b => HELP[b.getAttribute('onclick').match(/'(\w+)'/)[1]]) };
      closeSheet('help'); closeSheet('sourceentry'); closeSheet('profiles');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('Auto mode card opens the Auto mode sheet over Home; settings apply; subscriptions default to auto', async () => {
    await page.click('#autoCard'); await settle(page);
    const r = await page.evaluate(() => {
      const out = {};
      out.open = document.getElementById('view-home').classList.contains('active') && document.getElementById('sh-setauto').classList.contains('open') && !!document.querySelector('#auto-settings .set-group');
      const th = document.getElementById('am-threshold'); th.value = '100'; th.dispatchEvent(new Event('change'));
      out.threshold = autoCfg.threshold === 100;
      const th2 = document.getElementById('am-threshold'); th2.value = 'abc'; th2.dispatchEvent(new Event('change'));
      out.badInput = autoCfg.threshold === 100 && document.getElementById('am-threshold').value === '100';
      const dlg = (btn, val, unit) => { document.getElementById(btn).click(); document.getElementById('iv-value').value = val; document.getElementById('iv-unit').value = unit; saveIntervalDialog(); };
      document.getElementById('am-every').click();
      out.dlgOpen = document.getElementById('sh-interval').classList.contains('open') && document.getElementById('iv-value').value === '1' && document.getElementById('iv-unit').selectedOptions[0].textContent === 'minutes';
      dlg('am-every', '5', '60');
      out.every = autoCfg.checkEvery === 300 && /5 min/.test(document.getElementById('am-every').textContent) && !document.getElementById('sh-interval').classList.contains('open');
      dlg('am-every', '2', '1');   // 2 s: below the minimum — refused, dialog stays
      out.everyMin = autoCfg.checkEvery === 300 && document.getElementById('sh-interval').classList.contains('open'); closeSheet('interval');
      dlg('am-subs', '2', '86400');
      out.subs = autoCfg.subsEvery === 172800 && /2 d/.test(document.getElementById('am-subs').textContent);
      dlg('am-subs', '30', '60');
      out.subsMin = autoCfg.subsEvery === 1800 && /30 min/.test(document.getElementById('am-subs').textContent);
      dlg('am-subs', '0', '3600');
      out.subsOff = autoCfg.subsEvery === 0 && /off/.test(document.getElementById('am-subs').textContent);
      dlg('am-subs', '5', '1');   // 5 s: below the minimum — refused
      out.subsTooShort = autoCfg.subsEvery === 0; closeSheet('interval');
      dlg('am-subs', '12', '3600');
      out.subsBack = autoCfg.subsEvery === 43200;
      const slider = () => document.querySelector('#am-standby input[type=range]');
      const sv = v => { const r = slider(); r.value = v; r.dispatchEvent(new Event('input')); r.dispatchEvent(new Event('change')); };
      out.slider = slider().max === '20' && slider().value === '2' && /next 2/.test(document.getElementById('am-standby-val').textContent);
      sv(20); out.spares20 = autoCfg.standby === 20 && /next 20/.test(document.getElementById('am-standby-val').textContent);
      out.warmPlan = planAuto().standby === 20 && planAuto().warmEvery === 60 && !('keepWarm' in planAuto());
      dlg('am-warm', '5', '60');
      out.warmEvery = autoCfg.warmEvery === 300 && /5 min/.test(document.getElementById('am-warm').textContent);
      sv(0); out.sparesOff = autoCfg.standby === 0 && /off/.test(document.getElementById('am-standby-val').textContent) && !document.getElementById('am-warm');
      sv(2); setAutoCfg('warmEvery', 60); out.sparesBack = !!document.getElementById('am-warm');
      const sp = [...document.querySelectorAll('#auto-settings .set-row')].find(r => /Speed test on failures/.test(r.textContent));
      sp.querySelector('.mini-toggle').click();
      out.speed = autoCfg.speedOnFail === true; setAutoCfg('speedOnFail', false);
      for (let i = 0; i < 6; i++) document.querySelector('#am-failafter .stepper-btn:last-child').click();
      out.stepMax = autoCfg.failAfter === 5 && document.querySelector('#am-failafter .stepper-btn:last-child').disabled;
      for (let i = 0; i < 6; i++) document.querySelector('#am-failafter .stepper-btn').click();
      out.stepMin = autoCfg.failAfter === 1;
      const num = (id, v) => { const el = document.getElementById(id); el.value = v; el.dispatchEvent(new Event('change')); };
      out.retryDefault = autoCfg.retryPause === 0.5 && document.getElementById('am-retry').value === '0.5' && planAuto().retryPause === 0.5;
      num('am-retry', '2,5'); out.retry = autoCfg.retryPause === 2.5 && planAuto().retryPause === 2.5;
      num('am-retry', '0'); out.retryNoOff = autoCfg.retryPause === 2.5 && document.getElementById('am-retry').value === '2.5';
      num('am-retry', '11'); out.retryMax = autoCfg.retryPause === 2.5;
      num('am-retry', '0.15'); out.retryTenths = autoCfg.retryPause === 2.5;
      num('am-retry', '0.1'); out.retryLow = autoCfg.retryPause === 0.1;
      num('am-retry', '0.5');
      const ret = document.getElementById('am-return');
      out.returnDefault = ret.value === 'always' && planAuto().returnTo === 'always' && ret.options.length === 3;
      ret.value = 'faster'; ret.dispatchEvent(new Event('change'));
      out.returnFaster = autoCfg.returnTo === 'faster' && planAuto().returnTo === 'faster' && document.getElementById('am-return').value === 'faster';
      setAutoCfg('returnTo', 'always');
      // Retry a failed site through other routes: Off | Up to 3 | All, in the plan as siteRetry, saved with autoCfg
      const sr = document.getElementById('am-siteretry-sel');
      out.siteDefault = sr.value === '3' && planAuto().siteRetry === '3' && sr.options.length === 3 && !!document.querySelector('#am-siteretry .set-hint');
      sr.value = 'off'; sr.dispatchEvent(new Event('change'));
      out.siteOff = autoCfg.siteRetry === 'off' && planAuto().siteRetry === 'off' && document.getElementById('am-siteretry-sel').value === 'off' && liveSnapshot().autoCfg.siteRetry === 'off';
      setAutoCfg('siteRetry', 'all'); out.siteAll = planAuto().siteRetry === 'all' && document.getElementById('am-siteretry-sel').value === 'all';
      setAutoCfg('siteRetry', '3');
      out.flapDefault = autoCfg.flapGuard && document.getElementById('am-flapmax').value === '30' && document.getElementById('am-flapreset').value === '15';
      num('am-flapmax', '61'); num('am-flapreset', '4'); out.flapBounds = autoCfg.flapMax === 30 && autoCfg.flapReset === 15;
      num('am-flapmax', '60'); num('am-flapreset', '5'); out.flapSet = autoCfg.flapMax === 60 && autoCfg.flapReset === 5 && planAuto().flapMax === 60 && planAuto().flapReset === 5;
      document.querySelector('#am-flap .mini-toggle').click();
      out.flapOff = autoCfg.flapGuard === false && !document.getElementById('am-flapmax') && planAuto().flapGuard === false;
      setAutoCfg('flapGuard', true); setAutoCfg('flapMax', 30); setAutoCfg('flapReset', 15);
      out.help = !!HELP.autoreturn && !!document.querySelector('#auto-settings .help-btn[onclick*="autoreturn"]');
      setAutoCfg('failAfter', 2); setAutoCfg('checkEvery', 60);
      setAutoCfg('threshold', 50);
      closeSheet('setauto'); switchTab('home');
      openSrcForm('src1');
      const ivBtn = () => document.getElementById('sf-interval').textContent.trim();
      const ivSet = (v, u) => { document.getElementById('sf-interval').click(); document.getElementById('iv-value').value = v; document.getElementById('iv-unit').value = u; saveIntervalDialog(); };
      out.auto = /^auto · 12 h$/.test(ivBtn());
      document.getElementById('sf-interval').click();
      out.dlg = document.getElementById('sh-interval').classList.contains('open') && document.getElementById('iv-value').value === '' && document.getElementById('iv-unit').options.length === 3;
      ivSet('8', '3600'); saveSrcForm();
      out.own = sourcesData.src1.updateInterval === 8 * 3600;
      openSrcForm('src1'); out.ownShown = ivBtn() === '8 h' && !document.getElementById('sh-interval').classList.contains('open');
      ivSet('3', '1'); out.tooLow = sfInterval === 8 * 3600;   // under 10 s: refused, dialog stays
      closeSheet('interval');
      ivSet('30', '60'); out.min = ivBtn() === '30 min'; saveSrcForm();
      out.minStored = sourcesData.src1.updateInterval === 1800;
      openSrcForm('src1'); ivSet('', '60'); saveSrcForm();
      out.back = sourcesData.src1.updateInterval === 'auto';
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('subscription: announce on the card, rediscover in ⋮, URL edit resets the UA strategy, bad filter refused', async () => {
    const r = await page.evaluate(async () => {
      const out = {}, calls = [], orig = backend.updateSource;
      backend.updateSource = (s, opts) => { calls.push([s.id, opts]); return Promise.resolve(); };
      // any two subscriptions: A gets a provider announce, support link and a fixed UA; B stays Auto
      const [ia, ib] = sourceOrder.filter(id => sourcesData[id].kind === 'sub'), A = sourcesData[ia], keepA = { ...A };
      Object.assign(A, { announce: 'Maintenance tonight', supportUrl: 'https://t.me/x', userAgent: 'mihomo' });
      switchTab('nodes'); renderNodes();
      const ann = document.querySelector(`.src-card[data-id=${ia}] .src-announce`);
      out.announce = !!ann && /Maintenance/.test(ann.textContent);
      openSourceActions(ia);   // a fixed UA: no rediscover; the provider's support link is there
      out.noRediscover = !/all user agents/.test(document.getElementById('actions-body').textContent);
      out.support = /Support/.test(document.getElementById('actions-body').textContent);
      closeSheet('actions');
      Object.keys(A).forEach(k => { if (!(k in keepA)) delete A[k]; }); Object.assign(A, keepA);
      openSourceActions(ib);
      [...document.querySelectorAll('#actions-body .menu-row')].find(x => /all user agents/.test(x.textContent)).click();
      out.rediscover = calls.length === 1 && calls[0][0] === ib && calls[0][1].rediscover === true;
      await new Promise(res => setTimeout(res, 50));
      const s = sourcesData[ib], url = s.url;
      s.uaStrategy = [{ ua: 'mihomo', unique: 3 }]; s.discoveredAt = 1;
      openSrcForm(ib); document.getElementById('sf-filter').value = '(';
      saveSrcForm();
      out.badFilter = s.filter === '' && sheetStack.some(x => x.name === 'srcform');
      document.getElementById('sf-filter').value = ''; document.getElementById('sf-url').value = url + 'x';
      saveSrcForm();
      await new Promise(res => setTimeout(res, 50));
      out.reset = s.url === url + 'x' && s.uaStrategy.length === 0 && s.discoveredAt === 0
        && calls.length === 2 && calls[1][1].rediscover === true;
      openSrcForm(ib); document.getElementById('sf-url').value = url; saveSrcForm();
      await new Promise(res => setTimeout(res, 50));
      backend.updateSource = orig; switchTab('home');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('ping cache: one result per server, shared by every view', async () => {
    const ok = await page.evaluate(async () => {
      const n = sourcesData.src1.nodes[0];
      await pingNodes([n]);
      return ping(n) === pingCache.get(pingKey(n)).ms && pingAge(n) < 5000;
    });
    expect(ok, 'cache not updated by pingNodes');
  });

  await check('system proxy: Home switch and Settings → Connection stay in sync', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      document.getElementById('seg-sys-on').click();
      out.home = connCfg.sysProxy === true && document.getElementById('seg-sys').classList.contains('sys-on');
      out.settings = document.querySelector('#conn-settings .mini-toggle').classList.contains('on');
      document.querySelector('#conn-settings .mini-toggle').click();
      out.off = connCfg.sysProxy === false && segState.sys === 'off' && document.getElementById('seg-sys-off').classList.contains('active');
      // a tap anywhere on a two-option switch flips it, even on the option already chosen
      const route = segState.route;
      document.getElementById('seg-route-' + route).click();
      out.flip = segState.route !== route;
      document.querySelector('#seg-route .segment-pill').click();
      out.back = segState.route === route;
      document.querySelector('#seg-sys .seg-title').click();
      out.title = connCfg.sysProxy === true;
      document.getElementById('seg-sys').click();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('DNS: card opens the DNS sheet over Home, pings, keeps one server, form validates, hijack note', async () => {
    await page.click('#dnsCard'); await settle(page);
    const r = await page.evaluate(async () => {
      const out = {};
      out.open = document.getElementById('view-home').classList.contains('active') && document.getElementById('sh-setdns').classList.contains('open');
      out.pinging = dnsPing.remote !== undefined;
      toggleDnsOn('remote'); toggleDnsOn('local');
      out.keepsOne = dnsActive().length === 1; toggleDnsOn('remote');
      out.sub = /Cloudflare/.test(document.getElementById('dnsCardSub').textContent);
      openDnsForm();
      document.getElementById('df-addr').value = 'not a dns'; saveDnsForm();
      out.bad = dnsOrder.length === 3 && document.getElementById('sh-dnsform').classList.contains('open');
      document.getElementById('df-addr').value = 'tls://9.9.9.9'; setDnsDraftVia('direct');
      await pingDnsDraft();
      out.draftPing = /ms/.test(document.getElementById('df-ping').textContent);
      saveDnsForm();
      const id = dnsOrder[3];
      out.added = dnsOrder.length === 4 && dnsServers[id].via === 'direct' && document.querySelectorAll('#dns-settings .dns-row').length === 4;
      openDnsForm(id); deleteDnsServer();
      out.deleted = dnsOrder.length === 3;
      setSegment('mode', 'proxy');
      out.note = !!document.querySelector('#dns-settings .set-hint.warn');
      setSegment('mode', 'tun');
      out.noteGone = !document.querySelector('#dns-settings .set-hint.warn');
      closeSheet('setdns'); switchTab('home');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('DNS failover: the server in use and a failed one are marked, Switch automatically off keeps the first, events in the journal', async () => {
    const r = await page.evaluate(async () => {
      const out = {}, tags = () => [...document.querySelectorAll('#dns-settings .dns-row')].map(r => r.dataset.id + ':' + [...r.querySelectorAll('.dns-state')].map(s => s.textContent).join());
      openDnsSettings(); await wait(1200);
      dnsPing.remote = 20; dnsPing.local = 12; dnsPing.google = 30; renderDns();
      out.first = tags().join() === 'remote:In use,local:,google:';
      const n0 = mockEv.list.filter(e => e.cat === 'dns').length;
      dnsPing.remote = -1; renderDns();
      out.failover = tags().join() === 'remote:No answer,local:In use,google:';
      const ev = mockEv.list.filter(e => e.cat === 'dns').slice(n0);
      out.event = ev.length === 1 && ev[0].data.from === 'remote' && ev[0].data.to === 'local' && ev[0].data.reason === 'failover' && /DNS: Cloudflare → Local/.test(evText(ev[0]));
      setDnsCfg('auto', false);
      out.off = tags().join() === 'remote:No answer,local:,google:' && dnsHealth().active === 'remote';
      const last = mockEv.list.filter(e => e.cat === 'dns').pop();
      out.offEvent = last.data.reason === 'off' && last.own === true;
      setDnsCfg('auto', true);
      dnsPing.remote = 20; renderDns();
      out.back = dnsHealth().active === 'remote' && mockEv.list.filter(e => e.cat === 'dns').pop().data.reason === 'back';
      out.hint = !!document.querySelector('#dns-settings [data-key=dnsAuto] .mini-toggle.on');
      // the rules events read as words: the target by its name, what the rule does meanwhile
      const src = catalogOrder.simple[0], nm = sourcesData[src].name;
      const a = evDescribe({ cat: 'rules', type: 'fallback', data: { rule: 'Streaming', more: 2, target: 'src:' + src, to: 'block' } });
      const b = evDescribe({ cat: 'rules', type: 'targetBack', data: { rule: 'Streaming', target: 'src:' + src } });
      out.words = a.title === nm + ' does not answer' && a.detail === 'Rule Streaming and 2 more blocked while it is down' && b.title === nm + ' answers again' && b.detail === 'Rule Streaming back through it';
      out.notif = EV_NOTIF['rules/fallback'] === 'autoSwitch' && EV_NOTIF['rules/targetBack'] === 'autoSwitch' && EV_NOTIF['dns/switched'] === 'autoSwitch';
      out.filter = EV_CATS.some(c => c[0] === 'dns') && EV_CATS.find(c => c[0] === 'rules')[2].some(t => t[0] === 'fallback');
      closeSheet('setdns');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('rules: chips, paste, validation, save / delete, JSON round-trip, composite', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      openRules(); openRuleForm();
      const inp = () => document.querySelector('#rf-body input[data-g="domain"][data-f="domain_suffix"]');
      inp().value = 'example.com'; inp().dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
      rfAddValues('domain', 'domain_suffix', 'a.org\nb.org; bad value');
      out.chips = document.querySelectorAll('#rf-body .vchip').length === 4 && document.querySelectorAll('#rf-body .vchip.bad').length === 1;
      const n = ruleOrder.length; saveRuleForm();
      out.refused = ruleOrder.length === n;
      rfRemoveVal('domain', 'domain_suffix', 3);
      out.noLinks = !document.querySelector('#rf-body .rf-more');   // no "+ Keyword" links inside cards
      rfAddField('domain', 'domain_keyword');
      out.fold = !!document.querySelector('#rf-body input[data-f="domain_keyword"]');
      rfAddField('port', 'port'); rfAddValues('port', 'port', '443, 8000-9000', false);
      ruleDraft.action = 'direct';
      setRfTab('json');
      const j = JSON.parse(document.getElementById('rf-json').value);
      out.json = j.port[0] === 443 && j.port_range[0] === '8000:9000' && j.outbound === 'direct' && j.domain_suffix.length === 3;
      j.domain_suffix.push('c.org'); j.ip_version = 4;
      document.getElementById('rf-json').value = JSON.stringify(j); rfCheckJson();
      setRfTab('form');
      out.back = ruleDraft.groups.domain.v.domain_suffix.includes('c.org') && !!document.querySelector('#rf-body .rf-plaque');
      saveRuleForm();
      const id = ruleOrder[ruleOrder.length - 1];
      out.saved = ruleOrder.length === n + 1 && rulesData[id].action === 'direct' && !document.getElementById('sh-ruleform').classList.contains('open');
      out.test = testAddress('x.b.org:8080').rule.startsWith('#' + ruleOrder.length) && testAddress('b.org:22').rule === 'Everything else';
      openRuleForm(id); deleteRule();
      out.deleted = ruleOrder.length === n && !rulesData[id];
      openRuleForm('r4');
      out.composite = !!document.querySelector('#rf-body .rf-plaque') && !document.querySelector('#rf-body .rf-group');
      closeSheet('ruleform');
      out.apps = testAddress('Telegram').rule === 'Apps → Telegram';
      // local networks: always direct and first, no toggle, not in the plan (the core adds it)
      out.lan = testAddress('192.168.1.5').to === 'Direct' && testAddress('router.lan').to === 'Direct';
      out.lanFirst = effectiveRules()[0][0] === 'Local networks';
      out.lanFixed = !!document.getElementById('qr-lan') && !document.querySelector('#qr-lan .toggle, #qr-lan input');
      out.lanPlan = !('lan' in routingPlan().quick);
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('rule form: a chip edits in place (Enter / blur commit, invalid stays red, Esc cancels, empty removes, JSON follows); + Condition keeps all four dashed edges at 100% and 120%', async () => {
    await page.evaluate(() => { openRules(); openRuleForm(); ruleDraft.groups = { domain: { not: false, v: { domain_suffix: ['a.org', 'b.org', 'c.org'] } } }; renderRuleForm(); });
    const vals = () => page.evaluate(() => ruleDraft.groups.domain && ruleDraft.groups.domain.v.domain_suffix || []);
    const edit = async i => { await page.click(`#rf-body .vchip:nth-child(${i + 1}) .vchip-t`); await page.waitForTimeout(50); };
    // tap -> input with the value, focused, caret at the end
    await edit(1);
    const st = await page.evaluate(() => { const i = document.activeElement; return { on: i && i.classList.contains('vchip-edit'), v: i && i.value, end: i && i.selectionStart === i.value.length && i.selectionEnd === i.value.length }; });
    expect(st.on && st.v === 'b.org' && st.end, 'edit input: ' + JSON.stringify(st));
    await page.keyboard.press('Control+A'); await page.keyboard.type('bad value'); await page.keyboard.press('Enter');
    expect(await page.evaluate(() => { const i = document.querySelector('#rf-body .vchip-edit'); return !!i && i.classList.contains('bad') && !!document.querySelector('#rf-body .rf-edit-hint'); }) && (await vals()).join() === 'a.org,b.org,c.org', 'invalid stays in edit, red, draft untouched');
    await page.keyboard.press('Control+A'); await page.keyboard.type('b2.org'); await page.keyboard.press('Enter');
    expect((await vals()).join() === 'a.org,b2.org,c.org' && !await page.locator('#rf-body .vchip-edit').count(), 'Enter commits: ' + (await vals()).join());
    await edit(0); await page.keyboard.type('x'); await page.keyboard.press('Escape');
    expect((await vals()).join() === 'a.org,b2.org,c.org' && !await page.locator('#rf-body .vchip-edit').count(), 'Esc cancels');
    await edit(2); await page.keyboard.press('Control+A'); await page.keyboard.type('c2.org'); await page.click('#rf-body .rf-flabel');   // blur commits
    expect((await vals()).join() === 'a.org,b2.org,c2.org', 'blur commits: ' + (await vals()).join());
    // JSON tab and back keep the edit
    const js = await page.evaluate(() => { setRfTab('json'); const j = JSON.parse(document.getElementById('rf-json').value); setRfTab('form'); return j.domain_suffix; });
    expect(js.join() === 'a.org,b2.org,c2.org' && (await vals()).join() === 'a.org,b2.org,c2.org', 'json round-trip: ' + js);
    await edit(0); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace'); await page.keyboard.press('Enter');
    expect((await vals()).join() === 'b2.org,c2.org', 'empty removes: ' + (await vals()).join());
    // the × still removes
    await page.click('#rf-body .vchip:nth-child(1) b'); expect((await vals()).join() === 'c2.org', '× removes');
    // + Condition: a dashed 1px border on every edge, its top edge inside the scroll box and clear of the card above
    for (const scale of [1, 1.2]) {
      const r = await page.evaluate(scale => {
        applyScale(scale); renderRuleForm();
        const b = document.querySelector('#rf-body .rf-add-btn'), cs = getComputedStyle(b), box = b.getBoundingClientRect(), sc = document.getElementById('rf-body').getBoundingClientRect();
        b.scrollIntoView({ block: 'nearest' });
        const prev = b.previousElementSibling.getBoundingClientRect(), after = b.getBoundingClientRect();
        const top = document.elementFromPoint(after.left + after.width / 2, after.top + .5);
        return { styles: ['Top', 'Right', 'Bottom', 'Left'].map(s => cs['border' + s + 'Style'] + (parseFloat(cs['border' + s + 'Width']) > .5 ? '' : ' thin')).join(), clear: prev.bottom <= after.top + .01, inside: after.top >= sc.top - .01 && after.bottom <= sc.bottom + .01, topHit: top === b || b.contains(top) };
      }, scale);
      expect(r.styles === Array(4).fill('dashed').join() && r.clear && r.inside && r.topHit, 'dashed + Condition at ' + scale + ': ' + JSON.stringify(r));
    }
    await page.evaluate(() => { applyScale(1); closeSheet('ruleform'); });
  });

  await check('rule form: + Condition offers every field; a field × (the last takes the card); no links inside cards', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      openRules(); openRuleForm();
      out.startOne = Object.keys(ruleDraft.groups).join() === 'domain' && document.querySelectorAll('#rf-body .rf-field').length === 1 && !document.querySelector('#rf-body .rf-more');
      // every field of every group is reachable through the picker, and leaves it once on the form
      ruleDraft.groups = {}; rfAddOpen = true; renderRuleForm();
      const all = RULE_GROUPS.flatMap(g => rfFieldsOf(g).map(([f]) => [g.key, f]));
      out.offered = all.every(([g, f]) => !!document.querySelector(`#rf-body .rf-add .chip[onclick="rfAddField('${g}','${f}')"]`)) && document.querySelectorAll('#rf-body .rf-add .chip').length === all.length;
      all.forEach(([g, f]) => { rfAddOpen = true; renderRuleForm(); document.querySelector(`#rf-body .rf-add .chip[onclick="rfAddField('${g}','${f}')"]`).click(); });
      out.allOn = document.querySelectorAll('#rf-body .rf-group').length === RULE_GROUPS.length && !document.querySelector('#rf-body .rf-add, #rf-body .rf-add-btn')
        && document.querySelectorAll('#rf-body .rf-group > .rf-ghead').length === RULE_GROUPS.length
        && document.querySelectorAll('#rf-body .rf-field .rf-x').length === all.length && !document.querySelector('#rf-body .rf-more');
      // × on a field: the others stay; on the last one the card goes
      document.querySelector('#rf-body .rf-group[data-g="domain"] .rf-field .rf-x').click();
      out.oneField = ruleDraft.groups.domain && !('domain_suffix' in ruleDraft.groups.domain.v) && 'domain' in ruleDraft.groups.domain.v && document.querySelectorAll('#rf-body .rf-group[data-g="domain"] .rf-field').length === 5;
      ['domain', 'domain_keyword', 'domain_regex', 'geosite', 'rule_set'].forEach(f => rfRemoveField('domain', f));
      out.cardGone = !ruleDraft.groups.domain && !document.querySelector('#rf-body .rf-group[data-g="domain"]');
      rfRemoveField('ip', 'ip_is_private'); rfRemoveField('ip', 'ip_cidr');
      out.flagField = !!ruleDraft.groups.ip && ruleDraft.groups.ip.flag === undefined; rfRemoveField('ip', 'geoip');
      out.ipGone = !ruleDraft.groups.ip;
      rfRemoveField('network', 'network');
      out.choice = !!ruleDraft.groups.network && !('network' in ruleDraft.groups.network.v) && 'protocol' in ruleDraft.groups.network.v;
      // the picker offers the removed field again, and the card × still removes a whole card
      rfAddOpen = true; renderRuleForm();
      out.again = !!document.querySelector('#rf-body .rf-add .chip[onclick="rfAddField(\'domain\',\'domain_suffix\')"]') && !document.querySelector('#rf-body .rf-add .chip[onclick="rfAddField(\'network\',\'protocol\')"]');
      rfRemoveGroup('port'); out.cardX = !ruleDraft.groups.port;
      closeSheet('ruleform');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('rule form: Form → JSON → Form gives the same draft (single group, Domains + IP, except, GeoIP / local networks, fallback, dns, block, name)', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      const canon = o => JSON.stringify(o, (k, v) => v && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => a < b ? -1 : 1)) : v);
      const tgt = allTargets().find(Boolean), srv = dnsOrder[dnsOrder.length - 1];
      const g = (v, o) => Object.assign({ not: false, v }, o);
      const cases = {
        single: { groups: { domain: g({ domain_suffix: ['a.com', 'b.com'], domain_keyword: ['ads'] }) } },
        domainIp: { action: 'direct', dns: srv, groups: { domain: g({ domain_suffix: ['a.com'] }), ip: g({ ip_cidr: ['10.0.0.0/8', '1.1.1.1'] }) } },
        except: { name: 'Not RU', groups: { domain: g({ domain_suffix: ['ru'] }, { not: true }), port: g({ port: ['443'] }) } },
        exceptBoth: { ipTunOnly: true, groups: { domain: g({ domain: ['x.org'] }, { not: true }), ip: g({ geoip: ['ru'] }, { not: true }) } },
        geoipLan: { groups: { ip: g({ geoip: ['ru', 'by'] }, { flag: true }), network: g({ network: ['tcp'], protocol: ['tls', 'quic'] }) } },
        lanOnly: { action: 'direct', groups: { domain: g({ geosite: ['youtube'], rule_set: ['ru-blocked'] }), ip: g({}, { flag: true }) } },
        fallback: { action: 'proxy', target: tgt, fallback: 'block', name: 'Via target', groups: { domain: g({ domain_regex: ['^a.+$'] }), source: g({ source_ip_cidr: ['192.168.1.0/24'], source_port: ['5000'] }) } },
        proxyMain: { groups: { process: g({ process: ['chrome.exe', '/usr/bin/x'] }), ip: g({ ip_cidr: ['8.8.8.8'] }) } },
        directDns: { action: 'direct', dns: srv, groups: { domain: g({ domain_suffix: ['lan'] }) } },
        blockDrop: { action: 'block', block: 'drop', groups: { domain: g({ domain_keyword: ['tracker'] }), ip: g({ ip_cidr: ['1.2.3.4'] }) } },
        blockReject: { action: 'block', block: 'reject', name: 'No ads', groups: { domain: g({ domain_suffix: ['ads.com'] }) } },
        emptyCard: { groups: { domain: g({ domain_suffix: [] }), ip: g({ ip_cidr: ['10.0.0.0/8'] }) } },
      };
      openRules(); openRuleForm();
      for (const [name, o] of Object.entries(cases)) {
        const want = newRule(o); want.id = '';
        ruleDraft = JSON.parse(JSON.stringify(want)); rfTab = 'form'; renderRuleForm();
        const groups = Object.keys(want.groups).length;
        setRfTab('json'); setRfTab('form');
        out[name] = canon(ruleDraft) === canon(want) && !document.querySelector('#rf-body .rf-plaque') && document.querySelectorAll('#rf-body .rf-group').length === groups;
        if (!out[name]) out[name + '_got'] = canon(ruleDraft) + ' vs ' + canon(want);
      }
      // a genuinely foreign rule still says so
      openRuleForm('r4');
      out.foreign = !!document.querySelector('#rf-body .rf-plaque') && !document.querySelector('#rf-body .rf-group');
      closeSheet('ruleform');
      return out;
    });
    expect(Object.entries(r).every(([k, v]) => k.endsWith('_got') || v === true), JSON.stringify(r));
  });

  await check('rules: drag reorders my rules; search hides grips', async () => {
    await page.evaluate(() => openRules()); await settle(page);
    const before = await page.evaluate(() => ruleOrder.join());
    const g = await page.locator('#rules-list .rule-row >> nth=0 >> .drag-handle').boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, g.y + 120, { steps: 8 }); await page.mouse.up(); await page.waitForTimeout(300);
    const after = await page.evaluate(() => ruleOrder.join());
    const grips = await page.evaluate(() => { setRuleQuery('discord'); const n = document.querySelectorAll('#rules-list .drag-handle').length + '/' + document.querySelectorAll('#rules-list .rule-row').length; setRuleQuery(''); return n; });
    expect(before !== after && after.split(',')[0] === before.split(',')[1], before + ' → ' + after);
    expect(grips === '0/1', 'search: ' + grips);
  });

  await check('rules: Clash / JSON import and export, rule-set delete guard, apps split', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      openRuleIO(); setRuleIO('export', 'clash');
      out.export = /DOMAIN-SUFFIX,corp\.local,DIRECT/.test(document.getElementById('io-text').value);
      setRuleIO('import', 'clash');
      const n = ruleOrder.length;
      document.getElementById('io-text').value = 'DOMAIN-SUFFIX,ya.ru,DIRECT\nIP-CIDR,10.0.0.0/8,REJECT\nMATCH,PROXY';
      ruleIOAction();
      out.clash = ruleOrder.length === n + 2 && rulesData[ruleOrder[n + 1]].action === 'block' && quickCfg.final === 'proxy';
      openRuleIO(); setRuleIO('import', 'json');
      document.getElementById('io-text').value = '[{"domain":["x.io"],"outbound":"direct"}]'; ruleIOAction();
      out.json = ruleOrder.length === n + 3;
      openRuleIO(); setRuleIO('import', 'json');
      document.getElementById('io-text').value = '[{oops'; ruleIOAction();
      out.err = !!document.getElementById('io-err').textContent; closeSheet('ruleio');
      ruleOrder.slice(n).forEach(id => delete rulesData[id]); ruleOrder.splice(n);
      openRuleSets(); openRsForm('rs1');
      rulesData.r1.groups.domain.v.rule_set = ['ru-blocked'];
      deleteRuleSet();
      out.guard = ruleSets.some(s => s.id === 'rs1');
      delete rulesData.r1.groups.domain.v.rule_set;
      openIntervalDialog('rsEvery'); document.getElementById('iv-value').value = '2'; document.getElementById('iv-unit').value = '3600'; saveIntervalDialog();
      out.every = rsDraft.every === 7200 && /2 h/.test(document.getElementById('rs-every').textContent);
      closeSheet('rsform'); closeSheet('rulesets');
      openApps(); openAppAct('com.whatsapp');
      appDraft.act = 'proxy'; appDraft.split = true; appDraft.udp.act = 'proxy'; appDraft.udp.target = 'profile:work'; renderAppAct();
      out.twoTargets = document.querySelectorAll('#aa-body .tgt-row').length === 2;   // Via and Fallback Via of the TCP tab
      setAppTab('udp'); out.udpTab = document.querySelectorAll('#aa-body .tgt-row').length === 2 && !!document.querySelector('#aa-card .aa-half[data-half="udp"]');
      saveAppAct();
      out.saved = appRules['com.whatsapp'].split && /UDP/.test(document.querySelector('.app-row[data-pkg="com.whatsapp"] .app-state').textContent);
      openAppAct('com.whatsapp'); appDraft.act = 'default'; appDraft.udp.act = 'default'; saveAppAct();
      out.reset = !appRules['com.whatsapp'];
      closeSheet('apps'); closeSheet('rules');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('per-app dialog: height stable across Route / Fallback, no segment clipped (320 at 120%, 280, wide)', async () => {
    for (const [width, scale] of [[320, true], [280, true], [280, false], [420, false]]) {
      const p = await openPage(browser, { width });
      await p.evaluate(s => { if (s) applyScale(UI_SCALE_MAX); openRules(); openApps(); openAppAct('org.telegram.messenger'); appDraft.target = 'src:src1'; }, scale);
      await p.waitForTimeout(400);
      const r = await p.evaluate(() => {
        const hs = new Set(), clipped = [];
        for (const act of ['default', 'proxy', 'direct', 'block']) for (const fb of ['default', 'main', 'direct', 'block']) {
          appDraft.act = act; appDraft.fallback = fb; renderAppAct();
          hs.add(Math.round(document.getElementById('sh-appact').getBoundingClientRect().height));
          const card = document.querySelector('#aa-card .aa-group').getBoundingClientRect();
          document.querySelectorAll('#aa-card .seg3 button').forEach(b => { const r = b.getBoundingClientRect(); if (r.right > card.right + 1 || r.left < card.left - 1 || b.scrollWidth > b.clientWidth + 1) clipped.push(act + '/' + fb + ':' + b.textContent); });
        }
        return { heights: [...hs], clipped };
      });
      expect(r.heights.length === 1 && r.clipped.length === 0, `${width}px scale=${scale}: ${JSON.stringify(r)}`);
      await p.close();
    }
  });

  await check('per-app routing: action order, If unavailable, split on any action, old shape migrates', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const out = {}, txt = () => document.getElementById('aa-body').textContent;
      out.order = APP_ACTS.map(a => a[1]).join() === 'Default,Proxy,Direct,Block';
      openRules(); openApps(); openAppAct('com.whatsapp');
      out.orderUi = [...document.querySelectorAll('#aa-body .aa-route:first-child .seg3 button, #aa-body .aa-group > .aa-route:first-child .seg3 button')].map(b => b.textContent).join() === 'Default,Proxy,Direct,Block';
      // the Split toggle is the first item, above the segment, its explanation in a (?)
      const first = document.getElementById('aa-body').firstElementChild;
      out.toggleFirst = first.classList.contains('aa-split') && !!document.getElementById('aa-split') && !!first.querySelector('.help-btn') && !first.querySelector('.set-hint');
      // If unavailable: only for a proxy half with a target, saved with the app
      appDraft.act = 'direct'; renderAppAct();
      appDraft.act = 'default'; renderAppAct();
      out.fallbackOnDefault =!document.querySelector("#aa-body .aa-fb.aa-inert") && [...document.querySelectorAll("#aa-fallback-all button")].every(b => !b.disabled) && !!document.querySelector("#aa-body .aa-fb-via.aa-inert");
      appDraft.fallback = 'main'; renderAppAct();
      out.defaultFbVia = !document.querySelector("#aa-body .aa-fb-via.aa-inert"); appDraft.fallback = 'default';
      appDraft.act = 'direct'; renderAppAct();
      out.noFallbackDirect = !!document.querySelector("#aa-body .aa-fb.aa-inert") && [...document.querySelectorAll("#aa-fallback-all button")].every(b => b.disabled);
      appDraft.act = 'block'; renderAppAct();
      out.noFallbackBlock = !!document.querySelector("#aa-body .aa-fb.aa-inert") && [...document.querySelectorAll("#aa-fallback-all button")].every(b => b.disabled);
      out.fbLabel = document.querySelector("#aa-body .aa-fb .set-label").textContent === 'Fallback';
      appDraft.act = 'proxy'; appDraft.target = 'src:src1'; renderAppAct();
      out.fallbackRow = !!document.querySelector("#aa-fallback-all") && [...document.querySelectorAll("#aa-fallback-all button")].map(b => b.textContent).join() === "Default,Proxy,Direct,Block" && document.querySelectorAll("#aa-body .aa-fb-via").length === 1 && document.querySelector("#aa-body .aa-fb-via").classList.contains('aa-inert');
      document.querySelectorAll("#aa-fallback-all button")[1].click(); out.fbVia = document.querySelectorAll("#aa-body .aa-fb-via").length === 1 && !document.querySelector("#aa-body .aa-fb-via").classList.contains('aa-inert') && /Main flow/.test(document.querySelector("#aa-body .aa-fb-via").textContent);
      // the Route's Via can't be picked as the fallback target
      document.querySelector("#aa-body .aa-fb-via").click(); pickTarget('src:src1'); out.excluded = tpCurrent === ''; closeSheet('target');
      document.querySelectorAll("#aa-fallback-all button")[3].click();
      out.fallbackSet = appDraft.fallback === "block" && document.querySelectorAll("#aa-body .aa-fb-via").length === 1 && document.querySelector("#aa-body .aa-fb-via").classList.contains('aa-inert');
      saveAppAct();
      out.fallbackSaved = appRules['com.whatsapp'].fallback === 'block' && routingPlan().apps.find(a => a.id === 'com.whatsapp').fallback === 'block';
      // Default + a Fallback is an own rule (kept, configured); Default + Default is not
      openAppAct('com.whatsapp'); appDraft.act = 'default'; appDraft.fallback = 'block'; saveAppAct();
      out.defFbKept = !!appRules['com.whatsapp'] && appRules['com.whatsapp'].fallback === 'block';
      openAppAct('com.whatsapp'); appDraft.fallback = 'default'; saveAppAct();
      out.defFbDropped = !appRules['com.whatsapp'];
      out.evFallback = EV_TEXT['rules/fallback']({ target: 'proxy', app: 'WhatsApp', to: 'src:src1' }).join(' | ') === 'Main flow does not answer | App WhatsApp goes through ' + targetName('src:src1');
      // Split on Block: TCP Default + UDP Block = one udp reject rule in the plan, nothing for TCP
      openAppAct('com.whatsapp'); appDraft.act = 'default'; appDraft.split = true; appDraft.udp.act = 'block'; renderAppAct();
      out.twoBlocks = document.querySelectorAll('#aa-body .aa-half').length === 1 && [...document.querySelectorAll('#aa-tabs .nodes-tab')].map(e => e.textContent).join() === 'TCP,UDP';
      saveAppAct();
      const wa = routingPlan().apps.find(a => a.id === 'com.whatsapp');
      out.udpOnly = wa.split && wa.act === 'default' && wa.udp.act === 'block';
      out.text = appActText(appRules['com.whatsapp']) === 'TCP Default · UDP Block'
        && /UDP Block/.test(document.querySelector('.app-row[data-pkg="com.whatsapp"] .app-state').textContent);
      // Split on Direct, and a proxy half with its own fallback in the UDP block
      openAppAct('com.whatsapp'); appDraft.act = 'direct'; appDraft.udp.act = 'proxy'; appDraft.udp.target = 'src:src1'; appDraft.split = true; renderAppAct();
      setAppTab("udp");
      out.udpFallback = !!document.querySelector('#aa-fallback-udp') && !document.querySelector('#aa-fallback-tcp');
      document.querySelectorAll('#aa-fallback-udp button')[2].click(); saveAppAct();
      const w2 = routingPlan().apps.find(a => a.id === 'com.whatsapp');
      out.splitDirect = w2.act === 'direct' && w2.udp.act === 'proxy' && w2.udp.target === 'src:src1' && w2.udp.fallback === 'direct';
      out.named = 'src:src1' in routingPlan().targets && w2.name === 'WhatsApp';
      out.impact = targetImpact(t => t === 'src:src1').some(l => l[0] === 'WhatsApp' && /UDP/.test(l[1]) && /direct/.test(l[2]));
      // both halves Default: no own route
      openAppAct('com.whatsapp'); appDraft.act = 'default'; appDraft.udp.act = 'default'; appDraft.fallback = appDraft.udp.fallback = 'default'; saveAppAct();
      out.none = !appRules['com.whatsapp'] && !routingPlan().apps.some(a => a.id === 'com.whatsapp');
      // switching Split off drops the UDP half
      openAppAct('org.telegram.messenger'); appDraft.split = true; appDraft.udp.act = 'block'; appDraft.split = false; saveAppAct();
      out.splitOff = !appRules['org.telegram.messenger'].split && appRules['org.telegram.messenger'].udp.act === 'default';
      closeSheet('appact'); closeSheet('apps'); closeSheet('rules');
      // the old shape { act: 'proxy', split, udpTarget } becomes udp: { act: 'proxy', target }
      const m = appRulesNormalize({ a: { act: 'proxy', target: 'src:src1', split: true, udpTarget: 'chain:sc1' }, b: { act: 'direct', target: '', split: false, udpTarget: '' }, c: { act: 'proxy', target: '', split: false, udpTarget: 'chain:sc1' } });
      out.migrated = m.a.udp.act === 'proxy' && m.a.udp.target === 'chain:sc1' && m.a.fallback === 'default' && !('udpTarget' in m.a)
        && m.b.act === 'direct' && m.b.udp.act === 'default' && m.c.udp.act === 'default' && m.c.split === false;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('app events name the app; rule events stay as they were', async () => {
    const r = await page.evaluate(() => {
      const a = evDescribe({ cat: 'rules', type: 'fallback', data: { app: 'Telegram', target: 'src:src1', to: 'block' } });
      const b = evDescribe({ cat: 'rules', type: 'fallback', data: { rule: 'Streaming', more: 2, target: 'src:src1', to: 'direct' } });
      const c = evDescribe({ cat: 'rules', type: 'targetBack', data: { app: 'Telegram', more: 1, target: 'src:src1' } });
      return { app: /App Telegram/.test(a.detail) && /blocked/.test(a.detail), rule: /Rule Streaming and 2 more/.test(b.detail), back: /App Telegram and 1 more/.test(c.detail) };
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('every sheet opens and closes', async () => {
    const ids = await page.$$eval('.sheet', els => els.map(e => e.id.slice(3)));
    for (const id of ids) await page.evaluate(id => { openSheet(id); closeSheet(id); }, id);
    expect(!page.errors.length, page.errors.join(' | '));
  });

  await check('nodes tabs: tap and swipe switch the list, never the route mode', async () => {
    await tab(page, 'nodes');
    await page.evaluate(() => { setNodesTab('simple'); renderNodes(); });
    const mode0 = await page.evaluate(() => connectMode);
    const box = await page.locator('#nodesPager').boundingBox(), y = box.y + 100;
    await page.mouse.move(box.x + box.width - 60, y); await page.mouse.down();
    await page.mouse.move(box.x + 60, y, { steps: 10 }); await page.mouse.up(); await settle(page);
    const r = await page.evaluate(m => ({ tab: nodesTab === 'profiles', mode: connectMode === m, noTap: !document.querySelector('#sh-actions.open'),
      cards: document.querySelectorAll('#nodes-profiles .entry-card').length === catalogOrder.profiles.length,
      dot: document.querySelector(`.nodes-tab[data-tab=${m}]`).classList.contains('used') }), mode0);
    await page.mouse.move(box.x + 150, y); await page.mouse.down();
    await page.mouse.move(box.x + 140, y + 120, { steps: 6 }); await page.mouse.up(); await settle(page);
    r.vertical = await page.evaluate(() => nodesTab === 'profiles');
    await page.click('.nodes-tab[data-tab=simple]'); await settle(page);
    r.tap = await page.evaluate(() => nodesTab === 'simple' && /sources/.test(document.getElementById('nodesSummary').textContent));
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('nodes profiles tab: + creates a profile there, ⋮ Delete lists the rules that lose it', async () => {
    const r = await page.evaluate(() => {
      const out = {}, body = () => document.getElementById('actions-body').textContent;
      switchTab('nodes'); setNodesTab('profiles');
      openNodesAdd(); out.menu = /Profile/.test(body()) && /Chain/.test(body()); closeSheet('actions');
      openCreateProfile(); toggleCreateProfileSource('src1'); document.getElementById('cp-name').value = 'Tmp prof'; saveCreateProfile();
      const id = catalogOrder.profiles.find(x => profilesData[x] && profilesData[x].name === 'Tmp prof');
      out.added = !!id && !!document.querySelector(`#nodes-profiles .entry-card[data-id=${id}]`) && modeOrder('profiles').includes(id);
      const r1 = rulesData.r1; r1.action = 'proxy'; r1.target = 'profile:' + id;
      out.card = !!document.querySelector(`#nodes-profiles .entry-card[data-id=${id}] .icon-btn[title="Edit profile"]`);
      openEditProfile(id); document.getElementById('cpDeleteBtn').click();
      out.impact = /Work network.*rule #\d.*loses its target/.test(body());
      document.querySelector('#actions-body .menu-row.danger').click();
      out.gone = !profilesData[id] && !catalogOrder.profiles.includes(id) && !modeOrder('profiles').includes(id) && !document.getElementById('sh-createprofile').classList.contains('open');
      r1.action = 'direct'; r1.target = '';
      setNodesTab('simple'); switchTab('home'); renderAll(); renderRules();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('rules: target picker offers the whole catalog; If unavailable per rule and global', async () => {
    const r = await page.evaluate(() => {
      const out = {};
      openRules(); openRuleForm('r1'); ruleDraft.action = 'proxy'; renderRuleForm();
      document.querySelector('#rf-body .tgt-row').click();
      out.open = document.getElementById('sh-target').classList.contains('open');
      const ts = [...document.querySelectorAll('#tp-body .tp-card')].map(e => e.dataset.t);
      out.all = ts.includes('') && ts.some(t => t.startsWith('src:')) && ts.some(t => t.startsWith('profile:')) && ts.some(t => t.startsWith('chain:'));
      // a tap on a card unfolds it and does not pick; AUTO picks the whole item; a server picks the node
      const sid = sourceOrder[0], card = () => document.querySelector(`#tp-body .tp-card[data-t="src:${sid}"]`);
      // picks only mark the selection (Save bar while it differs from the opening target); Save applies; tapping the selected item deselects
      const before = ruleDraft.target, saveOn = () => document.getElementById('tp-save').classList.contains('show'), shut = () => !document.getElementById('sh-target').classList.contains('open');
      out.noSave = !saveOn();
      card().querySelector('.src-head').click();
      out.unfold = card().classList.contains('open') && ruleDraft.target === before && !shut() && !saveOn()
        && card().querySelectorAll('.conn-body .node-row').length > 0;
      card().querySelector('.src-head').click();
      out.fold = !card().classList.contains('open');
      out.autoCollapsed = !!card().querySelector('.src-head .conn-state') && !card().classList.contains('open');
      card().querySelector('.src-head .conn-state').click();   // AUTO on the collapsed card marks the whole item, no close
      out.auto = ruleDraft.target === before && !shut() && saveOn() && card().classList.contains('picked') && !card().classList.contains('open')
        && card().querySelector('.src-head .conn-state').classList.contains('on');
      card().querySelector('.src-head .conn-state').click();   // tapped again: deselected -> main flow, with the warning
      out.deselect = !card().classList.contains('picked') && document.getElementById('tp-save').classList.contains('reset') === (before !== '') && saveOn() === (before !== '');
      card().querySelector('.src-head').click();
      card().querySelector('.conn-body .node-row').click();   // a server marks itself
      out.nodePick = !shut() && saveOn() && !!card().querySelector('.node-row.picked') && ruleDraft.target === before;
      document.querySelector('#tp-save button').click();
      out.node = ruleDraft.target.startsWith('node:') && shut();
      document.querySelector('#rf-body .tgt-row').click();
      out.nodeOpen = card().classList.contains('open') && !!card().querySelector('.node-row.picked') && !saveOn();
      const kept = ruleDraft.target;
      card().querySelector('.node-row.picked').click();   // deselect: Save bar with the reset warning
      out.resetWarn = saveOn() && document.getElementById('tp-save').classList.contains('reset');
      card().querySelector('.node-row[data-t="' + kept + '"]').click();   // the original again: bar hides
      out.repick = !saveOn();
      card().querySelector('.node-row.picked').click();
      closeSheet('target');   // closed without Save
      out.closeKeeps = ruleDraft.target === kept;
      out.row = /node/.test(document.querySelector('#rf-body .tgt-row').textContent);
      out.fbDefault = /Default: Main flow/.test(document.getElementById('rf-body').textContent);
      [...document.querySelectorAll('#rf-fallback button')].find(b => b.textContent === 'Direct').click();
      out.fb = ruleDraft.fallback === 'direct';
      closeSheet('ruleform');
      const r2 = rulesData.r2, keep = r2.target, keepFb = r2.fallback;
      r2.target = 'src:src2'; r2.fallback = 'default'; sourcesData.src2.enabled = false; quickCfg.fallback = 'block'; renderRules();
      out.down = /down → Block/.test(document.querySelector('.rule-row[data-id=r2]').textContent);
      sourcesData.src2.enabled = true; r2.target = keep; r2.fallback = keepFb; quickCfg.fallback = 'main'; renderRules(); renderAll();
      closeSheet('rules');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('rule form: Fallback block (like the app dialog) on Proxy with the main flow, inert on Direct, own Via, stable height, JSON keeps fallbackTarget, plan emits the target id', async () => {
    const r = await page.evaluate(() => {
      const out = {}, body = () => document.getElementById('rf-body'), h = () => body().scrollHeight, q = s => body().querySelector(s);
      openRules(); openRuleForm('r1'); ruleDraft.action = 'proxy'; ruleDraft.target = ''; ruleDraft.fallback = 'default'; renderRuleForm();
      out.present = !!q('#rf-fallback') && [...body().querySelectorAll('#rf-fallback button')].map(b => b.textContent).join() === 'Default,Proxy,Direct,Block'
        && !q('.aa-fb').classList.contains('aa-inert') && !!q('.rf-fb-hint');
      out.viaInert = q('.aa-fb-via').classList.contains('aa-inert');
      const h0 = h();
      [...body().querySelectorAll('#rf-fallback button')][1].click();
      out.viaOn = !q('.aa-fb-via').classList.contains('aa-inert') && /Main flow/.test(q('.aa-fb-via').textContent) && ruleDraft.fallback === 'main';
      out.sameH1 = h() === h0;
      q('.aa-fb-via').click();   // picker: Main flow first, the rule's own Via left out
      out.picker = document.getElementById('sh-target').classList.contains('open') && !!document.querySelector('#tp-body .tp-card');
      document.querySelector('#tp-body .tp-card[data-t="src:src2"] .src-head .conn-state').click();
      document.querySelector('#tp-save button').click();
      out.picked = ruleDraft.fallbackTarget === 'src:src2' && /src:src2|\S/.test(q('.aa-fb-via').textContent) && q('.aa-fb-via').textContent.indexOf('Main flow') < 0;
      out.sameH2 = h() === h0;
      // JSON round-trip keeps fallbackTarget
      setRfTab('json'); setRfTab('form');
      out.json = ruleDraft.fallback === 'main' && ruleDraft.fallbackTarget === 'src:src2';
      // the plan: a main-flow rule sends the target id and names the target
      const keep = JSON.stringify(rulesData.r1);
      saveRuleForm();
      const pr = routingPlan().rules.find(x => x.id === 'r1');
      out.plan = !!pr && pr.target === '' && pr.fallback === 'src:src2' && 'src:src2' in routingPlan().targets;
      // Direct: the block stays in place, dimmed and inert
      openRuleForm('r1'); ruleDraft.action = 'direct'; renderRuleForm();
      out.inert = q('.aa-fb').classList.contains('aa-inert') && q('.aa-fb-via').classList.contains('aa-inert') && [...body().querySelectorAll('#rf-fallback button')].every(b => b.disabled);
      out.sameH3 = Math.abs(h() - h0) <= 2;
      saveRuleForm();
      out.reset = rulesData.r1.fallback === 'default' && rulesData.r1.fallbackTarget === '';
      rulesData.r1 = JSON.parse(keep); renderRules(); closeSheet('rules');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('rules: services are a dropdown — add from the built-in list, switch VPN / Direct, remove', async () => {
    await seedServices(page);
    const r = await page.evaluate(() => {
      const out = {}, rows = () => [...document.querySelectorAll('.svc-row')].map(e => e.dataset.svc);
      openRules(); svcOpen = false; renderRules();
      out.closed = !rows().length && /added/.test(document.querySelector('.svc-head').textContent);
      document.querySelector('.svc-head').click();
      out.onlyAdded = rows().length && rows().every(k => quickCfg.services[k] !== 'default');
      document.querySelector('.svc-add-btn').click();
      const k = SERVICES.find(([key]) => quickCfg.services[key] === 'default')[0];
      [...document.querySelectorAll('.svc-add .chip')].find(c => c.textContent === SERVICES.find(s => s[0] === k)[1]).click();
      out.added = quickCfg.services[k] === 'vpn' && rows().includes(k);
      [...document.querySelectorAll(`.svc-row[data-svc=${k}] .seg3 button`)].find(b => b.textContent === 'Direct').click();
      out.direct = quickCfg.services[k] === 'direct';
      document.querySelector(`.svc-row[data-svc=${k}] .svc-del`).click();
      out.removed = quickCfg.services[k] === 'default' && !rows().includes(k);
      svcOpen = false; closeSheet('rules');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('services and per-app routing know about each other', async () => {
    await seedServices(page);
    const r = await page.evaluate(() => {
      const out = {}, keepT = quickCfg.services.telegram, keepA = appRules['org.telegram.messenger'];
      quickCfg.services.telegram = 'vpn'; appRules['org.telegram.messenger'] = appNormalize({ act: 'direct' });
      openRules(); svcOpen = true; renderRules();
      out.svcHint = /App: Direct/.test(document.querySelector('.svc-row[data-svc=telegram]').textContent);
      delete appRules['org.telegram.messenger']; openApps(); appFilter = 'user'; renderApps();
      out.appRow = /VPN · service/.test(document.querySelector('.app-row[data-pkg="org.telegram.messenger"] .app-state').textContent);
      openAppAct('org.telegram.messenger');
      out.dialog = /Telegram service: VPN/.test(document.getElementById('aa-body').textContent);
      closeSheet('appact'); closeSheet('apps'); closeSheet('rules'); svcOpen = false;
      quickCfg.services.telegram = keepT; if (keepA) appRules['org.telegram.messenger'] = keepA; renderRules();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('themes change colours only, not layout', async () => {
    const boxes = () => page.evaluate(() => [...document.querySelectorAll('.view.active *')].map(e => { const r = e.getBoundingClientRect(); return [r.x, r.y, r.width, r.height].map(Math.round).join(); }).join('|'));
    for (const t of ['home', 'nodes', 'settings']) {
      await tab(page, t);
      const base = (await page.evaluate(() => applyTheme('original')), await boxes());
      for (const th of ['karing', 'github']) {
        await page.evaluate(th => applyTheme(th), th);
        expect(await page.evaluate(() => document.documentElement.dataset.theme) === th, 'data-theme not set');
        expect(base === await boxes(), `${t}: layout differs in ${th}`);
      }
    }
    await page.evaluate(() => applyTheme('original'));
  });

  await check('no errors during the run', async () => expect(!page.errors.length, page.errors.join(' | ')));

  /* ── Back button (phone/browser/Esc): 60-sheets.js — sheetStack, justClosed,
     syncBackHistory, goBack, popstate, Esc. Each case gets its own fresh page so the
     history depth starts clean. */

  await check('back: Nodes → Add → Subscription unwinds one level at a time', async () => {
    const p = await openPage(browser);
    await tab(p, 'nodes');
    await p.evaluate(() => openNodesAdd());
    await p.click('#sh-addmenu .menu-row >> nth=0');   // Subscription: closeSheet('addmenu');openSrcForm()
    expect(await p.isVisible('#sh-srcform'), 'srcform did not open');

    await backAndSettle(p);
    expect(await p.isVisible('#sh-addmenu') && !(await p.isVisible('#sh-srcform')), 'back #1: addmenu should reopen, srcform should close');

    await backAndSettle(p);
    expect(!(await p.isVisible('#sh-addmenu')) && await p.evaluate(() => activeTab()) === 'nodes', 'back #2: sheet should close, tab stays on nodes');

    await backAndSettle(p);
    expect(await p.evaluate(() => activeTab()) === 'home', 'back #3: should land on Home');
    await p.close();
  });

  await check('back: a sheet nested on top of Rules closes alone, Rules stays open', async () => {
    const p = await openPage(browser);
    await p.evaluate(() => { openRules(); openRuleForm('r2'); });
    await preBack(p);
    expect(await p.isVisible('#sh-ruleform') && await p.isVisible('#sh-rules'), 'both sheets should be open first');

    await backAndSettle(p);
    expect(!(await p.isVisible('#sh-ruleform')) && await p.isVisible('#sh-rules'), 'back should close only ruleform and keep rules open');
    await p.close();
  });

  await check('back: a replaced actions sheet is restored with its own title and rows', async () => {
    const p = await openPage(browser);
    await tab(p, 'nodes');
    const nid = await p.evaluate(() => sourcesData.src3.nodes[0].id);
    await p.evaluate(nid => openNodeActions('src3', nid), nid);
    const title0 = await p.textContent('#actionsTitle');
    await p.click('#actions-body .menu-row.danger');   // Delete server -> confirmDeleteNode -> openActions() again, same sheet
    const title1 = await p.textContent('#actionsTitle');
    expect(title1 !== title0, 'the delete confirm did not replace the actions body');

    await backAndSettle(p);
    expect(await p.isVisible('#sh-actions'), 'actions sheet did not reopen on back');
    expect(await p.textContent('#actionsTitle') === title0, `title not restored: got "${await p.textContent('#actionsTitle')}", expected "${title0}"`);
    await p.close();
  });

  await check('back: closing a sheet with × does not leave an extra history level', async () => {
    const p = await openPage(browser);
    await tab(p, 'nodes');
    await p.evaluate(() => openNodesAdd());
    await preBack(p);
    const before = await p.evaluate(() => histDepth);
    await p.click('#sh-addmenu .sheet-close');
    await preBack(p);
    const after = await p.evaluate(() => ({ depth: histDepth, want: backDepth(), open: sheetStack.length, tab: activeTab() }));
    expect(after.open === 0 && after.tab === 'nodes', '×-close did not clean up the sheet stack: ' + JSON.stringify(after));
    expect(after.depth === after.want, `histDepth ${after.depth} out of sync with backDepth() ${after.want} after ×-close`);
    expect(after.depth === before - 1, `expected histDepth to drop by exactly 1 (${before} -> ${after.depth})`);

    await backAndSettle(p);   // the one back a ×-close owes should not be swallowed
    expect(await p.evaluate(() => activeTab()) === 'home', 'the back after a ×-close was swallowed');
    await p.close();
  });

  await check('back: Esc closes the top sheet', async () => {
    const p = await openPage(browser);
    await tab(p, 'nodes');
    await p.evaluate(() => openNodesAdd());
    await preBack(p);
    await p.keyboard.press('Escape');
    await p.waitForTimeout(400);
    expect(!(await p.isVisible('#sh-addmenu')), 'Esc did not close the sheet');
    await p.close();
  });

  // Live mode (the page served by core/bin/jormd.dart) starts from an empty state: every
  // screen must render with nothing added. No core here, so /api calls only toast.
  await check('live mode: mock off the file page; an empty state renders everywhere', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const out = { mockHere: backend.live === false };
      window.JORMD = true; liveInit();
      out.empty = !sourceOrder.length && !connectOrder.length && !connected;
      renderAll(); openProfiles(); closeSheet('profiles');
      switchTab('nodes'); setNodesTab('profiles'); setNodesTab('simple'); switchTab('settings'); switchTab('rules'); switchTab('home');
      await wait(300);
      try { livePlan(); out.plan = false; } catch (e) { out.plan = /Nothing to connect/.test(e.message); }
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('ping cache: one result per server variant; stored server-keyed ones migrate only when unambiguous', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      const s = sourcesData[sourceOrder[0]], a = s.nodes[0], b = Object.assign({}, a, { id: a.id + '-v2' });
      s.nodes.push(b);   // another variant (other SNI…) of the same server
      setPing(a, 50); setPing(b, -1);
      const out = { separate: ping(a) === 50 && ping(b) === -1 };
      const all = Object.values(sourcesData).flatMap(x => x.nodes.concat(x.gone || []));
      const c = all.find(n => all.filter(m => serverKey(m) === serverKey(n)).length === 1);
      restorePings([[serverKey(a), { ms: 70, at: Date.now() }], [serverKey(c), { ms: -1, at: Date.now() }], [pingKey(b), { ms: 33, at: Date.now(), fails: 0 }]]);
      out.ambiguous = ping(a) === null;
      out.single = ping(c) === -1 && pingEntry(c).fails === 1;
      out.newKey = ping(b) === 33;
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('live plan: every Auto entry is a route; pings, the core moving and Auto mode settings leave it be (settings go to the core live), Manual is a new one', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      setAutoConnect(true); autoCfg.standby = 0;   // no spares: still every Auto entry
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { n.outbound = n.outbound || { type: 'direct' }; n.unsupported = false; }));
      const order = autoOrder(), plan = livePlan(order[1]);
      const out = { enough: order.length >= 5,
        routes: plan.routes.map(x => x.id).join() === order.join() && plan.current === 1 && plan.auto.failAfter === autoCfg.failAfter && plan.auto.retryPause === 0.5 };
      live.anchor = order[1];
      // every server measured and alive first: a leftover in-flight / failed ping of an earlier check would move a Priority pick
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => setPing(n, 100)));
      const sig = planSig();
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => setPing(n, Math.round(Math.random() * 300))));
      coreRoute = { id: order[0], server: null, entryServer: null };
      out.stable = planSig() === sig;
      // Settings → Auto mode: no reconnect, the running core gets it once
      const sent = [], ab = backend.autoSettings, st = [live.ready, live.planSig, connected];
      backend.autoSettings = a => { sent.push(a); return Promise.resolve(); };
      live.ready = true; live.planSig = sig; connected = true; live.autoSig = JSON.stringify(planAuto());
      autoCfg.retryPause = 2; autoCfg.returnTo = 'never';
      out.autoNoSig = planSig() === sig;
      liveSyncAuto(); liveSyncAuto();
      out.autoSent = sent.length === 1 && sent[0].retryPause === 2 && sent[0].returnTo === 'never';
      autoCfg.retryPause = 0.5; autoCfg.returnTo = 'always';
      backend.autoSettings = ab; [live.ready, live.planSig, connected] = st;
      setAutoConnect(false);
      out.manual = planSig() !== sig && livePlan().routes.map(x => x.id).join() === activeConnectId && activeConnectId === order[0];
      coreRoute = null;
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
    await p.close();
  });

  await check('live Auto: dock and Route show the core\'s entry and server, its checks reach the ping cache (what the core did comes as events, see Events)', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      setAutoConnect(true);
      const order = autoOrder(), id = order.find(x => !chainsData[x] && unitPickRefs(x).length > 1);
      const refs = unitPickRefs(id), last = refs[refs.length - 1], now = Date.now() + 1000;
      pingCache.delete(pingKey(refs[0].node));   // the launch ping may have it in flight (that one would win)
      connected = true;
      const st = (auto, extra) => Object.assign({ connected: true, restarts: 0, recovering: null, auto }, extra);
      const auto = (switches, extra) => Object.assign({ now: id, server: refKey(last), entryServer: null, switches, noNet: false, unstable: 0,
        lastSwitch: { from: order[0], to: id, reason: 'failover', at: now }, routes: [{ id: order[0] }, { id }],
        members: [{ key: refKey(refs[0]), ms: -1, fails: 3, oks: 0, at: now }] }, extra);
      liveAutoStatus(st(auto(1)));
      const out = { entry: effectiveConnectId() === id && effectiveConnectId(true) !== undefined,
        server: unitNode(id) === last.node,
        dock: document.getElementById('profModeDetail').textContent.includes(last.node.name) && document.getElementById('profCardName').textContent === connectEntry(id).name,
        merged: ping(refs[0].node) === -1 && pingEntry(refs[0].node).fails === 3 };
      liveAutoStatus(null);
      out.cleared = coreRoute === null;
      connected = false;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('Notifications: toggles gate background events only; master off silences all; own-action failures always toast; state saved and old genCfg toggles migrate', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const out = {}, toasts = []; const t0 = window.toast; window.toast = m => toasts.push(m);
      // the screen: master + 9 toggles, none left in General
      switchTab('settings'); openSheet('setnotif');
      out.rows = document.querySelectorAll('#notif-settings .set-row').length === 1 + NOTIF_KEYS.length + 1;   // + Pop-ups on PC
      out.desktop = notifCfg.desktopStyle === 'own' && document.querySelector('#notif-settings [data-key="desktopStyle"] .chip.active').textContent === 'Own pop-ups';
      setNotifCfg('desktopStyle', 'system');
      out.desktop2 = notifCfg.desktopStyle === 'system' && document.querySelector('#notif-settings [data-key="desktopStyle"] .chip.active').textContent === 'System notifications';
      setNotifCfg('desktopStyle', 'own');
      out.noGeneral = !document.querySelector('#general-settings [data-key="statusNotif"]') && !('statusNotif' in genCfg) && !('switchNotif' in genCfg);
      out.sub = /^\d of \d on$/.test(document.getElementById('setNotifSub').textContent);
      setNotifCfg('enabled', false);
      out.subOff = document.getElementById('setNotifSub').textContent === 'Off' && getComputedStyle(document.getElementById('notif-groups')).opacity === '0.4';
      setNotifCfg('enabled', true);
      // background events
      notifCfg.subFailed = false; toasts.length = 0;
      notify('subFailed', 'bg');
      out.bgOff = !toasts.length;
      notifCfg.subFailed = true; notify('subFailed', 'bg');
      out.bgOn = toasts.length === 1;
      notifCfg.enabled = false; toasts.length = 0;
      Object.keys(notifCfg).forEach(k => notify(k, 'x'));
      out.masterOff = !toasts.length;
      notifCfg.enabled = true;
      // the user's own manual update failing still toasts with subFailed off; a timer one does not
      const sid = sourceOrder.find(id => sourcesData[id].kind === 'sub'), s = sourcesData[sid], url0 = s.url;
      s.url = 'https://example.test/fail'; notifCfg.subFailed = false; toasts.length = 0;
      updateSource(sid);
      await new Promise(r => setTimeout(r, 2500));
      out.manual = toasts.some(m => /Update of .* failed/.test(m));
      toasts.length = 0; updateSource(sid, { background: true });
      await new Promise(r => setTimeout(r, 2500));
      out.timerQuiet = !toasts.length;
      notifCfg.subFailed = true; updateSource(sid, { background: true });
      await new Promise(r => setTimeout(r, 2500));
      out.timerOn = toasts.some(m => /update failed/.test(m));
      s.url = url0; window.toast = t0;
      // saved with the snapshot; an old one migrates
      out.saved = 'notifCfg' in liveSnapshot();
      const keep = Object.assign({}, notifCfg);
      liveApply(Object.assign(liveSnapshot(), { notifCfg: undefined, genCfg: Object.assign({}, genCfg, { statusNotif: false, switchNotif: false }) }));
      out.migrated = !notifCfg.status && !notifCfg.autoSwitch && !('statusNotif' in genCfg);
      Object.assign(notifCfg, keep);
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  // The blocked-site card: two named rows (no raw ids), Create rule prefilled; Open / In raw log leave the journal and Back returns to the event.
  await check('journal: blocked card (two rows, names), Create rule, Open → Back and In raw log → Back return to Logs → Events at the entry', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs'); await p.waitForTimeout(500);
    const info = await p.evaluate(async () => {
      const [a, b] = autoOrder(), e = mockEventAdd('site', 'blocked', 'warn', { host: 'card.example.com', dest: 'card.example.com:443', entry: a, via: b }, { raw: 'card.example.com:443 does not open' });
      await pollEvents();
      const row = [...document.querySelectorAll('#evList .ev-row.cat-site')].find(r => r.dataset.ids.split(',').includes(String(e.id)));
      const rows = row ? [...row.querySelectorAll('.ev-via')] : [];
      return { id: e.id, n: rows.length, names: rows.map(r => r.querySelector('.ev-via-name').firstChild.textContent), opens: rows.map(r => !!r.querySelector('.ev-act')),
        want: [connectEntry(a).name, connectEntry(b).name], btns: [...row.querySelectorAll('.ev-acts .ev-act')].map(x => x.textContent) };
    });
    expect(info.n === 2 && info.names.join() === info.want.join() && info.opens.every(Boolean), 'two rows with names ' + JSON.stringify(info));
    expect(info.btns.join() === 'Create rule,In raw log', 'buttons ' + info.btns.join());
    await p.evaluate(id => evAct('rule', id), info.id); await p.waitForTimeout(300);
    expect(await p.evaluate(() => document.getElementById('sh-ruleform').classList.contains('open') && ruleDraft.groups.domain && JSON.stringify(ruleDraft.groups.domain.v.domain) === '["card.example.com"]'), 'Create rule prefilled');
    await p.evaluate(() => closeSheet('ruleform')); await p.waitForTimeout(400);
    const inView = id => p.evaluate(id => {
      const row = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id)));
      const b = row && row.getBoundingClientRect(), s = document.getElementById('evScroll').getBoundingClientRect();
      return !!row && logsOpen() && logTab === 'events' && row.classList.contains('open') && b.top >= s.top - 1 && b.bottom <= s.bottom + 1;
    }, id);
    // Open on the via row → Nodes; Back → the journal at the event
    await p.evaluate(id => { [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id))).querySelectorAll('.ev-via .ev-act')[1].click(); }, info.id);
    await p.waitForTimeout(400);
    expect(await p.evaluate(() => activeTab() === 'nodes'), 'Open goes to Nodes');
    await backAndSettle(p);
    expect(await inView(info.id), 'Open → Back returns to the event');
    await p.evaluate(() => { const r = document.querySelector('#evList .ev-row.open'); if (r) r.classList.remove('open'); });
    await p.evaluate(id => [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id))).querySelector('.ev-acts .ev-act:last-child').click(), info.id);
    await p.waitForTimeout(700);
    expect(await p.evaluate(() => logTab === 'raw'), 'In raw log shows Raw');
    await backAndSettle(p);
    expect(await inView(info.id), 'In raw log → Back returns to the event');
    await p.evaluate(() => { evState.open.clear(); });
    await backAndSettle(p);
    expect(await p.evaluate(() => activeTab() === 'home'), 'a second Back goes Home');
    await p.close();
  });

  // The unreachable-site card: the entry in use and every route tried as named ⚠️ rows; a muted line when none was tried; no Create rule; In raw log → Back returns.
  await check('journal: unreachable card (named rows, a muted line when no route was tried, no Create rule), In raw log → Back returns to the event', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs'); await p.waitForTimeout(500);
    const info = await p.evaluate(async () => {
      const [a, b] = autoOrder(), data = (host, more) => ({ host, dest: host + ':443', entry: a, route: a, ...more });
      const e1 = mockEventAdd('site', 'unreachable', 'warn', data('dead.example.com', { tried: [{ entry: b }, { entry: a }] }), { raw: 'dead.example.com:443 does not open through any route' });
      const e0 = mockEventAdd('site', 'unreachable', 'warn', data('none.example.com', { tried: [] }), { raw: 'none.example.com:443 does not open' });
      const eo = mockEventAdd('site', 'unreachable', 'warn', data('off.example.com', { tried: [], retries: 'off' }), { raw: 'off.example.com:443 does not open' });
      await pollEvents();
      const rowOf = e => [...document.querySelectorAll('#evList .ev-row.cat-site')].find(r => r.dataset.ids.split(',').includes(String(e.id)));
      const read = e => { const r = rowOf(e); return { rows: [...r.querySelectorAll('.ev-via')].map(x => x.querySelector('.ev-via-name').firstChild.textContent), ico: [...r.querySelectorAll('.ev-via-ico')].map(x => x.textContent).join(''),
        opens: [...r.querySelectorAll('.ev-via')].every(x => !!x.querySelector('.ev-act')), note: (r.querySelector('.ev-via-note') || {}).textContent || null,
        btns: [...r.querySelectorAll('.ev-acts .ev-act')].map(x => x.textContent), title: r.querySelector('.ev-title').textContent, more: r.querySelector('.ev-more').textContent }; };
      return { id: e1.id, a: connectEntry(a).name, b: connectEntry(b).name, one: read(e1), none: read(e0), off: read(eo), text: evText(e1), textNone: evText(e0), ids: [a, b] };
    });
    const { one, none, off } = info;
    expect(one.rows.length === 3 && one.rows[0] === info.a && one.rows[1] === info.b && one.ico === '⚠️⚠️⚠️' && one.opens && one.note === null, 'rows ' + JSON.stringify(one));
    expect(one.title === 'dead.example.com does not open' && one.btns.join() === 'In raw log', 'title / buttons ' + one.title + ' | ' + one.btns.join());
    expect(!one.more.includes('{') && one.more.includes('Also tried') && one.more.includes(info.b), 'fields in words ' + one.more);
    expect(none.rows.length === 1 && none.note === 'No other working route to try' && off.note === 'Retries through other routes are off', 'muted lines ' + none.note + ' | ' + off.note);
    expect(info.text.includes('dead.example.com does not open') && info.text.includes('⚠️ ' + info.b) && info.textNone.includes('No other working route to try'), 'notification / export text ' + info.text);
    const inView = id => p.evaluate(id => {
      const row = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id)));
      const b = row && row.getBoundingClientRect(), s = document.getElementById('evScroll').getBoundingClientRect();
      return !!row && logsOpen() && logTab === 'events' && row.classList.contains('open') && b.top >= s.top - 1 && b.bottom <= s.bottom + 1;
    }, id);
    await p.evaluate(id => [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id))).querySelector('.ev-acts .ev-act:last-child').click(), info.id);
    await p.waitForTimeout(700);
    expect(await p.evaluate(() => logTab === 'raw'), 'In raw log shows Raw');
    await backAndSettle(p);
    expect(await inView(info.id), 'In raw log → Back returns to the event');
    await p.evaluate(() => { evState.open.clear(); });
    await p.close();
  });

  // The "why" rows of the site cards (core: data.rule {kind, id, name} + data.process {name, path}): the rule's name, the app; a tap
  // opens that rule / app dialog / service or quick rule place / Route; Back returns to the entry. No rule = the main flow.
  await check('journal: site cards name the rule and the app (user rule, app, service, quick, main flow), a tap opens it, Back returns to the entry', async () => {
    const p = await openPage(browser);
    await seedServices(p);
    await tab(p, 'logs'); await p.waitForTimeout(500);
    const info = await p.evaluate(async () => {
      const [a, b] = autoOrder(), base = (host, more) => ({ host, dest: host + ':443', entry: a, route: a, ...more });
      const add = (type, host, more) => mockEventAdd('site', type, 'warn', base(host, more), { raw: host + ':443 does not open' });
      const evs = {
        user: add('blocked', 'why-user.example.com', { via: b, rule: { kind: 'user', id: 'r2', name: 'old name' }, process: { name: 'curl.exe', path: 'C:\\x\\curl.exe' } }),
        gone: add('blocked', 'why-gone.example.com', { via: b, rule: { kind: 'user', id: 'r99', name: 'Deleted rule' } }),
        app: add('unreachable', 'why-app.example.com', { tried: [], rule: { kind: 'app', id: 'com.discord', name: 'Discord' }, process: { name: 'Discord.exe' } }),
        service: add('blocked', 'why-svc.example.com', { via: b, rule: { kind: 'service', id: 'telegram', name: 'Telegram' } }),
        quick: add('unreachable', 'why-quick.example.com', { tried: [{ entry: b }], rule: { kind: 'quick', id: 'ads', name: 'Block ads' } }),
        final: add('unreachable', 'why-final.example.com', { tried: [{ entry: b }], rule: { kind: 'final' }, process: { name: 'Telegram.exe' } }),
        unknown: add('blocked', 'why-raw.example.com', { via: b, rule: { kind: 'unknown', text: 'domain_suffix=raw.example' } }),
        none: add('blocked', 'why-none.example.com', { via: b }),
      };
      await pollEvents();
      const rowOf = e => [...document.querySelectorAll('#evList .ev-row.cat-site')].find(r => r.dataset.ids.split(',').includes(String(e.id)));
      const read = e => { const r = rowOf(e); return { rows: [...r.querySelectorAll('.ev-why')].map(x => [x.querySelector('.ev-why-k').textContent, x.querySelector('.ev-via-name').textContent, x.classList.contains('go')]),
        first: r.querySelector('.ev-vias > .ev-via').classList.contains('ev-why'), more: r.querySelector('.ev-more').textContent }; };
      const out = { ids: Object.fromEntries(Object.entries(evs).map(([k, e]) => [k, e.id])) };
      Object.keys(evs).forEach(k => { out[k] = read(evs[k]); });
      out.text = evText(evs.user); out.textFinal = evText(evs.final);
      return out;
    });
    const row = k => JSON.stringify(info[k].rows);
    expect(row('user') === JSON.stringify([['Rule', 'Discord voice', true], ['App', 'curl.exe', false]]) && info.user.first, 'user rule row (the live name, not the stored one) + app ' + row('user'));
    expect(row('gone') === JSON.stringify([['Rule', 'Deleted rule', false]]), 'a deleted rule is named but not a link ' + row('gone'));
    expect(row('app') === JSON.stringify([['App', 'Discord', true]]), 'a per-app rule: one App row, no process row ' + row('app'));
    expect(row('service') === JSON.stringify([['Service', 'Telegram', true]]) && row('quick') === JSON.stringify([['Rule', 'Block ads', true]]), 'service / quick rows ' + row('service') + row('quick'));
    expect(row('final') === JSON.stringify([['Rule', 'None — main flow', true], ['App', 'Telegram', true]]), 'no rule = the main flow ' + row('final'));
    expect(row('unknown') === JSON.stringify([['Rule', 'domain_suffix=raw.example', false]]) && info.none.rows.length === 0, 'unknown rule shows its text, an event without the data has no row ' + row('unknown'));
    expect(info.user.more.includes('Discord voice') && info.user.more.includes('curl.exe') && !info.user.more.includes('{') && !info.user.more.includes('[object'), 'fields in words ' + info.user.more);
    expect(info.text.includes('Rule Discord voice') && info.text.includes('App curl.exe') && info.textFinal.includes('No rule, main flow'), 'notification / export text ' + info.text + ' | ' + info.textFinal);
    const inView = id => p.evaluate(id => {
      const row = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id)));
      const b = row && row.getBoundingClientRect(), s = document.getElementById('evScroll').getBoundingClientRect();
      return !!row && logsOpen() && logTab === 'events' && row.classList.contains('open') && b.top >= s.top - 1 && b.bottom <= s.bottom + 1;
    }, id);
    const tapFirst = id => p.evaluate(id => { const r = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id))); r.querySelector('.ev-why.go').click(); }, id);
    const open = sheet => p.evaluate(s => document.getElementById('sh-' + s).classList.contains('open'), sheet);
    const cases = [
      ['user', async () => (await open('ruleform')) && await p.evaluate(() => ruleEditing === 'r2'), 'the rule form of that rule'],
      ['app', async () => (await open('appact')) && await p.evaluate(() => appEditing === 'com.discord'), 'the per-app dialog'],
      ['service', async () => (await open('rules')) && await p.evaluate(() => !!document.querySelector('#rules-body .svc-row[data-svc="telegram"]')), 'Rules with the service row'],
      ['quick', async () => (await open('rules')) && await p.evaluate(() => !!document.querySelector('#rules-body [data-quick="ads"]')), 'Rules with the quick rule'],
      ['final', async () => await open('profiles'), 'Route'],
    ];
    for (const [k, ok, what] of cases) {
      await p.evaluate(() => { const r = document.querySelector('#evList .ev-row.open'); if (r) r.classList.remove('open'); evState.open.clear(); });
      await tapFirst(info.ids[k]); await p.waitForTimeout(500);
      expect(await ok(), k + ': a tap opens ' + what);
      await backAndSettle(p);
      expect(await inView(info.ids[k]), k + ': Back returns to the entry');
    }
    await p.evaluate(() => { evState.open.clear(); });
    expect(!p.errors.length, p.errors.join(' | '));
    await p.close();
  });

  // A conflict in the "why" block: an app with its own route and a rule that both could send the site. The side sing-box applied says
  // "applied", the other is muted "overridden by …"; both keep their links. Judged with today's settings (evWhyRows, rulesCatching).
  await check('journal: why block shows both sides of an app / rule conflict (applied, overridden by rule / by app), both link, a plain app has no mark, Back returns', async () => {
    const p = await openPage(browser);
    await seedServices(p);
    await tab(p, 'logs'); await p.waitForTimeout(500);
    const info = await p.evaluate(async () => {
      const [a, b] = autoOrder(), base = (host, more) => ({ host, dest: host + ':443', entry: a, route: a, ...more });
      const add = (host, more) => mockEventAdd('site', 'blocked', 'warn', base(host, { via: b, ...more }), { raw: host + ':443 does not open' });
      const evs = {
        byRule: add('why-ovr.example.com', { rule: { kind: 'user', id: 'r2', name: 'Discord voice' }, process: { name: 'Telegram.exe', path: 'C:\\t\\Telegram.exe' } }),
        byApp: add('wiki.corp.local', { rule: { kind: 'app', id: 'com.discord', name: 'Discord' }, process: { name: 'Discord.exe' } }),
        svc: add('t.me', { rule: { kind: 'app', id: 'com.discord', name: 'Discord' }, process: { name: 'Discord.exe' } }),
        clean: add('unrelated.example', { rule: { kind: 'app', id: 'com.discord', name: 'Discord' }, process: { name: 'Discord.exe' } }),
        plain: add('why-plain.example.com', { rule: { kind: 'user', id: 'r1', name: 'Work network' }, process: { name: 'Spotify.exe' } }),
        unlisted: add('why-unl.example.com', { rule: { kind: 'user', id: 'r1', name: 'Work network' }, process: { name: 'curl.exe' } }),
      };
      await pollEvents();
      const rowOf = e => [...document.querySelectorAll('#evList .ev-row.cat-site')].find(r => r.dataset.ids.split(',').includes(String(e.id)));
      const read = e => [...rowOf(e).querySelectorAll('.ev-why')].map(x => ({ k: x.querySelector('.ev-why-k').textContent, n: x.querySelector('.ev-via-name').textContent,
        sub: (x.querySelector('.ev-why-sub') || {}).textContent || '', dim: x.classList.contains('dim'), go: x.classList.contains('go') }));
      const out = { ids: Object.fromEntries(Object.entries(evs).map(([k, e]) => [k, e.id])) };
      Object.keys(evs).forEach(k => { out[k] = read(evs[k]); });
      out.catching = JSON.stringify(rulesCatching('wiki.corp.local', 443)) + JSON.stringify(rulesCatching('discord.gg', 443)) + JSON.stringify(rulesCatching('10.1.2.3', 443));
      return out;
    });
    const j = o => JSON.stringify(o);
    const br = info.byRule;
    expect(br.length === 2 && br[0].n === 'Discord voice' && /applied/.test(br[0].sub) && !br[0].dim && br[1].k === 'App' && br[1].n === 'Telegram' && br[1].dim && br[1].go
      && /^Proxy · overridden by rule$/.test(br[1].sub), 'app overridden by the rule ' + j(br));
    const ba = info.byApp;
    expect(ba.length === 2 && ba[0].k === 'App' && ba[0].n === 'Discord' && /applied/.test(ba[0].sub) && ba[1].k === 'Rule' && ba[1].n === 'Work network' && ba[1].dim && ba[1].go
      && /^Direct · overridden by app$/.test(ba[1].sub), 'rule overridden by the app ' + j(ba));
    expect(info.svc.length === 2 && info.svc[1].k === 'Service' && info.svc[1].n === 'Telegram' && info.svc[1].sub === 'VPN · overridden by app', 'service overridden by the app ' + j(info.svc));
    expect(info.clean.length === 1 && !info.clean[0].sub.includes('applied'), 'no other rule matches: no conflict, no marks ' + j(info.clean));
    expect(info.plain.length === 2 && info.plain[1].n === 'Spotify' && !info.plain[1].dim && !/overridden|applied/.test(info.plain[0].sub + info.plain[1].sub), 'an app with no route of its own: no mark ' + j(info.plain));
    expect(info.unlisted.length === 2 && info.unlisted[1].n === 'curl.exe' && !info.unlisted[1].go, 'an app not in the list is just named ' + j(info.unlisted));
    expect(info.catching === '[{"kind":"user","id":"r1"}][][]', 'rulesCatching: judges names, skips what it cannot (a network rule, an IP) ' + info.catching);
    const inView = id => p.evaluate(id => {
      const row = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id)));
      const b = row && row.getBoundingClientRect(), s = document.getElementById('evScroll').getBoundingClientRect();
      return !!row && logsOpen() && logTab === 'events' && row.classList.contains('open') && b.top >= s.top - 1 && b.bottom <= s.bottom + 1;
    }, id);
    const tap = (id, i) => p.evaluate(([id, i]) => { const r = [...document.querySelectorAll('#evList .ev-row')].find(r => r.dataset.ids.split(',').includes(String(id))); r.querySelectorAll('.ev-why')[i].click(); }, [id, i]);
    const open = sheet => p.evaluate(s => document.getElementById('sh-' + s).classList.contains('open'), sheet);
    for (const [k, i, ok, what] of [
      ['byRule', 1, async () => (await open('appact')) && await p.evaluate(() => appEditing === 'org.telegram.messenger'), 'the app dialog of the overridden app'],
      ['byRule', 0, async () => (await open('ruleform')) && await p.evaluate(() => ruleEditing === 'r2'), 'the applied rule'],
      ['byApp', 1, async () => (await open('ruleform')) && await p.evaluate(() => ruleEditing === 'r1'), 'the rule that lost'],
      ['svc', 1, async () => (await open('rules')) && await p.evaluate(() => !!document.querySelector('#rules-body .svc-row[data-svc="telegram"]')), 'Rules at the service that lost'],
    ]) {
      await p.evaluate(() => { const r = document.querySelector('#evList .ev-row.open'); if (r) r.classList.remove('open'); evState.open.clear(); });
      await tap(info.ids[k], i); await p.waitForTimeout(500);
      expect(await ok(), k + ' #' + i + ': a tap opens ' + what);
      await backAndSettle(p);
      expect(await inView(info.ids[k]), k + ' #' + i + ': Back returns to the entry');
    }
    await p.evaluate(() => { evState.open.clear(); });
    expect(!p.errors.length, p.errors.join(' | '));
    await p.close();
  });

  // The journal drives the background notifications (47-events.js → 58-notif.js): only events newer than the page's first look, not own, with their toggle on.
  await check('events → notifications: history never, a new one yes (toggle on, not own), a Rule button on a blocked site, a tap opens Logs at the event; sub/dead is posted by the UI', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const toasts = []; window.toast = (m, act, tap) => toasts.push({ m, act, tap });
      const order = autoOrder(), [a, b] = [order[0], order[1] || order[0]], now = Date.now(), wait = ms => new Promise(r => setTimeout(r, ms));
      const add = (cat, type, level, data, own) => { const e = mockEventAdd(cat, type, level, data, { own }); return pollEvents().then(() => e); };
      await pollEvents();
      const out = { history: !toasts.length && evState.list.length > 20 };   // the seeded history holds warnings and errors: silent
      await add('site', 'blocked', 'warn', { host: 'chat.example.com', dest: 'chat.example.com:443', entry: a, via: b });
      out.toast = toasts.length === 1 && toasts[0].m.includes('chat.example.com') && toasts[0].act && toasts[0].act.label === 'Create rule' && typeof toasts[0].tap === 'function';
      toasts[0].act.fn();
      // the core's `via` is a bare entry id: the rule's target is the prefixed one, resolves to a live entry (never "deleted …"), the host is an exact Domain
      out.rule = document.getElementById('sh-ruleform').classList.contains('open') && ruleDraft.action === 'proxy'
        && ruleDraft.target === entryTarget(b) && /^(profile|chain|src):/.test(ruleDraft.target)
        && !targetInfo(ruleDraft.target).gone && targetName(ruleDraft.target) === entryLabel(b)
        && JSON.stringify(ruleDraft.groups) === '{"domain":{"not":false,"v":{"domain":["chat.example.com"]}}}';
      out.targetRow = !/deleted/.test(document.getElementById('sh-ruleform').textContent);
      out.hostGroup = JSON.stringify([hostGroup('1.2.3.4').ip.v.ip_cidr, hostGroup('2001:db8::1').ip.v.ip_cidr, hostGroup('a.b.c').domain.v.domain]) === '[["1.2.3.4/32"],["2001:db8::1/128"],["a.b.c"]]';
      closeSheet('ruleform');
      notifCfg.blocked = false; toasts.length = 0;
      await add('site', 'blocked', 'warn', { host: 'x.test', dest: 'x.test:443', entry: a, via: b });
      out.off = !toasts.length;
      notifCfg.blocked = true;
      await add('auto', 'switched', 'info', { from: a, to: b, reason: 'failover' }, true);
      out.own = !toasts.length;
      const sw = await add('auto', 'switched', 'info', { from: a, to: b, reason: 'failover', fails: 3 });
      out.switch = toasts.length === 1 && toasts[0].m.includes(connectEntry(a).name) && /failed 3 checks/.test(toasts[0].m);
      notifCfg.enabled = false; toasts.length = 0;
      await add('core', 'crashed', 'error', { code: 1 });
      out.master = !toasts.length;
      notifCfg.enabled = true;
      // a tap on the toast: Logs → Events at that event
      toasts[0] = { tap: () => openEventInLogs(sw.id) };
      toasts[0].tap();
      await wait(200);
      out.tap = logsOpen() && logTab === 'events' && !!document.querySelector('#evList .ev-row.hit');
      // every tested server of a subscription fails while another source answers: sub/dead, once
      const sid = Object.keys(sourcesData).find(k => sourcesData[k].kind === 'sub' && sourcesData[k].nodes.length >= 2);
      const other = Object.keys(sourcesData).find(k => k !== sid && sourcesData[k].nodes.length);
      const mem = [...sourcesData[sid].nodes.slice(0, 2).map(n => ({ key: sid + '::' + n.id, ms: -1, fails: 3, oks: 0, at: now })),
        { key: other + '::' + sourcesData[other].nodes[0].id, ms: 80, fails: 0, oks: 3, at: now }];
      const st = { connected: true, restarts: 0, recovering: null, auto: { now: a, server: null, switches: 0, unstable: 0, blocked: 0, noNet: false, routes: [], members: mem } };
      toasts.length = 0;
      const dead0 = evState.list.filter(e => e.type === 'dead').length;
      liveAutoStatus(st); liveAutoStatus(st);
      await wait(300);
      out.srcDown = toasts.length === 1 && toasts[0].m.includes(sourcesData[sid].name) && /support/.test(toasts[0].m) && evState.list.filter(e => e.type === 'dead').length === dead0 + 1;
      liveAutoStatus(null);
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('Kill switch: turning it off while connected or blocked asks first; on / off while idle does not', async () => {
    const r = await page.evaluate(async () => {
      const out = {}, wait = ms => new Promise(r => setTimeout(r, ms)), was = connected;
      const sw = () => document.querySelector('#conn-settings [data-key="killSwitch"] .mini-toggle');
      const asked = () => document.getElementById('sh-actions').classList.contains('open');
      switchTab('settings'); openSheet('setconn');
      connected = false; connCfg.killSwitch = false; renderConnSettings();
      sw().click(); await wait(30);
      out.onFree = connCfg.killSwitch === true && !asked();
      sw().click(); await wait(30);
      out.offIdleFree = connCfg.killSwitch === false && !asked();
      connected = true; connCfg.killSwitch = true; renderConnSettings();
      sw().click(); await wait(30);
      out.asks = asked() && connCfg.killSwitch === true && /Turn the kill switch off/.test(document.getElementById('sh-actions').textContent);
      closeSheet('actions'); await wait(30);
      out.kept = connCfg.killSwitch === true;
      sw().click(); await wait(30);
      [...document.querySelectorAll('#sh-actions .menu-row')].find(e => /Turn it off/.test(e.textContent)).click(); await wait(30);
      out.off = connCfg.killSwitch === false;
      connected = was; closeSheet('setconn'); renderConnSettings();
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('Kill switch: sub-toggles only with it on, killWhileClosed needs autostart + autoconnect, downProxy row only with it off; saved; recovering is invisible; down keeps the power button on with the right buttons; release / retry; power tap while down disconnects; blocking plaque', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const out = {}, wait = ms => new Promise(r => setTimeout(r, ms)), toasts = []; const t0 = window.toast; window.toast = m => toasts.push(m);
      const has = k => !!document.querySelector(`#conn-settings [data-key="${k}"]`);
      switchTab('settings'); openSheet('setconn');
      out.off = has('killSwitch') && !has('killOnDisconnect') && !has('killWhileClosed') && has('downProxy') && connCfg.downProxy === 'remove';
      const dpTg = () => document.querySelector('#conn-settings [data-key="downProxy"] .mini-toggle');
      out.chipOn = dpTg().classList.contains('on');
      dpTg().click();
      out.chip = connCfg.downProxy === 'keep' && !dpTg().classList.contains('on');
      connCfg.killSwitch = true; renderConnSettings();
      out.on = !has('downProxy') && has('killOnDisconnect') && has('killWhileClosed');
      const wc = () => document.querySelector('#conn-settings [data-key="killWhileClosed"]');
      out.dim = wc().classList.contains('dim') && !wc().querySelector('.mini-toggle.on');
      wc().click(); await wait(50);
      const sheetOpen = () => document.getElementById('sh-actions').classList.contains('open');
      const act = t => [...document.querySelectorAll('#sh-actions .menu-row')].find(e => e.textContent.trim() === t);
      out.offer = sheetOpen() && !connCfg.killWhileClosed && /Keep blocking while closed/.test(document.getElementById('sh-actions').textContent);
      act('Turn on').click(); await wait(50);
      out.offerAll = !sheetOpen() && connCfg.killWhileClosed === true && genCfg.launchAtStartup === true && genCfg.connectOnLaunch === true;
      connCfg.killWhileClosed = false; renderConnSettings();
      out.enabled = !wc().classList.contains('dim');
      wc().querySelector('.mini-toggle').click(); await wait(50);
      out.confirmOpen = sheetOpen() && !connCfg.killWhileClosed && !!act('Turn on') && !/Launch at startup/.test(document.getElementById('sh-actions').textContent);
      act('Cancel').click(); await wait(50);
      out.cancelled = !sheetOpen() && !connCfg.killWhileClosed && !wc().querySelector('.mini-toggle.on');
      wc().querySelector('.mini-toggle').click(); await wait(50);
      act('Turn on').click(); await wait(50);
      out.confirmed = !sheetOpen() && connCfg.killWhileClosed === true && !!wc().querySelector('.mini-toggle.on');
      wc().querySelector('.mini-toggle').click(); await wait(50);
      out.offNoSheet = !sheetOpen() && connCfg.killWhileClosed === false;
      connCfg.killWhileClosed = true; renderConnSettings();
      out.toggled = out.offerAll && out.confirmed && out.offNoSheet;
      genCfg.connectOnLaunch = false; setGenCfg('launchAtStartup', true);
      out.dimAgain = wc().classList.contains('dim');
      out.saved = ['killSwitch', 'killOnDisconnect', 'killWhileClosed', 'downProxy'].every(k => k in liveSnapshot().connCfg);
      closeSheet('setconn'); switchTab('home');
      // a background restart: nothing to see
      connected = true; connecting = false; toasts.length = 0;
      const label = () => document.getElementById('connLabel').textContent, pw = () => document.getElementById('powerBtn').className;
      const before = label() + '|' + pw();
      liveAutoStatus({ connected: true, recovering: { attempt: 1, next: 1000, code: 1 }, down: null });
      await wait(100);
      out.recovering = label() + '|' + pw() === before && label() === 'Connected' && !toasts.length && !document.querySelector('#vpnAlert .vpn-alert');
      // down, proxy kept: blocked wording, both buttons, power button still on
      liveAutoStatus({ connected: true, recovering: { attempt: 4 }, down: { since: Date.now() - 65e3, attempt: 4, proxy: 'kept' } });
      const btns = () => [...document.querySelectorAll('#vpnAlert button')].map(b => b.textContent);
      out.kept = /internet is blocked/.test(document.querySelector('#vpnAlert').textContent) && btns().join() === 'Retry,Disable sys proxy'
        && document.getElementById('powerBtn').classList.contains('on') && label() === 'VPN is down' && /VPN is down · .*retrying/.test(document.getElementById('dockDown').textContent);
      out.noDisconnect = !btns().some(b => /disconnect/i.test(b));
      const rel = backend.releaseSysProxy; let released = 0; backend.releaseSysProxy = () => { released++; return Promise.resolve(); };
      [...document.querySelectorAll('#vpnAlert button')].find(b => b.textContent === 'Disable sys proxy').click(); await wait(50);
      backend.releaseSysProxy = rel;
      out.release = released === 1 && /traffic goes direct/.test(document.querySelector('#vpnAlert').textContent) && btns().join() === 'Retry';
      // down, proxy removed
      liveAutoStatus({ connected: true, down: { since: Date.now() - 65e3, attempt: 4, proxy: 'removed' } });
      out.direct = /traffic goes direct/.test(document.querySelector('#vpnAlert').textContent) && btns().join() === 'Retry';
      // settings apply live while down: kill switch on → proxy kept; off + Remove → removed; autoconnect ungates killWhileClosed
      renderConnSettings(); mockKill = null; connCfg.killSwitch = true; connCfg.downProxy = 'remove'; renderConnSettings(); await wait(50);
      out.liveOn = !!mockKill && mockKill.killSwitch === true && mockKill.killWhileClosed === false && vpn.down.proxy === 'kept' && /internet is blocked/.test(document.querySelector('#vpnAlert').textContent);
      setGenCfg('connectOnLaunch', true); await wait(50);
      out.liveGate = mockKill.killWhileClosed === true;
      connCfg.killSwitch = false; renderConnSettings(); await wait(50);
      out.liveOff = mockKill.killSwitch === false && vpn.down.proxy === 'removed';
      connCfg.downProxy = 'keep'; renderConnSettings(); await wait(50);
      out.liveKeep = mockKill.downProxy === 'keep' && vpn.down.proxy === 'kept';
      connCfg.downProxy = 'remove'; renderConnSettings();
      // Retry recovers (mock)
      vpn.down = { since: Date.now() - 65e3, attempt: 4, proxy: 'kept' }; renderConnState();
      document.querySelector('#vpnAlert button').click(); await wait(1000);
      out.retry = !vpn.down && !document.querySelector('#vpnAlert .vpn-alert') && label() === 'Connected';
      // power tap while down = disconnect (blocking plaque with kill + killOnDisconnect)
      connCfg.killSwitch = true; connCfg.killOnDisconnect = true;
      vpn.down = { since: Date.now() - 65e3, attempt: 4, proxy: 'kept' }; renderConnState();
      toggleMain(); await wait(100);
      out.tap = connected === false && !vpn.down && !!vpn.blocking && /Kill switch: internet is blocked/.test(document.querySelector('#vpnAlert').textContent)
        && btns().join() === 'Remove' && label() === 'Tap to connect';
      [...document.querySelectorAll('#vpnAlert button')][0].click(); await wait(50);
      out.remove = !document.querySelector('#vpnAlert .vpn-alert') && vpn.blocking.proxy === 'released';
      // a block is lifted by turning its setting off (settings reach the core while blocked, not only connected)
      vpn.blocking = { since: Date.now(), reason: 'disconnect', proxy: 'kept' }; renderConnState();
      connCfg.killOnDisconnect = false; renderConnSettings(); await wait(50);
      out.lift = !vpn.blocking && !document.querySelector('#vpnAlert .vpn-alert');
      connCfg.killSwitch = false; connCfg.killOnDisconnect = false; vpn.blocking = null; renderConnState();
      out.crashDefault = notifCfg.coreCrash === false;
      window.toast = t0;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('Events: opens on its tab at the bottom, day separators, repeats ×N, level marks, row opens; a new event at the bottom scrolls to it, scrolled up the view stays and the pill counts', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs');
    await p.waitForTimeout(700);
    const r = await p.evaluate(async () => {
      const out = {}, box = document.getElementById('evScroll'), wait = ms => new Promise(r => setTimeout(r, ms));
      const bottom = () => box.scrollTop + box.clientHeight >= box.scrollHeight - 3;
      const jump = document.getElementById('logJump');
      out.tab = logTab === 'events' && getComputedStyle(box).display !== 'none' && getComputedStyle(document.getElementById('logScroll')).display === 'none'
        && document.querySelector('#logTabs .nodes-tab.active').textContent === 'Events';
      out.bottom = bottom() && box.scrollHeight > box.clientHeight;
      const days = [...document.querySelectorAll('#evList .ev-day')].map(x => x.textContent);
      out.days = days.includes('Today') && days.includes('Yesterday');
      const rep = document.querySelector('#evList .ev-row.cat-site .ev-rep');
      out.rep = !!rep && rep.textContent === '×3';
      out.lvl = !!document.querySelector('#evList .ev-row.lvl-warn .log-tag.warn') && !!document.querySelector('#evList .ev-row.lvl-error .log-tag.error');
      out.noOwn = !document.querySelector('#evList .ev-row.cat-user');
      out.names = [...document.querySelectorAll('#evList .ev-title')].every(t => !/\bsrc\d/.test(t.textContent)) && /^Auto: .+ → .+/.test(document.querySelector('#evList .ev-row.cat-auto .ev-title').textContent);
      const site = document.querySelector('#evList .ev-row.cat-site');
      out.acts = /^Open,Open,Create rule/.test([...site.querySelectorAll('.ev-act')].map(x => x.textContent).join());
      site.click();
      out.open = site.classList.contains('open') && getComputedStyle(site.querySelector('.ev-more')).display !== 'none' && /Times/.test(site.querySelector('.ev-more').textContent);
      site.click();
      out.shut = !site.classList.contains('open');
      // In raw log: the connected row jumps to its line
      const con = [...document.querySelectorAll('#evList .ev-row.cat-conn')].find(x => x.querySelector('.ev-act'));
      out.rawBtn = !!con;
      // a new event while at the bottom: smooth scroll to it, no pill
      const last = () => box.querySelector('.ev-row:last-child .ev-title').textContent;
      mockEventAdd('auto', 'switched', 'info', { from: visibleOrder()[0], to: visibleOrder()[1], reason: 'back' });
      await pollEvents(); await wait(1100);
      out.follow = bottom() && /^Auto:/.test(last()) && jump.style.display === 'none' && evState.unseen === 0;
      // scrolled up: it stays, the pill counts
      box.scrollTop = 0; await wait(150);
      mockEventAdd('auto', 'switched', 'info', { from: visibleOrder()[1], to: visibleOrder()[0], reason: 'failover', fails: 2 });
      mockEventAdd('core', 'crashed', 'error', { code: 2 });
      await pollEvents(); await wait(300);
      out.stay = box.scrollTop === 0 && evState.unseen === 2 && jump.style.display !== 'none' && /2 new/.test(jump.textContent);
      jump.click(); await wait(1100);
      out.back = bottom() && jump.style.display === 'none' && evState.unseen === 0;
      // In raw log: Raw tab, at the line, lit
      const withLog = evState.list.find(e => e.log != null && e.cat === 'auto');
      evAct('raw', withLog.id);
      await wait(700);
      out.raw = logTab === 'raw' && !!document.querySelector('#logList .log-line.hit[data-n="' + withLog.log + '"]');
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('Events filter: by type, category tri-state, only problems, search, badge + Filtered bar + Reset; Show my actions is kept with the state, the filter is not', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs');
    await p.waitForTimeout(600);
    const r = await p.evaluate(async () => {
      const out = {}, rows = () => document.querySelectorAll('#evList .ev-row').length, n0 = rows();
      const badge = document.getElementById('evFilterBadge'), bar = document.getElementById('evFilterBar');
      openEvFilter(); evFilterFold('auto');
      out.sheet = document.getElementById('sh-evfilter').classList.contains('open') && document.querySelectorAll('#evfilter-body .evf-type').length === 3
        && document.querySelectorAll('#evfilter-body .evf-cat').length === 7;
      const unstable = () => [...document.querySelectorAll('#evList .ev-title')].some(t => /is unstable/.test(t.textContent));
      out.before = unstable() && !!document.querySelector('#evList .cat-auto');
      evToggleType('auto/unstable');
      out.type = !unstable() && !!document.querySelector('#evList .cat-auto') && rows() < n0
        && !!document.querySelector('#evfilter-body [data-cat="auto"] .evf-check.part')
        && badge.style.display !== 'none' && badge.textContent === '1' && bar.style.display !== 'none' && /Filtered: Auto 2\/3/.test(bar.textContent) && /Reset/.test(bar.textContent);
      evToggleCat('auto');   // half → all on
      out.catOn = unstable() && !!document.querySelector('#evfilter-body [data-cat="auto"] .evf-check.on');
      evToggleCat('auto');   // all on → all off
      out.catOff = !document.querySelector('#evList .cat-auto') && !document.querySelector('#evfilter-body [data-cat="auto"] .evf-check.on, #evfilter-body [data-cat="auto"] .evf-check.part');
      evResetFilter();
      out.reset = rows() === n0 && badge.style.display === 'none' && bar.style.display === 'none';
      setEvProblems(true);
      out.problems = rows() > 0 && rows() < n0 && [...document.querySelectorAll('#evList .ev-row')].every(x => /lvl-(warn|error)/.test(x.className)) && /only problems/.test(bar.textContent);
      evResetFilter();
      const inp = document.getElementById('evQ'); inp.value = 'rutracker'; inp.dispatchEvent(new Event('input'));
      out.search = rows() === 1 && /rutracker/.test(document.querySelector('#evList .ev-title').textContent);
      evResetFilter();
      // hidden by default; the switch shows them and is kept, the filter is not part of the state
      out.ownHidden = !document.querySelector('#evList .cat-user') && logCfg.showOwn === false;
      setShowOwn(true);
      out.ownShown = !!document.querySelector('#evList .cat-user') && document.querySelector('#evfilter-body [data-key="showOwn"] .mini-toggle').classList.contains('on');
      setEvProblems(true); evFilter.off.add('core/crashed');
      const snap = JSON.parse(JSON.stringify(liveSnapshot()));
      out.snap = snap.logCfg.showOwn === true && Object.keys(snap.logCfg).sort().join() === 'rawTop,rawUnread,seen,showOwn' && !JSON.stringify(snap).includes('core/crashed');
      logCfg.showOwn = false;
      liveApply(snap);
      out.kept = logCfg.showOwn === true;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('Logs tab dots: a new error → red, a warning → yellow (both may show), seen in Events or via the toast → gone, filtered-out ones count, kept in the snapshot, no layout shift', async () => {
    const p = await openPage(browser);
    await p.waitForTimeout(300);
    const r = await p.evaluate(async () => {
      const out = {}, on = id => document.getElementById(id).classList.contains('on'), wait = ms => new Promise(r => setTimeout(r, ms));
      const add = (cat, type, level, data) => { const e = mockEventAdd(cat, type, level, data); return pollEvents().then(() => e); };
      await pollEvents();
      out.hist = on('navDotErr') && on('navDotWarn');   // the mock's last hour is unseen
      const w0 = document.querySelector('.nav-btn[data-tab="logs"]').getBoundingClientRect().width;
      evMarkIds(evState.list.filter(e => e.level !== 'info').map(e => e.id));
      out.clear = !on('navDotErr') && !on('navDotWarn');
      out.noShift = document.querySelector('.nav-btn[data-tab="logs"]').getBoundingClientRect().width === w0 && getComputedStyle(document.getElementById('navDotErr')).position === 'absolute';
      const crash = await add('core', 'crashed', 'error', { code: 1 });
      out.red = on('navDotErr') && !on('navDotWarn');
      await wait(3400);   // its toast is gone by itself
      const lost = await add('conn', 'lost', 'warn', {});
      out.both = on('navDotErr') && on('navDotWarn');
      // the toast of a journal event, tapped: it is seen (its own dot goes, the other stays)
      document.getElementById('toast').click();
      await wait(300);
      out.tapSeen = logCfg.seen.includes(lost.id) && !on('navDotWarn');
      // viewed in Events: the error at the bottom row is in the viewport
      switchTab('logs'); await wait(500);
      out.viewed = !on('navDotErr') && !on('navDotWarn');
      // a warning alone, the tab closed; hidden by the filter it still counts
      switchTab('home');
      evFilter.off.add('conn/offline');
      await add('conn', 'offline', 'warn', {});
      out.warn = on('navDotWarn') && !on('navDotErr');
      evFilter.off.clear();
      // kept: through a snapshot round trip
      const snap = JSON.parse(JSON.stringify(liveSnapshot()));
      logCfg.seen = []; renderNavDots();
      out.lostState = on('navDotErr');
      liveApply(snap);
      out.kept = logCfg.seen.includes(crash.id) && on('navDotWarn') && !on('navDotErr');
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('notification toast: tappable, flies into the Logs tab when it goes (transform + opacity), an own-action toast just fades, reduced motion fades', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const out = {}, el = document.getElementById('toast'), wait = ms => new Promise(r => setTimeout(r, ms));
      const [a, b] = visibleOrder();
      mockEventAdd('auto', 'switched', 'info', { from: a, to: b, reason: 'failover', fails: 3 });
      await pollEvents();
      out.shown = el.classList.contains('show') && el.classList.contains('has-tap');
      await wait(350);   // fully shown first
      hideToast();
      await wait(150);
      const cs = getComputedStyle(el), m = new DOMMatrix(cs.transform);
      out.fly = el.classList.contains('fly') && +cs.opacity < 1 && +cs.opacity > 0.1 && m.a < 0.98;
      await wait(500);
      out.gone = !el.classList.contains('show') && !el.classList.contains('fly');
      toast('Backup saved');
      hideToast();
      out.plain = !el.classList.contains('fly') && !el.classList.contains('show');
      return out;
    });
    await p.emulateMedia({ reducedMotion: 'reduce' });
    r.reduced = await p.evaluate(async () => {
      const el = document.getElementById('toast'), [a, b] = visibleOrder();
      mockEventAdd('auto', 'switched', 'info', { from: b, to: a, reason: 'failover' });
      await pollEvents();
      hideToast();
      return !el.classList.contains('fly') && !el.classList.contains('show');
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('Logs: count badge keeps the chip width (1 vs 123), warn / error lines are two lines (meta, message), same-name servers in Auto events get the protocol / address, header buttons stay put when Search opens', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs');
    await p.waitForTimeout(500);
    const r = await p.evaluate(async () => {
      const out = {}, wait = ms => new Promise(r => setTimeout(r, ms)), rect = s => document.querySelector(s).getBoundingClientRect();
      setLogTab('raw');
      const line = (n, lvl) => ({ n, t: Date.now(), lvl, src: 'sing-box', msg: lvl + ' message ' + n });
      const unread = ls => { logState.lines = ls; logUnread.clear(); ls.forEach(l => logUnread.add(l.n)); };
      unread([line(1, 'warn'), line(2, 'info')]);
      renderLogSummary();
      const chip = () => document.querySelector('#logLevels .chip[data-lvl="warn"]'), w1 = chip().getBoundingClientRect().width;
      unread(Array.from({ length: 123 }, (_, i) => line(i + 10, 'warn')));
      renderLogSummary();
      const badge = document.getElementById('logWarnCount'), br = badge.getBoundingClientRect(), cr = chip().getBoundingClientRect();
      out.badge = chip().getBoundingClientRect().width === w1 && badge.textContent === '99+' && getComputedStyle(badge).position === 'absolute' && br.right > cr.right - 12 && br.top < cr.top + 4;
      out.badgeColor = getComputedStyle(badge).backgroundColor;
      logState.lines = [line(1, 'error'), line(2, 'info'), line(3, 'warn')];
      renderLogs();
      const w = document.querySelector('#logList .log-group.warn'), i = document.querySelector('#logList .log-group.info');
      out.twoLines = !!w && w.querySelector('.log-msg').getBoundingClientRect().top >= w.querySelector('.log-meta').getBoundingClientRect().bottom - 1
        && !!i && i.querySelector('.log-msg').getBoundingClientRect().top >= i.querySelector('.log-meta').getBoundingClientRect().bottom - 1;
      const btns = () => [...document.querySelectorAll('#rawActions .icon-btn')].map(b => { const q = b.getBoundingClientRect(); return q.x + ',' + q.y; }).join(' ');
      const b0 = btns(); toggleLogSearch(true); await wait(150);
      out.slots = b0 === btns();
      toggleLogSearch(false);
      // the same name, another protocol / the same protocol on another address
      const sid = sourceOrder.find(x => sourcesData[x].kind === 'sub' && sourcesData[x].nodes.length > 1) || sourceOrder[0], ns = sourcesData[sid].nodes;
      const a = ns[0], b = { ...ns[1], id: 'dup-proto', name: a.name, protocol: a.protocol === 'hy2' ? 'vless' : 'hy2', reality: false, outbound: undefined };
      ns.push(b);
      const ev = { cat: 'auto', type: 'fastest', level: 'info', data: { route: visibleOrder()[0], from: sid + '::' + a.id, to: sid + '::' + b.id } };
      const t1 = evDescribe(ev).title, f1 = evValue('to', ev.data.to, ev);
      const c = { ...ns[1], id: 'dup-same', name: a.name, protocol: a.protocol, address: 'other.example', port: '8443', reality: a.reality, outbound: a.outbound };
      ns.push(c);
      ev.data.to = sid + '::' + c.id;
      const t2 = evDescribe(ev).title;
      ns.length -= 2;
      out.same = t1.includes('· ' + String(b.protocol).toUpperCase()) && t1.includes('· ' + String(a.protocol).toUpperCase()) && f1.includes('·') && t2.includes('other.example:8443');
      out.titles = t1 + ' | ' + t2;
      return out;
    });
    await p.close();
    expect(r.badge && r.twoLines && r.slots && r.same, JSON.stringify(r));
  });

  await check('Logs (Raw): badge colour = worst unread (green / yellow / red), 99+ cap, dividers between entries, same second + level + source = one group, search finds a line inside a group', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs');
    await p.waitForTimeout(400);
    const r = await p.evaluate(() => {
      const out = {}, base = Math.floor((Date.now() - 6e5) / 1000) * 1000;
      setLogTab('raw');
      const mk = (n, lvl, t, msg) => ({ n, t, lvl, src: 'sing-box', msg: msg || lvl + ' message ' + n });
      const lines = Array.from({ length: 80 }, (_, i) => mk(i + 1, 'info', base + i * 5000));
      lines[10] = mk(11, 'warn', base + 10 * 5000);
      lines[70] = mk(71, 'error', base + 70 * 5000);
      // three lines in one second, one in the next
      lines.push(mk(81, 'info', base + 1e6, 'grouped needle-one'), mk(82, 'info', base + 1e6 + 100, 'grouped two'), mk(83, 'info', base + 1e6 + 200, 'grouped three'), mk(84, 'info', base + 1e6 + 1500, 'later'));
      const all = () => document.getElementById('logAllCount'), wc = () => document.getElementById('logWarnCount');
      logState.lines = lines; logState.follow = false; logState.level = 'all'; logUnread.clear();
      renderLogs();
      // colours: info only → green, a warning → yellow, an error → red; hidden at 0
      const col = ls => { logState.lines = ls; logUnread.clear(); ls.forEach(l => logUnread.add(l.n)); renderLogSummary(); return getComputedStyle(all()).backgroundColor; };
      const probe = v => { const d = document.createElement('i'); d.style.background = 'var(' + v + ')'; document.body.appendChild(d); const c = getComputedStyle(d).backgroundColor; d.remove(); return c; };
      const g = col([mk(1, 'info', base)]), y = col([mk(1, 'info', base), mk(2, 'warn', base)]), rd = col([mk(1, 'warn', base), mk(2, 'error', base)]);
      out.colors = g === probe('--active') && y === probe('--warn') && rd === probe('--danger');
      out.cap = (col(Array.from({ length: 150 }, (_, i) => mk(i + 1, 'info', base + i * 5000))), all().textContent === '99+');
      logUnread.clear(); renderLogSummary();
      out.hidden = all().textContent === '' && wc().textContent === '';
      // dividers and groups
      logState.lines = lines; renderLogs();
      const gs = [...document.querySelectorAll('#logList .log-group')];
      out.divider = gs.length > 2 && gs.slice(1).every(x => getComputedStyle(x).borderTopWidth === '1px');
      const grp = [...document.querySelectorAll('#logList .log-group')].find(x => x.textContent.includes('grouped two'));
      out.grouped = !!grp && grp.querySelectorAll('.log-line').length === 3 && grp.querySelectorAll('.log-meta').length === 1 && !grp.textContent.includes('later');
      // search inside a group
      document.getElementById('logSearch').value = 'grouped two'; renderLogs();
      const f = [...document.querySelectorAll('#logList .log-line')];
      out.search = f.length === 1 && f[0].textContent.includes('grouped two') && !!f[0].querySelector('mark');
      document.getElementById('logSearch').value = ''; renderLogs();
      return out;
    });
    await p.close();
    expect(r.colors && r.cap && r.hidden && r.divider && r.grouped && r.search, JSON.stringify(r));
  });

  await check('Logs (Raw): unread is per line — a line is read only once it was in the viewport (Raw open, page visible); new lines off-screen raise the badges at once, scrolling reads exactly what came into view, a filter does not read what it hides, kept as ranges, core numbering restarting and Clear reset it', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs');
    await p.waitForTimeout(400);
    const r = await p.evaluate(async () => {
      const out = {}, wait = ms => new Promise(r => setTimeout(r, ms));
      connected = false;   // the mock adds no lines of its own
      setLogTab('raw'); await wait(300);
      const box = document.getElementById('logScroll'), all = () => document.getElementById('logAllCount'), wc = () => document.getElementById('logWarnCount');
      const feed = async specs => { const ns = specs.map(([lvl, msg]) => mockLogAdd('sing-box', lvl, msg)); pollLogs(); await wait(80); return ns; };
      const inView = n => { const el = document.querySelector('#logList .log-line[data-n="' + n + '"]'); if (!el) return false; const b = el.getBoundingClientRect(), v = box.getBoundingClientRect(); return b.bottom > v.top + 8 && b.top < v.bottom - 8; };
      const scrollTo = async y => { box.scrollTop = y; await wait(320); };
      // cold start: what the core already had is read
      out.cold = logUnread.size === 0 && all().textContent === '' && logCfg.rawTop === mockLog.n - 1;
      // following at the bottom: new lines are in view, read at once
      await feed([['info', 'follow 1'], ['warn', 'follow 2'], ['info', 'follow 3']]);
      out.follow = logUnread.size === 0 && all().textContent === '' && logState.follow === true;
      // (a batch taller than the viewport would leave its top unread: length only here)
      await feed(Array.from({ length: 40 }, (_, i) => ['info', 'filler ' + i]));
      logUnread.clear(); renderLogSummary();
      // scrolled up: the new ones are off-screen, unread, the badges go up at once
      await scrollTo(0);
      out.scrolledUp = logState.follow === false;
      const batch = await feed(Array.from({ length: 90 }, (_, i) => [i === 30 ? 'warn' : i === 60 ? 'error' : 'info', 'batch ' + i]));
      out.up = all().textContent === '90' && wc().textContent === '2' && all().classList.contains('err') && logUnread.size === 90;
      // scrolling to the bottom reads only what is in view, the middle stays unread
      await scrollTo(box.scrollHeight);
      const seen = batch.filter(inView).length;
      out.bottom = seen > 0 && seen < 90 && logUnread.size === 90 - seen && all().textContent === String(90 - seen) && batch.every(n => logUnread.has(n) !== inView(n));
      // scrolling them into view reduces the badge by exactly those lines
      const before = new Set(logUnread), first = [...before].sort((a, b) => a - b)[0];
      document.querySelector('#logList .log-line[data-n="' + first + '"]').scrollIntoView({ block: 'start' });
      await wait(320);
      const came = [...before].filter(inView).length;
      out.middle = came > 0 && logUnread.size === before.size - came && all().textContent === String(before.size - came) && [...before].every(n => inView(n) === !logUnread.has(n));
      // the filter hides the info lines: they are not read, whatever is in view
      const info = [...logUnread].filter(n => { const l = logState.lines.find(x => x.n === n); return l.lvl === 'info'; });
      setLogLevel('warn'); await wait(320);
      const prob = logState.lines.filter(l => logUnread.has(l.n) && l.lvl !== 'info').length;
      out.filter = info.length > 0 && info.every(n => logUnread.has(n)) && wc().textContent === (prob ? String(prob) : '');
      setLogLevel('all'); await wait(50);
      // the page is not visible: new lines in view stay unread until it is
      await scrollTo(box.scrollHeight);
      logUnread.clear(); renderLogSummary();
      Object.defineProperty(document, 'hidden', { value: true, configurable: true });
      const hid = await feed([['info', 'while hidden 1'], ['warn', 'while hidden 2']]);
      out.hiddenUnread = logUnread.size === 2 && all().textContent === '2' && hid.every(inView);
      delete document.hidden; document.dispatchEvent(new Event('visibilitychange')); await wait(320);
      out.visibleRead = logUnread.size === 0 && all().textContent === '';
      // kept as ranges; lines that came while the page was away are unread on top of them
      await scrollTo(0);
      const more = await feed(Array.from({ length: 50 }, (_, i) => ['info', 'more ' + i]));
      const keep = [...logUnread].sort((a, b) => a - b).join(), snap = JSON.parse(JSON.stringify(liveSnapshot())), top = logCfg.rawTop;
      out.ranges = logUnread.size === 50 && snap.logCfg.rawUnread.length === 2 && snap.logCfg.rawTop === top;
      Object.defineProperty(document, 'hidden', { value: true, configurable: true });
      logUnread.clear(); logCfg.rawTop = null; logState.lines = []; logState.next = null; document.getElementById('logList').innerHTML = '';
      liveApply(snap);
      const away = mockLogAdd('sing-box', 'warn', 'while away');
      pollLogs(); await wait(80);
      out.reload = [...logUnread].sort((a, b) => a - b).join() === keep + ',' + away && logCfg.rawTop === top + 1;
      // the core started numbering again: what it holds is new
      mockLog.n = 0; mockLog.lines = [];
      mockLogAdd('sing-box', 'info', 'fresh 0'); mockLogAdd('sing-box', 'info', 'fresh 1');
      pollLogs(); await wait(80); pollLogs(); await wait(80);
      out.restart = [...logUnread].sort().join() === '0,1' && logCfg.rawTop === 1;
      // Clear reads everything
      delete document.hidden;
      clearLogs(); await wait(150);
      out.clear = logUnread.size === 0 && all().textContent === '' && wc().textContent === '' && logCfg.rawUnread.length === 0;
      return out;
    });
    await p.close();
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
  });

  await check('Events: Clear (confirm) empties the journal, Export has both logs as text, sub results and user actions are journaled (own)', async () => {
    const p = await openPage(browser);
    await tab(p, 'logs');
    await p.waitForTimeout(600);
    const r = await p.evaluate(async () => {
      const out = {}, wait = ms => new Promise(r => setTimeout(r, ms));
      const text = await logsExportText();
      out.export = /== Events \(\d+\) ==/.test(text) && /== Raw log \(\d+ lines\) ==/.test(text) && /Auto: /.test(text) && /Connected: /.test(text);
      // the user's own actions and a manual update land in the journal, own, so they never notify
      const n0 = evState.list.length;
      toggleSegment('mode'); setSysProxy(true);
      const sid = sourceOrder.find(id => sourcesData[id].kind === 'sub');
      updateSource(sid);
      await wait(2800);
      const fresh = evState.list.slice(n0);
      out.user = fresh.some(e => e.cat === 'user' && e.type === 'mode' && e.own) && fresh.some(e => e.cat === 'user' && e.type === 'sysProxy' && e.data.on === true);
      out.sub = fresh.some(e => e.cat === 'sub' && e.type === 'updated' && e.own && e.data.source === sid);
      confirmClearEvents();
      out.confirm = document.getElementById('sh-actions').classList.contains('open') && /Clear events/.test(document.getElementById('actions-body').textContent);
      clearEvents();
      await wait(300);
      out.cleared = !evState.list.length && !document.querySelector('#evList .ev-row') && !!document.querySelector('#evList .log-empty');
      await pollEvents();
      out.stays = !evState.list.length;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('live plan + rules: one plan carries the Auto routes and plan.routing; the core moving a group or a rule target\'s ping order is no reconnect, a rule edit is', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(() => {
      setAutoConnect(true);
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { n.outbound = { type: 'socks', server: '127.0.0.1', server_port: 1 }; n.unsupported = false; }));
      const order = autoOrder(), id = order.find(x => !chainsData[x] && unitPickRefs(x).length > 1);
      live.anchor = effectiveConnectId(true);
      const plan = livePlan(), out = { both: plan.routes.length > 0 && !!plan.routing && !!plan.auto && plan.routes[plan.current].id === live.anchor };
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => setPing(n, 100)));   // all alive: leftover pings of earlier checks move a Priority pick
      const sig = planSig();
      // the core moved to another entry and server; a rule target's servers re-sorted by a ping
      coreRoute = { id, server: refKey(unitPickRefs(id).slice(-1)[0]), entryServer: null };
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => setPing(n, Math.round(Math.random() * 300))));
      out.stable = planSig() === sig;
      out.ownPicks =livePlan().routes.every(x => x.id !== id || x.main.chosen !== coreRoute.server || unitPriority(id));
      rulesData[ruleOrder[0]].enabled = !rulesData[ruleOrder[0]].enabled;
      out.ruleEdit = planSig() !== sig;
      coreRoute = null;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  // Resolve for IP rules (docs/rules.md §4, §6): the DNS setting, the rule form's IP block, plan.routing.
  await check('Resolve for IP rules: default Auto, off / server / unticked server, IP block only with IP conditions, flag saved, link to DNS', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      const out = {};
      out.def = dnsCfg.resolve === 'auto' && dnsResolveEff() === 'auto' && dnsResolveServer().id === 'remote' && routingPlan().dns.resolve === 'auto';
      openDnsSettings();
      const sel = () => document.getElementById('dns-resolve'), warn = () => !!document.querySelector('#dns-settings [data-key=dnsResolve] .set-hint.warn');
      out.select = [...sel().options].map(o => o.value).join() === 'off,auto,remote,local' && sel().value === 'auto' && !warn();
      setDnsCfg('resolve', 'off');
      out.off = sel().value === 'off' && routingPlan().dns.resolve === 'off' && dnsResolveServer() === null && !warn();
      setDnsCfg('resolve', 'local');
      out.direct = sel().value === 'local' && routingPlan().dns.resolve === 'local' && warn();
      toggleDnsOn('local');   // the chosen server is unticked: Auto again (the choice stays for when it comes back)
      out.unticked = sel().value === 'auto' && dnsResolveEff() === 'auto' && routingPlan().dns.resolve === 'local';
      toggleDnsOn('local'); setDnsCfg('resolve', 'auto');
      closeSheet('setdns');
      // the block: only with an IP condition (IP / CIDR, GeoIP, local networks, JSON)
      const block = () => !!document.querySelector('#rf-body .rf-ip');
      openRuleForm('r1');
      out.noIp = !block();
      rfAddField('ip', 'ip_cidr');
      out.emptyIp = !block();
      rfAddValues('ip', 'ip_cidr', '10.0.0.0/8', false);
      // the block: checkbox + (?) + link only; the explanation and the state live in the (?)
      const helpText = () => document.getElementById('help-body').textContent;
      out.shown = block() && !document.querySelector('#rf-body .rf-ip .set-hint') && !!document.querySelector('#rf-body .rf-ip .rf-ip-row .help-btn')
        && !!document.querySelector('#rf-body .rf-ip .rf-ip-link') && !document.querySelector('#rf-body .rf-ip .sub-checkbox').classList.contains('checked');
      document.querySelector('#rf-body .rf-ip .help-btn').click();
      out.helpOpen = document.getElementById('sh-help').classList.contains('open') && !ruleDraft.ipTunOnly && /Resolve for IP rules is via Cloudflare/.test(helpText()) && /this rule is not ticked/.test(helpText());
      closeSheet('help');
      document.querySelector('#rf-body .rf-ip-row').click();
      document.querySelector('#rf-body .rf-ip .help-btn').click();
      out.flagOn = ruleDraft.ipTunOnly === true && /this rule is ticked/.test(helpText());
      closeSheet('help');
      setRfTab('json'); setRfTab('form');
      out.jsonKeeps = ruleDraft.ipTunOnly === true && !JSON.stringify(ruleJson(ruleDraft)).includes('ipTunOnly');
      saveRuleForm();
      out.saved = rulesData.r1.ipTunOnly === true && routingPlan().rules.find(x => x.id === 'r1').ipTunOnly === true && !('ipTunOnly' in routingPlan().rules.find(x => x.id === 'r2'));
      openRuleForm('r3'); rfAddField('ip', 'ip_is_private'); renderRuleForm();
      out.localNets = block() && ruleDraft.groups.ip.flag === true;
      ruleDraft.groups.ip.flag = false; rfAddField('ip', 'geoip'); rfAddValues('ip', 'geoip', 'ru', false);
      out.geoip = block();
      out.json = ruleHasIpCondition({ composite: { type: 'logical', mode: 'or', rules: [{ domain_keyword: ['x'] }, { ip_cidr: ['1.1.1.1/32'] }] }, groups: {} })
        && !ruleHasIpCondition(rulesData.r4);
      closeSheet('ruleform');
      // dropping the IP conditions drops the flag
      openRuleForm('r1'); rfRemoveGroup('ip'); saveRuleForm();
      out.dropped = !('ipTunOnly' in rulesData.r1);
      // the link: Settings → DNS opens ABOVE the form (its draft stays under it); ×, swipe and Back all return to the form as it was
      const open = n => document.getElementById('sh-' + n).classList.contains('open');
      const z = n => +getComputedStyle(document.getElementById('sh-' + n)).zIndex;
      const fire = (el, type, y) => el.dispatchEvent(new PointerEvent(type, { clientY: y, bubbles: true }));
      const closers = {
        x: () => document.querySelector('#sh-setdns .sheet-close').click(),
        swipe: () => { fire(document.querySelector('#sh-setdns .sheet-head'), 'pointerdown', 100); fire(window, 'pointermove', 320); fire(window, 'pointerup', 320); },
        back: () => history.back(),
      };
      openRuleForm('r1'); rfAddField('ip', 'ip_cidr'); rfAddValues('ip', 'ip_cidr', '10.0.0.0/8', false); ruleDraft.name = 'Keep me';
      for (const [how, close] of Object.entries(closers)) {
        document.querySelector('#rf-body .rf-ip-link').click();
        await wait(150);
        out[how + 'Over'] = open('setdns') && open('ruleform') && sheetStack[sheetStack.length - 1].name === 'setdns' && z('setdns') > z('ruleform')
          && !!document.querySelector('#dns-settings [data-key=dnsResolve].hit');
        await wait(350);
        setDnsCfg('resolve', how === 'x' ? 'off' : 'auto');
        close();
        await wait(700);
        out[how + 'Back'] = open('ruleform') && !open('setdns') && sheetStack[sheetStack.length - 1].name === 'ruleform' && z('ruleform') > z('setdns')
          && ruleDraft.groups.ip.v.ip_cidr[0] === '10.0.0.0/8' && ruleDraft.name === 'Keep me' && document.getElementById('rf-name').value === 'Keep me';
      }
      document.querySelector('#rf-body .rf-ip .help-btn').click();
      out.state = /Resolve for IP rules is via Cloudflare/.test(helpText());
      closeSheet('help');
      closeSheet('ruleform');
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  // Rules, apps, quick rules and DNS reach the core as plan.routing (93-routing-plan.js).
  await check('routing plan: enabled rules, apps, targets as groups (null = unavailable), quick rules, DNS', async () => {
    const p = await openPage(browser);
    await seedServices(p);
    const r = await p.evaluate(() => {
      // mock servers carry no sing-box outbound (a target of those alone is unusable = null)
      const out0 = routingPlan().targets['chain:sc1'] === null;
      Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { n.outbound = { type: 'socks', server: '127.0.0.1', server_port: 1 }; }));
      const out = { noOutbound: out0 }, plan = routingPlan();
      out.json = JSON.parse(JSON.stringify(plan)).rules.length === plan.rules.length;
      out.enabledOnly = plan.rules.every(x => rulesData[x.id].enabled) && plan.rules.length === ruleOrder.filter(id => rulesData[id].enabled).length;
      const chain = plan.targets['chain:sc1'];
      out.chainTarget = targetInfo('chain:sc1').ok ? chain.kind === 'chain' && chain.entry.nodes.length > 0 && chain.main.nodes.length > 0 : chain === null;
      out.appSplit = plan.apps.some(a => a.id === 'com.discord' && a.split && a.udp.act === 'proxy' && a.udp.target === 'chain:sc1' && a.name === 'Discord' && a.kind === 'package');
      out.services = Object.keys(plan.quick.services).every(k => quickCfg.services[k] !== 'default') && Object.keys(plan.quick.services).length > 0;
      out.region = plan.quick.region === (quickCfg.regionOn ? quickCfg.region : null);
      out.dns = plan.dns.servers.map(s => s.id).join() === dnsOrder.join() && plan.geo.geosite.via === 'vpn';
      // a composite rule goes without its action (the rule's own action applies)
      rulesData.r4.enabled = true;
      out.composite = routingPlan().rules.some(x => x.composite && !('action' in x.composite) && x.composite.type === 'logical');
      // a target switched off in Nodes: null (the rule takes its If unavailable)
      appRules['org.telegram.messenger'] = appNormalize({ act: 'proxy', target: 'src:src1' });
      out.srcOk = routingPlan().targets['src:src1'].main.pick === 'fastest';
      sourcesData.src1.enabled = false;
      out.srcOff = routingPlan().targets['src:src1'] === null;
      sourcesData.src1.enabled = true;
      // the reconnect check: a ping reordering a target's servers is no change, a rule edit is
      const base = { kind: 'unit', main: null, routing: routingPlan() };
      const moved = JSON.parse(JSON.stringify(base));
      moved.routing.targets['src:src1'].main.nodes.reverse();
      out.sigPing = planSigOf(base) === planSigOf(moved);
      rulesData.r1.enabled = false;
      out.sigRule = planSigOf(base) !== planSigOf({ kind: 'unit', main: null, routing: routingPlan() });
      // Domains + IP in one rule: logical AND in the rule's JSON too, and back
      const both = newRule({ action: 'direct', groups: { domain: { not: false, v: { domain_suffix: ['a.com'] } }, ip: { not: false, v: { ip_cidr: ['1.1.1.1'] } } } });
      const j = ruleJson(both), back = ruleFromJson(j);
      out.andJson = j.type === 'logical' && j.mode === 'and' && !!back.groups.domain && !!back.groups.ip && !back.composite;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });

  await check('live mode: rules / apps / DNS start clean, persist in the snapshot, edits save', async () => {
    const p = await openPage(browser);
    const r = await p.evaluate(async () => {
      window.JORMD = true; liveInit();
      const out = {};
      out.clean = !ruleOrder.length && !Object.keys(rulesData).length && !Object.keys(appRules).length
        && ruleSets.every(s => s.builtin) && Object.values(quickCfg.services).every(v => v === 'default');
      out.dnsKept = dnsOrder.length === 3;
      const snap = liveSnapshot();
      out.inSnapshot = ['rulesData', 'ruleOrder', 'ruleSeq', 'quickCfg', 'appRules', 'ruleSets', 'rsSeq', 'dnsServers', 'dnsOrder', 'dnsSeq', 'dnsCfg'].every(k => k in snap);
      snap.rulesData = { r7: newRule({ id: 'r7', action: 'direct', groups: { domain: { not: false, v: { domain_suffix: ['x.com'] } } } }) };
      snap.ruleOrder = ['r7']; snap.ruleSeq = 8;
      snap.quickCfg = Object.assign({}, snap.quickCfg, { services: { telegram: 'vpn' }, ads: true });
      snap.dnsOrder = ['local', 'remote']; delete snap.dnsServers.google; snap.dnsOrder = snap.dnsOrder.filter(id => snap.dnsServers[id]);
      liveApply(JSON.parse(JSON.stringify(snap)));
      out.applied = ruleOrder[0] === 'r7' && quickCfg.ads && quickCfg.services.telegram === 'vpn' && quickCfg.services.youtube === 'default'
        && dnsOrder.join() === 'local,remote' && !dnsServers.google;
      renderRules(); renderDns();
      // a rules edit saves once the stored state is in
      live.ready = true;
      toggleRuleEnabled('r7');
      out.saves = !!live.saveTimer;
      clearTimeout(live.saveTimer); live.ready = false;
      return out;
    });
    expect(Object.values(r).every(Boolean) && !p.errors.length, JSON.stringify(r) + ' ' + p.errors.join(' | '));
    await p.close();
  });
  await browser.close();

  const failed = results.filter(r => r[1]);
  for (const [name, err] of failed) console.log(`FAIL  ${name}: ${err}`);
  console.log(`${results.length - failed.length}/${results.length} checks passed (seed ${CHECK_SEED})`);
  return failed.length;
}

// audit-ru [presets|all] — every text (and title / placeholder / aria-label) still Latin after a preset in Russian:
// what the dictionary (js/04-i18n-ru.js) misses. Names, protocols and the kept terms are filtered out.
async function auditRu(names) {
  if (!names.length || names[0] === 'all') names = Object.keys(SHOTS).filter(n => !n.startsWith('ru-'));
  const browser = await playwright.chromium.launch();
  const found = new Map();
  for (const name of names) {
    if (!SHOTS[name]) continue;
    const page = await openPage(browser, { lang: 'ru' });
    try { await SHOTS[name](page); await page.waitForTimeout(300); } catch (e) { console.log('preset failed: ' + name + ' ' + e.message.split('\n')[0]); }
    const texts = await page.evaluate(() => {
      const out = [], skip = 'script,style,textarea,[data-notr],.log-line,.log-time,.log-tag';
      const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (let n; (n = w.nextNode());) if (!(n.parentElement && n.parentElement.closest(skip))) out.push(n.nodeValue);
      document.querySelectorAll('[title],[placeholder],[aria-label]').forEach(el => { if (!el.closest(skip)) for (const a of ['title', 'placeholder', 'aria-label']) if (el.getAttribute(a)) out.push(el.getAttribute(a)); });
      return out;
    });
    for (let t of texts) {
      t = t.replace(/\s+/g, ' ').trim();
      const rest = t.replace(/\b(TUN|sing-box|DNS|IP|CIDR|GeoIP|Geosite|SOCKS5?|HTTPS?|UDP|TCP|QUIC|FakeIP|UUID|URL|JSON|YAML|Regex|VLESS|VMess|Trojan|Hysteria2?|HY2|TUIC|AnyTLS|Shadowsocks|SS|Clash|mihomo|Jormungand|Karing|Kill switch|HWID|DoH|DoT|DoQ|GB|MB|KB|Mbps|ms|OS|PC|UA|VPN|QR|Wi-?Fi|Android|Windows|SRS|Sub|GitHub|Dark|Discord|Telegram|Google|Yandex|YouTube|Netflix)\b/gi, '');
      if (!/[A-Za-z]{3}/.test(rest)) continue;
      if (!found.has(t)) found.set(t, name);
    }
    await page.close();
  }
  await browser.close();
  for (const [t, n] of [...found.entries()].sort((a, b) => a[0].localeCompare(b[0]))) console.log(t + '\t' + n);
  console.log(`# ${found.size} untranslated texts over ${names.length} presets`);
}

// shot <presets> — screenshots; verify [presets] — checks, then one grid of the presets.
if (positional[0] === 'audit-ru') await auditRu(positional.slice(1));
else if (positional[0] === 'shot') await shots(positional.slice(1).length ? positional.slice(1) : ['home']);
else {
  const failed = await runChecks();
  if (positional[0] === 'verify' && positional.length > 1) await shots(positional.slice(1), true);
  process.exit(failed ? 1 : 0);
}
