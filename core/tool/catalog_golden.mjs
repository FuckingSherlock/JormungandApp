// Golden files for core/test/catalog_golden_test.dart: runs the real mockup (design/main_screen.html,
// headless Chromium) through a list of scenarios and records, for each, the snapshot
// (liveSnapshot()) and what the mockup's catalog logic answers on it (effectiveConnectId, brokenBy,
// livePlan, planSig, targetInfo, deleteImpact...). The Dart catalog (core/lib/src/catalog) must
// give the same answers on the same snapshot; ops scenarios also record the snapshot after the
// mockup's own function ran, so the Dart ops are compared with it.
//
//   node core/tool/catalog_golden.mjs        (after `npm run build`, rewrites core/test/golden/catalog.json)
//
// Deterministic: Math.random is seeded and Date.now fixed, every node gets an explicit outbound and
// the ping cache is set by hand. Playwright is resolved like design/tools/check.mjs does.
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const PAGE = 'file://' + join(root, 'design', 'main_screen.html');
const OUT = join(root, 'core', 'test', 'golden', 'catalog.json');
const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(join(execSync('npm root -g').toString().trim(), 'playwright')); }

const T0 = 1760000000000;

const INIT = `(() => {
  let s = 1;
  Math.random = function () {
    s |= 0; s = (s + 0x6D2B79F5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  Date.now = () => ${T0};
})();`;

// Page side. Everything the mockup computes for a state, as plain JSON.
const LIB = `(() => {
  const T0 = ${T0};
  const clone = x => JSON.parse(JSON.stringify(x));
  let BASE = null;
  const nodeOfSid = (sid, nid) => { const s = sourcesData[sid]; return s.nodes.find(x => x.id === nid) || (s.gone || []).find(x => x.id === nid); };
  // ping a server: ms, fails (default 1 on a timeout), age in ms
  const P = (sid, nid, ms, o = {}) => pingCache.set(pingKey(nodeOfSid(sid, nid)), { ms, at: T0 - (o.age == null ? 1000 : o.age), fails: o.fails == null ? (ms === -1 ? 1 : 0) : o.fails });
  const PA = (sid, ms, o) => sourcesData[sid].nodes.forEach(n => P(sid, n.id, ms, o));
  // FNV-1a 32 + djb2 over UTF-16 code units (the Dart test has the same)
  const hash = s => {
    if (s == null) return null;
    let a = 0x811c9dc5, b = 5381;
    for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); a = Math.imul(a ^ c, 16777619) >>> 0; b = (Math.imul(b, 33) + c) >>> 0; }
    return s.length + ':' + a.toString(16) + ':' + b.toString(16);
  };
  const keyOfNode = n => { if (!n) return null; for (const s of Object.values(sourcesData)) if (s.nodes.includes(n)) return s.id + '::' + n.id; return null; };
  const TARGETS = ['', 'src:src1', 'src:src2', 'src:src3', 'src:src4', 'src:ghost', 'node:src1::n0', 'node:src1::n5', 'node:src2::n8', 'node:src2::n1',
    'node:ghost::n1', 'node:src1::ghost', 'profile:default', 'profile:work', 'profile:gaming', 'profile:ghost', 'chain:sc1', 'chain:cpgaming', 'chain:ghost',
    'src1', 'sc1', 'default', 'zzz'];

  function init() {
    Object.values(sourcesData).forEach(s => s.nodes.concat(s.gone || []).forEach(n => { n.outbound = { o: s.id + '.' + n.id }; }));
    pingCache.clear();
    Object.keys(sourcesData).sort().forEach((sid, si) => sourcesData[sid].nodes.forEach((n, i) => {
      if (i % 7 === 3) P(sid, n.id, -1, { fails: 2 });
      else P(sid, n.id, 30 + ((i * 53 + si * 17) % 280));
    }));
    coreRoute = null;
    BASE = clone(liveSnapshot());
    return BASE;
  }

  function impactOfEntry(id) {   // confirmDeleteEntry (31-catalog.js), without the dialog
    const lines = [];
    const dead = new Set(['chain:' + id, 'profile:' + id]);
    if (profilesData[id]) {
      const others = getProfileIds().filter(x => x !== id), fb = others[0];
      Object.values(chainsData).forEach(c => {
        if (c.inId !== id && c.outId !== id) return;
        const inId = c.inId === id ? fb : c.inId, outId = c.outId === id ? fb : c.outId;
        if (!fb || inId === outId) { lines.push([c.name, 'chain', 'is deleted with it', 'bad']); dead.add('chain:' + c.id); }
        else lines.push([c.name, 'chain', 'its ' + (c.inId === id ? 'entry' : 'exit') + ' moves to ' + profilesData[fb].name, 'warn']);
      });
    }
    if (effectiveConnectId() === id) lines.unshift(['Current connection', '', 'goes through it — will reconnect through the next entry', 'warn']);
    return lines.concat(targetImpact(t => dead.has(t)));
  }
  function impactOfSource(sid) {   // confirmDeleteSource (30-nodes.js)
    const dead = new Set(Object.values(chainsData).filter(c => c.inId === sid || c.outId === sid).map(c => 'chain:' + c.id));
    return deleteImpact(r => r.sid === sid, sid).concat(targetImpact(t => t === 'src:' + sid || t.startsWith('node:' + sid + '::') || dead.has(t)));
  }
  function impactOfNode(sid, nid) {   // confirmDeleteNode
    return deleteImpact(r => r.sid === sid && r.node.id === nid).concat(targetImpact(t => t === 'node:' + sid + '::' + nid));
  }

  function results(full, rt) {
    const R = {}, ids = connectOrder.slice();
    R.effective = effectiveConnectId() || null;
    R.own = effectiveConnectId(true) || null;
    R.whenAuto = effectiveConnectIdWhenAuto() || null;
    R.nothingInAuto = nothingInAuto();
    R.catalogEmpty = catalogEmpty();
    R.visible = visibleOrder();
    R.broken = brokenOrder();
    R.autoOrder = autoOrder();
    R.brokenBy = {}; R.brokenText = {}; R.mayWork = {}; R.picks = {}; R.usable = {};
    ids.forEach(id => {
      const b = brokenBy(id);
      R.brokenBy[id] = b.map(r => [r.sid, r.nid || null]);
      if (b.length) R.brokenText[id] = reasonsText(b);
      R.mayWork[id] = mayWork(id);
      R.usable[id] = isUsable(id);
      if (chainsData[id]) R.picks[id] = { entry: keyOfNode(chainEntryNode(chainsData[id])), exit: keyOfNode(chainExitNode(chainsData[id])) };
      else R.picks[id] = { node: keyOfNode(unitNode(id)) };
    });
    // the plan: in full (full scenarios) or in brief (routes with their groups' keys), always its signature
    const grp = g => g && { pick: g.pick, chosen: g.chosen, pinned: !!g.pinned, keys: g.nodes.map(n => n.key) };
    try {
      const plan = livePlan();
      R.planBrief = { current: plan.current, routes: plan.routes.map(r => ({ id: r.id, kind: r.kind, main: grp(r.main), entry: grp(r.entry) || null })) };
      if (full) R.plan = clone(plan);
    } catch (e) { R.planBrief = { error: e.message }; }
    R.planSig = hash(planSig());
    R.anchors = {};
    ids.forEach(id => {
      try { const p = livePlan(id); R.anchors[id] = { routes: p.routes.map(r => r.id), current: p.current, sig: hash(planSigOf(p)) }; }
      catch (e) { R.anchors[id] = { error: e.message }; }
    });
    R.findAnchor = [autoOrder(), ['sc1', 'src2'], ['zzz']].map(l => liveFindAnchor(l));
    R.goneLeft = {};
    Object.values(sourcesData).forEach(s => (s.gone || []).forEach(n => { R.goneLeft[s.id + '::' + n.id] = goneLeftDays(n); }));
    if (!full) return R;
    R.targets = {}; TARGETS.forEach(t => { const i = targetInfo(t); R.targets[t] = [i.kind, i.name || '', i.flag || '', !!i.gone, !!i.ok]; });
    if (rt) { R.routingTargets = {}; TARGETS.forEach(t => { R.routingTargets[t] = t === '' ? null : clone(routingTarget(t) || null); }); }
    R.impact = { src: {}, node: {}, entry: {} };
    sourceOrder.forEach(sid => {
      R.impact.src[sid] = impactOfSource(sid);
      ['n0', 'n6'].forEach(nid => { if (sourcesData[sid].nodes.some(n => n.id === nid)) R.impact.node[sid + '::' + nid] = impactOfNode(sid, nid); });
    });
    Object.keys(profilesData).concat(Object.keys(chainsData)).forEach(id => { R.impact.entry[id] = impactOfEntry(id); });
    R.nodeDead = {};
    Object.values(sourcesData).forEach(s => s.nodes.forEach(n => { if (knownDead(n)) R.nodeDead[s.id + '::' + n.id] = true; }));
    return R;
  }

  // Snapshot diff against another snapshot: whole keys, except the maps of entities, which are
  // patched per entry ({__patch: {id: entry | {__del: 1}}}).
  const MAPS = ['sourcesData', 'profilesData', 'chainsData', 'appRules', 'rulesData'];
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const diff = (snap, base) => {
    const o = {};
    Object.keys(snap).forEach(k => {
      if (same(snap[k], base[k])) return;
      if (!MAPS.includes(k)) { o[k] = snap[k]; return; }
      const p = {};
      Object.keys(snap[k]).forEach(id => { if (!same(snap[k][id], base[k][id])) p[id] = snap[k][id]; });
      Object.keys(base[k]).forEach(id => { if (!(id in snap[k])) p[id] = { __del: 1 }; });
      o[k] = { __patch: p };
    });
    return o;
  };

  function run(sc) {
    liveApply(clone(BASE));
    coreRoute = null;
    eval(sc.setup || '');
    syncCatalog();
    const S = clone(liveSnapshot()), out = { name: sc.name, snapshot: diff(S, BASE), meta: { coreRoute: coreRoute ? clone(coreRoute) : null } };
    out.results = results(sc.full, ['measured', 'profiles-mode', 'rules-targets', 'rules-targets-xhttp', 'xhttp-src2'].includes(sc.name));
    if (sc.op) {
      eval(sc.op);
      syncCatalog();
      out.op = sc.name;
      out.after = diff(clone(liveSnapshot()), S);
    }
    return out;
  }
  const apps = {}; APPS.forEach(a => { apps[a.pkg] = { name: a.name, kind: a.kind || null }; });
  window.__G = { init, run, apps, P, PA };
})()`;

const ALL_OFF = "Object.values(sourcesData).forEach(s => s.enabled = false)";
const EXTRA_RULES = `
  rulesData.r3.action = 'proxy'; rulesData.r3.target = 'src:src3';
  rulesData.r5 = { id: 'r5', name: 'Via disabled', enabled: true, action: 'proxy', target: 'node:src2::n8', block: 'drop', fallback: 'main', fallbackTarget: 'profile:work', dns: 'local', groups: { ip: { not: false, v: { ip_cidr: ['10.0.0.0/8'] }, flag: true } }, ipTunOnly: true };
  rulesData.r6 = { id: 'r6', name: '', enabled: true, action: 'proxy', target: 'profile:ghost', fallback: 'direct', groups: { domain: { not: true, v: { domain_suffix: ['a.com', 'b.com', 'c.com'], domain_keyword: ['x'] } } }, extra: { rule_set: ['q'] } };
  rulesData.r7 = { id: 'r7', name: 'Pinned', enabled: true, action: 'proxy', target: 'chain:cpgaming', fallback: 'block', groups: { port: { not: false, v: { port: ['443', '8000-9000'] } }, network: { not: false, v: { network: ['udp'] } } } };
  rulesData.r8 = { id: 'r8', name: 'Off', enabled: false, action: 'proxy', target: 'src:src1', groups: {} };
  ruleOrder.push('r5', 'r6', 'r7', 'r8');
  appRules['com.spotify.music'] = appNormalize({ act: 'proxy', target: 'profile:gaming', fallback: 'main', fallbackTarget: 'src:src4' });
  appRules['com.whatsapp'] = appNormalize({ act: 'default', fallback: 'block' });
  appRules['com.openai.chatgpt'] = appNormalize({ act: 'proxy', target: 'node:src2::n1', split: true, udp: { act: 'proxy', target: 'src:ghost', fallback: 'direct' } });
  appRules['com.android.chrome'] = appNormalize({ act: 'proxy', target: 'chain:sc1', fallback: 'default' });
  quickCfg.services.spotify = 'direct'; quickCfg.regionOn = false; quickCfg.ads = true; quickCfg.final = 'direct'; quickCfg.fallback = 'block';
  ruleSets.push({ id: 'rs2', name: 'extra', url: 'https://example.org/x.srs', format: 'srs', via: 'direct', every: 3600 });
  ruleSets.find(x => x.id === 'geoip').via = 'direct';
  dnsCfg.resolve = 'local'; dnsCfg.hijack = false;
  dnsServers.google.on = true;`;

const SCENARIOS = [
  { name: 'measured', full: true },
  { name: 'unmeasured', setup: 'pingCache.clear()', full: true },
  { name: 'src1-dead', setup: "__G.PA('src1', -1, { fails: 2 })", full: true },
  { name: 'src1-one-miss', setup: "__G.PA('src1', -1, { fails: 1 })" },
  { name: 'src1-old-miss', setup: "__G.PA('src1', -1, { fails: 3, age: 10 * 60e3 })" },
  { name: 'src1-and-sc1-dead', setup: "__G.PA('src1', -1, { fails: 2 }); __G.PA('src4', -1, { fails: 2 })" },
  { name: 'src1-off', setup: 'sourcesData.src1.enabled = false', full: true },
  { name: 'src3-nodes-disabled', setup: "sourcesData.src3.disabledNodes = ['n0', 'n1']" },
  { name: 'src2-all-off-for-entry', setup: "sourcesData.src2.offNodes = sourcesData.src2.nodes.map(n => n.id)" },
  { name: 'nothing-in-auto', setup: 'Object.values(profilesData).concat(Object.values(chainsData), Object.values(sourcesData)).forEach(e => e.inAuto = false)' },
  { name: 'manual-pin', setup: "autoConnect = false; activeConnectId = 'src1'; pinnedNode = 'src1::n3'", full: true },
  { name: 'manual-pin-dead', setup: "autoConnect = false; activeConnectId = 'src1'; pinnedNode = 'src1::n3'; __G.P('src1', 'n3', -1, { fails: 5 })" },
  { name: 'manual-pin-stale', setup: "autoConnect = false; activeConnectId = 'src1'; pinnedNode = 'src1::n5'" },
  { name: 'manual-entry', setup: "autoConnect = false; activeConnectId = 'src2'" },
  { name: 'manual-broken', setup: "autoConnect = false; activeConnectId = 'src3'; sourcesData.src3.disabledNodes = ['n0', 'n1']" },
  { name: 'manual-chain', setup: "autoConnect = false; activeConnectId = 'sc1'", full: true },
  { name: 'profiles-mode', setup: "setConnectMode('profiles')", full: true },
  { name: 'profiles-priority', setup: "setConnectMode('profiles'); autoConnect = false; activeConnectId = 'gaming'; __G.P('src4', 'n1', -1, { fails: 2 })" },
  { name: 'profiles-src2-off', setup: "setConnectMode('profiles'); sourcesData.src2.enabled = false", full: true },
  { name: 'profiles-gone-pick', setup: "setConnectMode('profiles'); profilesData.work.nodes = ['src1::n18', 'src1::n0']" },
  { name: 'core-route', setup: "coreRoute = { id: 'src2', server: 'src2::n1', entryServer: null }" },
  { name: 'core-route-chain', setup: "coreRoute = { id: 'sc1', server: 'src1::n9', entryServer: 'src4::n2' }", full: true },
  { name: 'core-route-not-in-auto', setup: "sourcesData.src2.inAuto = false; coreRoute = { id: 'src2', server: 'src2::n1' }" },
  { name: 'xhttp-src2', setup: "sourcesData.src2.nodes.forEach(n => n.unsupported = 'XHTTP')", full: true },
  { name: 'xhttp-all', setup: "Object.values(sourcesData).forEach(s => s.nodes.forEach(n => n.unsupported = 'XHTTP'))" },
  { name: 'no-outbound-src3', setup: "sourcesData.src3.nodes.forEach(n => delete n.outbound)" },
  { name: 'tun-auth', setup: "segState.mode = 'tun'; segState.sys = 'on'; connCfg.proxyAuth = true; connCfg.proxyUser = 'u'; connCfg.proxyPass = 'p'; connCfg.testUrl = 'https://t.example/'; connCfg.tunStack = 'gvisor'; connCfg.port = 0", full: true },
  { name: 'ipv6-on', setup: "segState.mode = 'tun'; connCfg.ipv6 = true" },
  { name: 'global', setup: "segState.route = 'global'; segState.sys = 'on'; autoCfg.checkEvery = 45; autoCfg.threshold = 80" },
  { name: 'rules-targets', setup: EXTRA_RULES, full: true },
  { name: 'rules-targets-src1-off', setup: EXTRA_RULES + "; sourcesData.src1.enabled = false", full: true },
  { name: 'rules-targets-xhttp', setup: EXTRA_RULES + "; sourcesData.src3.nodes.forEach(n => n.unsupported = 'XHTTP')", full: true },
  { name: 'chain-exit-dead', setup: "__G.P('src1', 'n6', -1, { fails: 2 }); __G.P('src1', 'n18', -1, { fails: 2 })", full: true },
  { name: 'chain-entry-off', setup: "chainsData.sc1.inOff = sourcesData.src4.nodes.map(n => 'src4::' + n.id)" },
  { name: 'priority-source', setup: "sourcesData.src1.pickMode = 'priority'; sourcesData.src1.pickOrder = ['src1::n4', 'src1::n2']; __G.P('src1', 'n4', -1, { fails: 2 })", full: true },
  { name: 'priority-profile-target', setup: "profilesData.work.pickMode = 'priority'; profilesData.work.pickOrder = ['src2::n3', 'src2::n1']" },
  { name: 'profile-node-disabled', setup: "setConnectMode('profiles'); sourcesData.src4.disabledNodes = ['n0']" },
  { name: 'all-off', setup: ALL_OFF, full: true },
  { name: 'first-run', setup: 'liveApply(null)', full: true },
  // ── ops: the mockup's own function runs after the setup; Dart replays it (catalog_golden_test.dart) ──
  { name: 'op-select-src2', op: "selectConnect('src2')" },
  { name: 'op-select-twice', setup: "autoConnect = false; activeConnectId = 'src2'", op: "selectConnect('src2')" },
  { name: 'op-auto-off', setup: "__G.PA('src1', -1, { fails: 2 })", op: 'setAutoConnect(false)' },
  { name: 'op-auto-on', setup: "autoConnect = false; activeConnectId = 'src2'; pinnedNode = 'src2::n1'", op: 'setAutoConnect(true)' },
  { name: 'op-pin', op: "pinRouteNode('src1', 'src1::n2')" },
  { name: 'op-pin-again', setup: "autoConnect = false; activeConnectId = 'src1'; pinnedNode = 'src1::n2'", op: "pinRouteNode('src1', 'src1::n2')" },
  { name: 'op-toggle-auto', op: "toggleEntryAuto('src2')" },
  { name: 'op-mode-profiles', op: "setConnectMode('profiles')" },
  { name: 'op-mode-roundtrip', setup: "autoConnect = false; activeConnectId = 'src2'; pinnedNode = 'src2::n1'", op: "setConnectMode('profiles'); autoConnect = false; activeConnectId = 'gaming'; setConnectMode('simple')" },
  { name: 'op-delete-src1', op: "deleteSource('src1')" },
  { name: 'op-delete-src4', op: "deleteSource('src4')" },
  { name: 'op-delete-node', op: "deleteNode('src1', 'n2')" },
  { name: 'op-delete-profile', setup: "setConnectMode('profiles')", op: "editingProfileId = 'default'; deleteEditingProfile()" },
  { name: 'op-delete-profile-active', setup: "setConnectMode('profiles'); autoConnect = false; activeConnectId = 'gaming'", op: "editingProfileId = 'gaming'; deleteEditingProfile()" },
  { name: 'op-delete-chain', op: "editingChainId = 'sc1'; deleteEditingChain()" },
  { name: 'op-forget-gone', op: "forgetGone('src1')" },
  { name: 'op-forget-one', op: "forgetGone('src1', ['n19'])" },
  { name: 'op-purge-gone', setup: "sourcesData.src1.gone[1].goneAt = " + (T0 - 16 * 864e5), op: 'purgeExpiredGone()' },
  { name: 'op-enable-source', setup: 'sourcesData.src2.enabled = false', op: "enableSource('src2')" },
  { name: 'op-toggle-source', op: "toggleSourceEnabled('src2')" },
  { name: 'op-enable-node', setup: "sourcesData.src3.disabledNodes = ['n0', 'n1']", op: "enableNode('src3', 'n0')" },
  { name: 'op-toggle-node', op: "toggleNodeEnabled('src2', 'n1'); toggleNodeEnabled('src2', 'n8')" },
  { name: 'op-drag-route', op: "(() => { const [order, done] = dragShown(connectOrder, visibleOrder(), o => { if (o.join() !== connectOrder.join()) routeCustom[connectMode] = true; connectOrder = o; }); order().reverse(); done(); })()" },
  { name: 'op-drag-route-hidden', setup: 'sourcesData.src2.enabled = false', op: "(() => { const [order, done] = dragShown(connectOrder, visibleOrder(), o => { if (o.join() !== connectOrder.join()) routeCustom[connectMode] = true; connectOrder = o; }); order().reverse(); done(); })()" },
  { name: 'op-reset-order', setup: "routeCustom.simple = true; connectOrder = ['src3', 'src1', 'src4', 'src2', 'sc1']", op: 'resetRouteOrder()' },
  { name: 'op-route-custom-sync', setup: "routeCustom.simple = true; connectOrder = ['src3', 'src1', 'src4']", op: "sourcesData.src9 = { id: 'src9', kind: 'node', name: 'New', enabled: true, nodes: [{ id: 'n0', name: 'X', flag: '🇩🇪', protocol: 'vless', address: 'x.example', port: 443, outbound: { o: 'x' } }] }; sourceOrder.push('src9'); sourceAdded('src9')" },
  { name: 'op-route-node-drag', setup: "sourcesData.src1.pickMode = 'priority'; sourcesData.src1.pickOrder = ['src1::n4']", op: "(() => { const u = unitOwner('src1'), shown = unitPickRefs('src1').map(refKey), cur = u.pickOrder || []; const [order, done] = dragShown(cur.concat(shown.filter(k => !cur.includes(k))), shown, o => { u.pickOrder = o; }); order().reverse(); done(); })()" },
  { name: 'op-row-mode', op: "routeRowFocus = 'src2'; setRouteRowMode('priority')" },
];

const browser = await playwright.chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 400, height: 800 } });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await page.addInitScript(INIT);
  await page.goto(PAGE);
  await page.evaluate(() => { try { localStorage.clear(); } catch (e) {} });
  await page.waitForTimeout(350);
  await page.evaluate(LIB);
  const base = await page.evaluate(() => window.__G.init());
  const apps = await page.evaluate(() => window.__G.apps);
  const scenarios = [];
  for (const sc of SCENARIOS) {
    try { scenarios.push(await page.evaluate(s => window.__G.run(s), sc)); }
    catch (e) { console.error('scenario failed:', sc.name, e.message.split('\n')[0]); process.exitCode = 1; }
  }
  if (errors.length) console.error('page errors:', [...new Set(errors)].slice(0, 5));
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, JSON.stringify({ now: T0, apps, base, scenarios }));
  console.log(`${scenarios.length}/${SCENARIOS.length} scenarios -> ${OUT}`);
} finally {
  await browser.close();
}
