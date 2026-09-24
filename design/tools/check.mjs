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
  'nodes-open': async p => { await tab(p, 'nodes'); await p.evaluate(() => { expandState[sourceOrder[0]] = true; renderNodes(); }); },
  settings:   async p => { await tab(p, 'settings'); },
  dock:       async p => ({ clip: await clipOf(p, '.dock', 60) }),
  'dock-off': async p => { await p.click('#powerBtn'); await p.waitForTimeout(1000); return { clip: await clipOf(p, '.dock', 60) }; },
  profiles:   async p => { await p.click('.dock-profile'); await settle(p); },
  'profile-edit': async p => { await p.evaluate(() => { openProfiles(); openEditProfile('gaming'); toggleCpOpen('src4'); }); await settle(p); },
  'chain-edit': async p => { await p.evaluate(() => { openProfiles(); openEditChain('cpdefault'); testChainRoute(); }); await p.waitForTimeout(1800); },
  addmenu:    async p => { await tab(p, 'nodes'); await p.click('.icon-btn.primary'); await settle(p); },
  srcform:    async p => { await tab(p, 'nodes'); await p.evaluate(() => { openSrcForm(); toggleSrcAdvanced(true); }); await settle(p); },
  nodeform:   async p => { await tab(p, 'nodes'); await p.evaluate(() => openNodeForm()); await settle(p); },
  actions:    async p => { await tab(p, 'nodes'); await p.click('.src-card >> nth=0 >> button[title=More]'); await settle(p); },
  more:       async p => { await tab(p, 'nodes'); await p.evaluate(() => openNodesMore()); await settle(p); },
};

async function clipOf(page, sel, extraTop = 0) {
  const r = await page.locator(sel).boundingBox();
  return { x: 0, y: Math.max(0, r.y - extraTop), width: page.viewportSize().width, height: r.height + extraTop };
}

async function shots(names) {
  const browser = await playwright.chromium.launch();
  const dir = join(root, '.shots');
  mkdirSync(dir, { recursive: true });
  for (const name of names) {
    if (!SHOTS[name]) { console.log(`unknown preset "${name}". presets: ${Object.keys(SHOTS).join(', ')}`); continue; }
    const page = await openPage(browser, {
      width: +opt('width', 400), height: +opt('height', 800), scale: +opt('scale', 1), theme: opt('theme'),
    });
    const extra = (await SHOTS[name](page)) || {};
    const file = join(dir, name + (opt('theme') ? '-' + opt('theme') : '') + '.png');
    await page.screenshot({ path: file, ...extra });
    console.log(file + (page.errors.length ? '   ERRORS: ' + page.errors.join(' | ') : ''));
    await page.close();
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

  await check('header and bottom nav stay fixed while content scrolls', async () => {
    await tab(page, 'nodes');
    await page.evaluate(() => { sourceOrder.forEach(id => expandState[id] = true); renderNodes(); });
    const pos = () => page.evaluate(() => ['#view-nodes .topbar', '.bottomnav'].map(s => Math.round(document.querySelector(s).getBoundingClientRect().top)).join());
    const before = await pos();
    const scrolled = await page.evaluate(() => { const el = document.querySelector('#view-nodes > .scroll'); el.scrollTop = 1e5; return el.scrollTop; });
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
      sourcesData[sourceOrder[0]].nodes.filter(n => n.latency === 'testing').length,
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
    await page.evaluate(() => { sourceOrder.forEach(id => expandState[id] = false); renderNodes(); });
    const last = await page.evaluate(() => sourceOrder[sourceOrder.length - 1]);
    const g = await page.locator('.src-card').last().locator('.drag-handle').boundingBox();
    const first = await page.locator('.src-card').first().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2);
    await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, first.y - 20, { steps: 8 });
    await page.mouse.up();
    expect(await page.evaluate(() => sourceOrder[0]) === last, 'order: ' + await page.evaluate(() => sourceOrder.join()));
  });

  await check('nodes: grip centred on subscription block', async () => {
    const off = await page.evaluate(() => [...document.querySelectorAll('.src-card')].map(c => {
      const t = c.querySelector('.src-top').getBoundingClientRect(), g = c.querySelector('.src-top > .drag-handle svg').getBoundingClientRect();
      return Math.abs((t.top + t.height / 2) - (g.top + g.height / 2));
    }));
    expect(off.every(d => d < 1.5), 'offsets ' + off.join());
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
    const target = await page.evaluate(() => connectOrder.filter(id => connectEntry(id).inAuto && isUsable(id))[1]);
    const g = await page.locator(`.conn-row[data-id=${target}] .drag-handle`).boundingBox();
    const top = await page.locator('.conn-row').first().boundingBox();
    await page.mouse.move(g.x + g.width / 2, g.y + g.height / 2); await page.mouse.down();
    await page.mouse.move(g.x + g.width / 2, top.y - 10, { steps: 8 }); await page.mouse.up();
    expect(await page.evaluate(() => effectiveConnectId()) === target, 'auto pick did not follow the new order');
  });

  await check('profiles: tap pins (sheet stays), second tap / Auto badge unpins', async () => {
    expect(await page.evaluate(() => autoConnect), 'auto is not the default');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    expect(await page.evaluate(() => !autoConnect && effectiveConnectId() === 'work'), 'not pinned');
    expect(/PINNED/.test(await page.textContent('#profModeBadge')), 'dock badge not PINNED');
    expect(await page.evaluate(() => document.getElementById('sh-profiles').classList.contains('open')), 'sheet closed on pin');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    expect(await page.evaluate(() => autoConnect), 'second tap did not re-enable auto');
    await page.click('.conn-row[data-id=work] .conn-main'); await settle(page);
    await page.click('#autoBadge');
    expect(await page.evaluate(() => autoConnect), 'auto not re-enabled');
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('profiles: editor sets a fixed node and Auto participation', async () => {
    await page.evaluate(() => { openProfiles(); openEditProfile('work'); }); await settle(page);
    await page.click('#cp-mode .chip >> nth=1');
    await page.click('#cp-fixed-row'); await settle(page);
    await page.click('#pickmanualnode-list .pick-row >> nth=2'); await settle(page);
    await page.click('#cp-inauto');
    await page.click('#cpSaveBtn');
    const p = await page.evaluate(() => profilesData.work);
    expect(!p.autoSelect && p.manualNodeId && !p.inAuto, JSON.stringify(p));
    expect(await page.$eval('.conn-row[data-id=work]', el => /fixed/i.test(el.textContent) && /not in auto/i.test(el.textContent)), 'row does not show fixed / not in Auto');
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('profile editor: expand a source, ping it, pick a fixed node from its list', async () => {
    await page.evaluate(() => { openProfiles(); openEditProfile('default'); }); await settle(page);
    await page.click('.ps-card[data-id=src1] .ps-main');
    expect(await page.$$eval('.ps-card[data-id=src1] .node-row', r => r.length) > 0, 'nodes not shown');
    await page.click('.ps-card[data-id=src1] button[title="Ping all"]');
    expect(await page.$$eval('.ps-card[data-id=src1] .lat.testing', r => r.length) > 0, 'ping did not start');
    await page.waitForFunction(() => !document.querySelector('.ps-card[data-id=src1] .lat.testing'));
    await page.click('#cp-mode .chip >> nth=1');
    await page.click('.ps-card[data-id=src1] .node-row >> nth=1');
    expect(await page.evaluate(() => cpDraft.manualNodeId === 'src1::' + sourcesData.src1.nodes[1].id), 'tap did not fix the node');
    await page.evaluate(() => { closeSheet('createprofile'); closeSheet('profiles'); });
  });

  await check('chain editor: same entry/exit blocked, route check reports exits', async () => {
    await page.evaluate(() => { sourcesData.src1.nodes.forEach(n => n.latency = 50); openProfiles(); openEditChain('cpdefault'); }); await settle(page);
    const inId = await page.evaluate(() => chainDraft.inId);
    const idx = await page.evaluate(id => getProfileIds().indexOf(id), inId);
    await page.click(`#cc-out-list .pick-row >> nth=${idx}`, { force: true });
    expect(await page.evaluate(() => chainDraft.inId !== chainDraft.outId), 'exit could be set to the entry');
    await page.click('#cc-test .btn-secondary');
    await page.waitForFunction(() => chainDraft.test && !chainDraft.test.running);
    expect(/reachable|will not connect/.test(await page.textContent('#cc-test')), 'no route summary');
    await page.click('#ccSaveBtn');
    expect(await page.evaluate(() => typeof chainsData.cpdefault.test.reachable === 'number'), 'result not saved');
    await page.evaluate(() => closeSheet('profiles'));
  });

  await check('every sheet opens and closes', async () => {
    const ids = await page.$$eval('.sheet', els => els.map(e => e.id.slice(3)));
    for (const id of ids) await page.evaluate(id => { openSheet(id); closeSheet(id); }, id);
    expect(!page.errors.length, page.errors.join(' | '));
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
  process.exit(failed.length ? 1 : 0);
}

if (positional[0] === 'shot') await shots(positional.slice(1).length ? positional.slice(1) : ['home']);
else await runChecks();
