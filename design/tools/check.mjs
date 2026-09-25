// Smoke tests and screenshots for design/main_screen.html (headless Chromium).
//
//   node design/tools/check.mjs                 run all checks, print one line per failure
//   node design/tools/check.mjs shot home dock  screenshots into design/.shots/
//        options: --theme original|karing|github  --scale 1  --width 400 --height 800
//        presets: see SHOTS below
//
// Playwright is resolved from the global npm root (pre-installed in the cloud env).
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
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

async function openPage(browser, { width = 400, height = 800, scale = 1, theme } = {}) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: scale });
  page.setDefaultTimeout(5000);
  page.errors = [];
  page.on('pageerror', e => page.errors.push(e.message));
  // Fonts come from Google; offline they only slow the load down.
  await page.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await page.goto(PAGE);
  await page.evaluate(() => { try { localStorage.clear(); } catch (e) {} });
  if (theme) await page.evaluate(t => applyTheme(t), theme);
  await page.waitForTimeout(350);   // let initial transitions settle
  return page;
}

const settle = page => page.waitForTimeout(400);
const tab = (page, name) => page.click(`.nav-btn[data-tab=${name}]`);

/* ═══════════════ SCREENSHOT PRESETS ═══════════════ */

const SHOTS = {
  home:       async p => {},
  nodes:      async p => { await tab(p, 'nodes'); },
  'nodes-open': async p => { await tab(p, 'nodes'); await p.evaluate(() => { expandState[sourceOrder[0]] = true; goneOpen.add('nodes:' + sourceOrder[0]); renderNodes(); document.querySelector('#view-nodes .scroll').scrollTop = 520; }); },
  settings:   async p => { await tab(p, 'settings'); },
  dock:       async p => ({ clip: await clipOf(p, '.dock', 60) }),
  'broken': async p => { await p.evaluate(() => { sourcesData.src4.enabled = false; renderAll(); openProfiles(); }); await settle(p); },
  'dock-chain': async p => { await p.evaluate(() => { selectConnect('sc1'); }); return { clip: await clipOf(p, '.dock', 60) }; },
  'dock-profile': async p => { await p.evaluate(() => { setConnectMode('profiles'); selectConnect('default'); }); return { clip: await clipOf(p, '.dock', 60) }; },
  'dock-off': async p => { await p.click('#powerBtn'); await p.waitForTimeout(1000); return { clip: await clipOf(p, '.dock', 60) }; },
  profiles:   async p => { await p.click('.dock-profile'); await settle(p); },
  'profiles-full': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); }); await settle(p); },
  'profiles-menu': async p => { await p.evaluate(() => { openProfiles(); openProfilesMenu(); }); await settle(p); },
  'source-entry': async p => { await p.evaluate(() => { openProfiles(); openSourceEntry('src1'); }); await settle(p); },
  'simple-chain': async p => { await p.evaluate(() => { openProfiles(); openEditChain('sc1'); toggleCcOpen('out', chainDraft.outId); }); await settle(p); },
  'chain-priority': async p => { await p.evaluate(() => { openProfiles(); openEditChain('sc1'); toggleCcOpen('out', chainDraft.outId); }); await settle(p); },
  'gone': async p => { await p.evaluate(() => { openProfiles(); goneOpen.add('se:src1'); openSourceEntry('src1'); document.querySelector('#sh-sourceentry .sheet-body').scrollTop = 9999; }); await settle(p); },
  'nothing-ticked': async p => { await p.evaluate(() => { openProfiles(); openEditChain('sc1'); toggleCcOpen('in', 'src4'); setChainNodesAll('in'); }); await settle(p); },
  'profile-edit': async p => { await p.evaluate(() => { setConnectMode('profiles'); openProfiles(); openEditProfile('gaming'); }); await settle(p); },
  'drag-mid': async p => { await p.evaluate(() => { openProfiles(); setConnectEdit(true); }); await settle(p);
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
  rules:      async p => { await p.evaluate(() => openRules()); await settle(p); },
  'rules-more': async p => { await p.evaluate(() => { openRules(); document.getElementById('rules-body').scrollTop = 9999; }); await settle(p); },
  'rule-form': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); }); await settle(p); },
  'rule-new':  async p => { await p.evaluate(() => { openRules(); openRuleForm(); rfAddGroup('ip'); rfAddValues('domain', 'domain_suffix', 'youtube.com, bad domain', false); }); await settle(p); },
  'rule-json': async p => { await p.evaluate(() => { openRules(); openRuleForm('r4'); setRfTab('json'); }); await settle(p); },
  'rule-test': async p => { await p.evaluate(() => { openRules(); openRuleTest(); document.getElementById('rt-input').value = 'discord.com'; runRuleTest(); }); await settle(p); },
  'rule-order': async p => { await p.evaluate(() => { openRules(); openRuleOrder(); }); await settle(p); },
  'rule-io':   async p => { await p.evaluate(() => { openRules(); openRuleIO(); setRuleIO('export', 'clash'); }); await settle(p); },
  'rule-sets': async p => { await p.evaluate(() => { openRules(); openRuleSets(); }); await settle(p); },
  apps:       async p => { await p.evaluate(() => { openRules(); openApps(); }); await settle(p); },
  'app-act':  async p => { await p.evaluate(() => { openRules(); openApps(); openAppAct('com.discord'); }); await settle(p); },
  'settings-dns': async p => { await p.evaluate(() => openDnsSettings()); await settle(p); },
  'dns-form': async p => { await p.evaluate(() => { openDnsSettings(); openDnsForm(); }); await settle(p); },
  'settings-conn': async p => { await p.evaluate(() => { switchTab('settings'); openSheet('setconn'); }); await settle(p); },
  'nodes-profiles': async p => { await tab(p, 'nodes'); await p.evaluate(() => { setNodesTab('profiles'); expandState.default = true; renderNodes(); }); await settle(p); },
  'nodes-swipe': async p => { await tab(p, 'nodes'); await p.evaluate(() => { document.getElementById('view-nodes').classList.add('swiping'); renderNodesTabs(-170); }); },
  'route': async p => { await p.evaluate(() => { openProfiles(); setConnectEdit(true); }); await settle(p); },
  'entry-delete': async p => { await tab(p, 'nodes'); await p.evaluate(() => { setNodesTab('profiles'); confirmDeleteEntry('work'); }); await settle(p); },
  'target-picker': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); openTargetPicker(rulesData.r2.target, () => {}); tpOpen.add('src2'); renderTargetPicker(); }); await settle(p); },
  'rule-fallback': async p => { await p.evaluate(() => { openRules(); openRuleForm('r2'); document.querySelector('#sh-ruleform .sheet-body').scrollTop = 9999; }); await settle(p); },
  more:       async p => { await tab(p, 'nodes'); await p.evaluate(() => openNodesMore()); await settle(p); },
};

async function clipOf(page, sel, extraTop = 0) {
  const r = await page.locator(sel).boundingBox();
  return { x: 0, y: Math.max(0, r.y - extraTop), width: page.viewportSize().width, height: r.height + extraTop };
}

// --grid (or verify) glues the presets into one labelled .shots/grid.png, 4 per row:
// one image to look at instead of several.
async function shots(names, grid = args.includes('--grid')) {
  const browser = await playwright.chromium.launch();
  const dir = join(root, '.shots');
  mkdirSync(dir, { recursive: true });
  const cells = [];
  for (const name of names) {
    if (!SHOTS[name]) { console.log(`unknown preset "${name}". presets: ${Object.keys(SHOTS).join(', ')}`); continue; }
    const page = await openPage(browser, {
      width: +opt('width', 400), height: +opt('height', 800), scale: +opt('scale', 1), theme: opt('theme'),
    });
    const extra = (await SHOTS[name](page)) || {};
    const file = join(dir, name + (opt('theme') ? '-' + opt('theme') : '') + '.png');
    const buf = await page.screenshot({ path: grid ? undefined : file, ...extra });
    if (grid) cells.push([name, buf.toString('base64')]);
    if (!grid || page.errors.length) console.log((grid ? name : file) + (page.errors.length ? '   ERRORS: ' + page.errors.join(' | ') : ''));
    await page.close();
  }
  if (grid && cells.length) {
    const page = await browser.newPage({ viewport: { width: 400 * Math.min(4, cells.length) + 8, height: 100 } });
    await page.setContent(`<body style="margin:0;background:#000;display:flex;flex-wrap:wrap;gap:4px;padding:4px;width:${400 * 4 + 12}px;font:600 13px sans-serif;color:#fff">${
      cells.map(([n, b]) => `<div style="width:400px"><div style="padding:2px 4px">${n}</div><img style="display:block;width:400px" src="data:image/png;base64,${b}"></div>`).join('')}</body>`);
    const file = join(dir, 'grid.png');
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

  await check('nodes: search opens, filters, closes', async () => {
    await tab(page, 'nodes');
    expect(!(await page.isVisible('#nodeSearchBar')), 'search bar visible before opening');
    await page.click('#nodeSearchBtn');
    await page.keyboard.type('tokyo');
    const rows = await page.$$eval('.node-row .node-name', els => els.map(e => e.textContent));
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

  await check('profiles: dragging changes the Auto pick', async () => {
    const target = await page.evaluate(() => { setConnectEdit(true); return connectOrder.filter(id => connectEntry(id).inAuto && isUsable(id))[1]; });
    const g = await page.locator(`.conn-row[data-id=${target}] .drag-handle`).boundingBox();
    const top = await page.locator('.conn-row').first().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, top.y - 10, { steps: 8 }); await page.mouse.up(); await settle(page);
    expect(await page.evaluate(() => effectiveConnectId()) === target, 'auto pick did not follow the new order');
    await page.evaluate(() => setConnectEdit(false));
  });

  await check('route: own order after a drag, Nodes order stays, "Follow Nodes order" resets', async () => {
    const r = await page.evaluate(() => {
      const out = {}, m = connectMode;
      out.custom = routeCustom[m] && /Own priority order/.test(document.getElementById('routeOrderNote').textContent);
      out.nodesKept = connectOrder.join() !== catalogOrder[m].join();
      document.querySelector('#routeOrderNote .am-link').click();
      out.reset = !routeCustom[m] && connectOrder.join() === catalogOrder[m].join();
      out.noEdit = !document.querySelector('#connects-list .conn-row .icon-btn') && !document.querySelector('#sh-profiles .sheet-action');
      setConnectEdit(true);
      const id = connectOrder.find(x => !isBroken(x)), was = connectEntry(id).inAuto;
      document.querySelector(`#connects-list .conn-row[data-id=${id}] .route-auto .mini-toggle`).click();
      out.autoToggle = connectEntry(id).inAuto === !was;
      toggleEntryAuto(id); setConnectEdit(false);
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('simple mode is the default: sources and source chains in the list', async () => {
    expect(await page.evaluate(() => connectMode === 'simple'), 'not simple by default');
    const ids = await page.$$eval('.conn-row', r => r.map(el => el.dataset.id));
    expect(ids.includes('src1') && ids.includes('sc1') && !ids.includes('default') && !ids.includes('cpdefault'), ids.join());
    expect(/Servers/.test(await page.textContent('#profilesTitle')), 'title');
  });

  await check('simple mode: tap a source for Manual, second tap back to Auto', async () => {
    await page.click('.conn-row[data-id=src2] .conn-main'); await settle(page);
    expect(await page.evaluate(() => !autoConnect && effectiveConnectId() === 'src2'), 'source not pinned');
    await page.click('.conn-row[data-id=src2] .conn-main'); await settle(page);
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

  await check('⋯ menu switches to profiles mode, each mode keeps its own list', async () => {
    await page.click('#sh-profiles .sheet-head .icon-btn[title=More]'); await settle(page);
    await page.click('#actions-body .menu-row >> nth=1'); await settle(page);
    const ids = await page.$$eval('.conn-row', r => r.map(el => el.dataset.id));
    expect(ids.includes('default') && ids.includes('cpdefault') && !ids.includes('src1'), ids.join());
    expect(/Profiles/.test(await page.textContent('#profilesTitle')) && /Profile|Chain/.test(await page.textContent('#profCardLabel')), 'titles');
  });

  await check('profiles: tap sets Manual (sheet stays), second tap / badge back to Auto', async () => {
    expect(await page.evaluate(() => autoConnect), 'auto is not the default');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    expect(await page.evaluate(() => !autoConnect && effectiveConnectId() === 'work'), 'not pinned');
    expect(/MANUAL/.test(await page.textContent('#profModeBadge')), 'dock badge not MANUAL');
    expect(/Manual/.test(await page.textContent('#autoBadge')), 'sheet badge not Manual');
    expect(await page.evaluate(() => document.getElementById('sh-profiles').classList.contains('open')), 'sheet closed on pin');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    expect(await page.evaluate(() => autoConnect), 'second tap did not re-enable auto');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    await page.click('#autoBadge');
    expect(await page.evaluate(() => autoConnect), 'auto not re-enabled');
    await page.evaluate(() => closeSheet('profiles'));
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
    await page.click('#cc-out-hint .chip >> nth=1'); await settle(page);
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
      out.src = document.getElementById('profCardLabel').textContent === 'Sub' && !!det().querySelector('.dock-node') && !det().querySelector('.dock-src');
      chainsData.tc3 = { id:'tc3', name:'t3', inId:'src2', outId:'src1', inAuto:true, inOff:[], outOff:[], exitMode:'fastest', exitOrder:[] };
      catalogOrder.simple.push('tc3'); syncCatalog(); activeConnectId = 'tc3'; updateMainConnectCard();
      out.chain = document.getElementById('profCardLabel').textContent === 'Chain' && det().querySelectorAll('.dock-node').length === 2 && !!det().querySelector('.dock-arrow');
      delete chainsData.tc3; connectOrder = connectOrder.filter(x => x !== 'tc3'); activeConnectId = 'src1'; autoConnect = was;
      setConnectMode('profiles'); const pw = autoConnect; autoConnect = false; activeConnectId = 'default'; updateMainConnectCard();
      out.profile = document.getElementById('profCardLabel').textContent === 'Profile' && !!det().querySelector('.dock-src');
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

  await check('edit modes: Nodes and the list show grips / switches only while editing', async () => {
    const r = await page.evaluate(() => {
      const out = {}; switchTab('nodes'); expandState.src2 = true; renderNodes();
      const q = s => document.querySelector(s);
      out.viewClean = !q('#nodes-list .drag-handle') && !q('#nodes-list .mini-toggle') && !q('#nodes-list .node-row.pick');
      q('.src-card[data-id=src2] .node-row[data-nid=n0]').click();
      out.tapMenu = q('#sh-actions').classList.contains('open') && !isNodeDisabled(sourcesData.src2, 'n0'); closeSheet('actions');
      setNodesEdit(true);
      out.edit = !!q('#nodes-list .drag-handle') && !!q('#nodes-list .mini-toggle') && !!q('#nodes-list .node-row.pick') && q('#nodesEditBtn').textContent === 'Done';
      setNodesEdit(false); switchTab('home');
      openProfiles(); const was = autoConnect;
      out.listView = !q('#connects-list .drag-handle');
      setConnectEdit(true);
      out.listEdit = !!q('#connects-list .drag-handle');
      q('#connects-list .conn-row .conn-main').click();
      out.noPin = autoConnect === was;
      closeSheet('profiles');
      out.reset = !connectEdit;
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('Priority on entries: first working server by order; drag reorders', async () => {
    const r = await page.evaluate(() => {
      const out = {}, s = sourcesData.src2, live = liveNodes(s).filter(isAlive);
      openProfiles(); openSourceEntry('src2');
      out.fastest = unitNode('src2') === bestAlive(live);
      document.querySelectorAll('#se-mode .chip')[1].click();
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
      document.querySelectorAll('#cp-mode .chip')[1].click();
      out.cpOrder = document.querySelectorAll('#cp-order .node-row').length === cpDraftRefs().length;
      document.getElementById('cpSaveBtn').click();
      out.saved = profilesData.default.pickMode === 'priority' && unitNode('default') === unitPickRefs('default').map(r => r.node).find(isAlive);
      profilesData.default.pickMode = 'fastest';
      closeSheet('profiles'); setConnectMode('simple'); renderAll();
      return out;
    });
    expect(Object.values(r).concat(Object.values(r2)).every(Boolean), JSON.stringify([r, r2]));
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
        above: h.contains(top), all: [...document.querySelectorAll('.help-btn')].every(b => HELP[b.getAttribute('onclick').match(/'(\w+)'/)[1]]) };
      closeSheet('help'); closeSheet('sourceentry'); closeSheet('profiles');
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('Auto mode card opens Settings → Auto mode; settings apply; subscriptions default to auto', async () => {
    await page.click('#autoCard'); await settle(page);
    const r = await page.evaluate(() => {
      const out = {};
      out.open = document.getElementById('view-settings').classList.contains('active') && document.getElementById('sh-setauto').classList.contains('open') && !!document.querySelector('#auto-settings .set-group');
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
      const warmChips = () => [...document.querySelectorAll('#auto-settings .chip')].filter(e => /^next/.test(e.textContent)).length;
      setAutoCfg('keepWarm', false);
      out.warmOff = warmChips() === 0 && autoCfg.standby === 2;
      setAutoCfg('keepWarm', true);
      out.warmOn = warmChips() === 3;
      const sp = [...document.querySelectorAll('#auto-settings .set-row')].find(r => /Speed test on failures/.test(r.textContent));
      sp.querySelector('.mini-toggle').click();
      out.speed = autoCfg.speedOnFail === true; setAutoCfg('speedOnFail', false);
      for (let i = 0; i < 6; i++) document.querySelector('#am-failafter .stepper-btn:last-child').click();
      out.stepMax = autoCfg.failAfter === 4 && document.querySelector('#am-failafter .stepper-btn:last-child').disabled;
      for (let i = 0; i < 6; i++) document.querySelector('#am-failafter .stepper-btn').click();
      out.stepMin = autoCfg.failAfter === 1;
      setAutoCfg('failAfter', 2); setAutoCfg('checkEvery', 60);
      setAutoCfg('threshold', 50);
      closeSheet('setauto'); switchTab('home');
      openSrcForm('src1');
      out.auto = document.getElementById('sf-interval').value === '' && /auto · 12 h/.test(document.getElementById('sf-interval').placeholder);
      document.getElementById('sf-interval').value = '8'; saveSrcForm();
      out.own = sourcesData.src1.updateInterval === 8;
      openSrcForm('src1'); document.getElementById('sf-interval').value = ''; saveSrcForm();
      out.back = sourcesData.src1.updateInterval === 'auto';
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('ping cache: one result per server, shared by every view', async () => {
    const ok = await page.evaluate(async () => {
      const n = sourcesData.src1.nodes[0];
      await pingNodes([n]);
      return ping(n) === pingCache.get(serverKey(n)).ms && pingAge(n) < 5000;
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
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
  });

  await check('DNS: card opens Settings → DNS, pings, keeps one server, form validates, hijack note', async () => {
    await page.click('#dnsCard'); await settle(page);
    const r = await page.evaluate(async () => {
      const out = {};
      out.open = document.getElementById('view-settings').classList.contains('active') && document.getElementById('sh-setdns').classList.contains('open');
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
      rfOpenField('domain', 'domain_keyword');
      out.fold = !!document.querySelector('#rf-body input[data-f="domain_keyword"]');
      rfAddGroup('port'); rfAddValues('port', 'port', '443, 8000-9000', false);
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
      out.lan = testAddress('192.168.1.5').to === 'Direct';
      return out;
    });
    expect(Object.values(r).every(Boolean), JSON.stringify(r));
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
      appDraft.act = 'proxy'; appDraft.split = true; appDraft.udpTarget = 'profile:work'; renderAppAct();
      out.twoTargets = document.querySelectorAll('#aa-body .tgt-row').length === 2;
      saveAppAct();
      out.saved = appRules['com.whatsapp'].split && /UDP/.test(document.querySelector('.app-row[data-pkg="com.whatsapp"] .app-state').textContent);
      openAppAct('com.whatsapp'); appDraft.act = 'default'; saveAppAct();
      out.reset = !appRules['com.whatsapp'];
      closeSheet('apps'); closeSheet('rules');
      return out;
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
      openEntryActions(id);
      [...document.querySelectorAll('#actions-body .menu-row')].find(e => /Delete/.test(e.textContent)).click();
      out.impact = /Work network.*rule #\d.*loses its target/.test(body());
      document.querySelector('#actions-body .menu-row.danger').click();
      out.gone = !profilesData[id] && !catalogOrder.profiles.includes(id) && !modeOrder('profiles').includes(id);
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
      tpToggle(sourceOrder[0]);
      document.querySelector('#tp-body .tp-nodes .node-row').click();
      out.node = ruleDraft.target.startsWith('node:') && !document.getElementById('sh-target').classList.contains('open');
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
  await browser.close();

  const failed = results.filter(r => r[1]);
  for (const [name, err] of failed) console.log(`FAIL  ${name}: ${err}`);
  console.log(`${results.length - failed.length}/${results.length} checks passed`);
  return failed.length;
}

// shot <presets> — screenshots; verify [presets] — checks, then one grid of the presets.
if (positional[0] === 'shot') await shots(positional.slice(1).length ? positional.slice(1) : ['home']);
else {
  const failed = await runChecks();
  if (positional[0] === 'verify' && positional.length > 1) await shots(positional.slice(1), true);
  process.exit(failed ? 1 : 0);
}
