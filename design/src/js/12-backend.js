/* ══════════════════════ BACKEND SEAM ══════════════════════
   Everything the UI asks the core for goes through `backend`. Here it is faked; when
   the page is served by the Dart core (core/bin/jormd.dart sets window.JORMD),
   95-live.js swaps in the real one. (Flutter: the service layer over jormungand_core —
   SubscriptionService, PingService, ConnectionService.) */

const wait = ms => new Promise(r => setTimeout(r, ms));

let mockKill = null;   // the last kill switch settings the mock "core" got
let backend = {
  live: false,
  // First fetch of a new subscription: fills s.nodes (and usage / expire).
  // The mock fails any URL with "fail" in it, to show the error state of a source card.
  fetchSource(s) {
    return wait(1200).then(() => {
      mockFetchFails(s);
      s.nodes = genNodes(8 + Math.floor(Math.random() * 20), 'sub');
      s.usage = { used: 0, total: 0 };
      s.updatedAt = Date.now();
    });
  },
  // Update: new s.nodes, dropped servers into s.gone (see connect-model.md → gone), the
  // provider's headers (usage, expire, format, announce…), s.updatedAt. opts.rediscover:
  // ask with every User-Agent again (the core; the mock just updates).
  updateSource(s, opts) {
    return wait(900 + Math.random() * 600).then(() => { mockFetchFails(s); if (s.demoChurn) demoProviderChurn(s, opts); s.updatedAt = Date.now(); });
  },
  // Servers added by hand (32-nodes-forms.js): every link in f.link (one per line), else one
  // from the fields; f.edit = the server being edited (it keeps its id). Resolves to the
  // nodes, or rejects with a message. The mock id hashes the server, so the same one twice is caught.
  manualNodes(f) {
    let got;
    if (f.link) {
      got = splitLinks(f.link).map(parseShareLinkLite).filter(Boolean)
        .map(p => Object.assign({}, p, splitFlagLite(p.name || p.address + ':' + p.port)));
      if (!got.length) return Promise.reject(new Error(LINK_FORMS));
      if (got.length === 1) typedName(got[0], f);
    } else {
      const sameProto = f.edit && f.edit.protocol === f.protocol;
      got = [typedName({ flag: f.edit ? f.edit.flag : '🌐', name: f.address, protocol: f.protocol, address: f.address, port: f.port,
        secret: f.secret || (sameProto ? f.edit.secret : ''), reality: sameProto && f.edit.reality }, f)];
    }
    if (f.edit) return Promise.resolve([Object.assign({}, got[0], { id: f.edit.id })]);
    return Promise.resolve(got.map(p => Object.assign({ id: mockNodeId(p) }, p)));
  },
  // Latency of each node; onResult(n, ms) as each lands (ms -1 = timeout).
  ping(nodes, onResult) {
    return Promise.all(nodes.map(n => wait(300 + Math.random() * 1400).then(() => onResult(n, mockPing(n)))));
  },
  // One exit through one entry (sing-box: the exit outbound detoured via the entry).
  pingPair(entry, exit) {
    return wait(250 + Math.random() * 700).then(() => mockPairPing(entry, exit));
  },
  // like the core: the exit is checked again after every connect
  connect()    { exitInfo = null; return wait(1100).then(() => {
    exitInfo = { ip: '91.108.4.12', country: 'DE', city: 'Frankfurt' };
    vpn.blocking = null;
    mockEventAdd('conn', 'connected', 'info', { entry: effectiveConnectId(), mode: segState.mode, route: segState.route }, { own: true, raw: 'Connected: ' + entryLabel(effectiveConnectId()) });
  }); },
  // Kill switch + "Also after I disconnect": the core keeps the system proxy, status.blocking says so.
  disconnect() {
    mockEventAdd('conn', 'disconnected', 'info', { by: 'user' }, { own: true });
    vpn.blocking = connCfg.killSwitch && connCfg.killOnDisconnect ? { since: Date.now(), reason: 'disconnect', proxy: 'kept' } : null;
    renderConnState();
    return Promise.resolve();
  },
  // The down alert / the blocking plaque: POST /api/sysproxy/release (restore the saved system proxy now)
  // and POST /api/retry (try a restart right now). The mock recovers on Retry.
  releaseSysProxy() { mockEventAdd('core', 'sysProxy', 'info', { on: false, by: 'user' }, { own: true }); return Promise.resolve(); },
  // POST /api/killswitch: while down the proxy follows the new settings (a released one stays released).
  killSettings(cfg) {
    mockKill = cfg;
    if (vpn.down && vpn.down.proxy !== 'released') vpn.down.proxy = cfg.killSwitch || cfg.downProxy === 'keep' ? 'kept' : 'removed';
    // the setting that justified a block is off now: the proxy goes, the block with it (as the core does)
    const b = vpn.blocking;
    if (b && !(cfg.killSwitch && (b.reason === 'closed' ? cfg.killWhileClosed : cfg.killOnDisconnect))) vpn.blocking = null;
    renderConnState();
    return Promise.resolve();
  },
  // POST /api/dns/auto {auto}: Settings → DNS → Switch automatically while connected (the core
  // puts the first server back at once when it is turned off). The mock derives the server in
  // use from the pings (56-dns.js dnsHealth), so there is nothing to keep here.
  dnsAuto(on) { return Promise.resolve(); },
  retry() {
    return wait(700).then(() => {
      const downMs = vpn.down ? Date.now() - vpn.down.since : 0;
      vpn.down = vpn.recovering = null;
      mockEventAdd('core', 'restarted', 'info', { attempt: 4, downMs });
    });
  },
  // Settings → Auto mode changed while connected: the core's Auto takes it as is (no reconnect).
  autoSettings(auto) { return Promise.resolve(); },
  // Live traffic (see renderTraffic): the mock keeps the numbers the cards show.
  // out = where each connection really goes, exit first (the core gives 'proxy/<sid::nid>' tags).
  traffic() {
    const id = effectiveConnectId(), c = chainsData[id];
    const out = c ? [chainExitNode(c), chainEntryNode(c)].filter(Boolean) : id ? [unitNode(id)].filter(Boolean) : [];
    const MB = 1048576, ago = s => new Date(Date.now() - s * 1000).toISOString();
    // rule = sing-box's own text of the matched rule (the conditions only; '' = no rule: final), o = what the core
    // makes of it (traffic.dart): [ruleKind, ruleName, ruleId]. undefined = by the route (final through the server /
    // the private-networks rule for direct)
    const PRIVATE = 'domain_suffix=[local localhost lan...] ip_is_private=true';
    const conn = (host, port, net, via, process, downRate, down, s, rule, id, o) => {
      if (rule === undefined) rule = via === out ? '' : PRIVATE;
      if (!o) o = !rule ? ['final', ''] : rule === PRIVATE ? ['system', 'Private networks', 'private'] : ['', ''];
      return { id: id || host, host, port, net, rule, ruleKind: o[0], ruleName: o[1], ...(o[2] ? { ruleId: o[2] } : {}), out: via.length ? via : ['direct'], process, down, up: down / 20 | 0, downRate, upRate: downRate / 30 | 0, start: ago(s) };
    };
    const YT = ['service', 'YouTube', 'youtube'], TG = ['service', 'Telegram', 'telegram'], REGION = ['quick', 'My region direct', 'region'];
    const YT_RULE = 'domain_suffix=[youtube.com googlevideo.com ytimg.com...]', TG_RULE = 'domain_suffix=[telegram.org t.me telegram.me...] || rule_set=geosite-telegram || rule_set=geoip-telegram';
    const RU_RULE = 'domain_suffix=[ru xn--p1ai su] || rule_set=[geosite-category-ru geosite-ru-available-only-inside] || rule_set=geoip-ru';
    // a chain-like route for the extra rows: the second server of the first source as an entry, when there is one
    const alt = (sourcesData[sourceOrder[0]] || { nodes: [] }).nodes.slice(-1).map(n => ({ ...n }))[0];
    const CH = 'C:\\Program Files\\', altOut = alt && out.length ? [alt, ...out.slice(0, 1)] : out;
    return Promise.resolve({ running: true, down: 48.3 * MB, up: 6.1 * MB, downTotal: 1.84 * 1024 * MB, upTotal: 312 * MB, tcp: 43, udp: 8, conns: [
      conn('googlevideo.com', '443', 'tcp', out, 'C:\\Program Files\\Google\\Chrome\\chrome.exe', 3.2 * MB, 410 * MB, 95),
      conn('api.github.com', '443', 'tcp', out, 'C:\\Code\\Code.exe', 4096, 2 * MB, 40),
      conn('192.168.0.1', '53', 'udp', [], 'C:\\Windows\\System32\\svchost.exe', 0, 900, 3),
      conn('discord.com', '443', 'tcp', out, 'C:\\Discord\\Discord.exe', 128 * 1024, 30 * MB, 600, 'network=tcp package_name=com.discord', undefined, ['app', 'Discord (TCP)', 'com.discord']),
      // older ones, for the list tools: other apps, rules, chains, UDP, addresses, no app
      conn('rr3.googlevideo.com', '443', 'tcp', out, 'C:\\Program Files\\Google\\Chrome\\chrome.exe', 1.1 * MB, 120 * MB, 700, YT_RULE, undefined, YT),
      conn('www.youtube.com', '443', 'udp', out, 'C:\\Program Files\\Google\\Chrome\\chrome.exe', 512 * 1024, 60 * MB, 900, YT_RULE, 'www.youtube.com/udp', YT),
      conn('t.me', '443', 'tcp', altOut, 'C:\\Telegram\\Telegram.exe', 64 * 1024, 8 * MB, 1200, TG_RULE, undefined, TG),
      conn('149.154.167.51', '443', 'tcp', altOut, 'C:\\Telegram\\Telegram.exe', 20 * 1024, 3 * MB, 1300, TG_RULE, undefined, TG),
      conn('wiki.corp.local', '443', 'tcp', [], 'C:\\Program Files\\Mozilla Firefox\\firefox.exe', 40 * 1024, 6 * MB, 1000, 'domain_suffix=[corp.local intra.example.com]', undefined, ['user', 'Work network', 'r1']),
      conn('us-east42.discord.media', '443', 'udp', altOut, 'C:\\Discord\\Discord.exe', 96 * 1024, 12 * MB, 1100, 'network=udp domain_suffix=[discord.gg discord.media]', undefined, ['user', 'Discord voice', 'r2']),
      conn('gitlab.com', '22', 'tcp', out, 'C:\\Program Files\\Git\\usr\\bin\\ssh.exe', 2048, 400 * 1024, 1500, ''),
      conn('mirror.yandex.ru', '443', 'tcp', [], 'C:\\Program Files\\Mozilla Firefox\\firefox.exe', 6 * MB, 800 * MB, 1800, RU_RULE, undefined, REGION),
      conn('vk.com', '443', 'tcp', [], 'C:\\Program Files\\Mozilla Firefox\\firefox.exe', 256 * 1024, 40 * MB, 2000, RU_RULE, undefined, REGION),
      conn('1.1.1.1', '443', 'tcp', out, '', 1024, 200 * 1024, 2200, ''),
      conn('224.0.0.251', '5353', 'udp', [], 'C:\\Windows\\System32\\svchost.exe', 0, 3000, 2600, undefined, '224.0.0.251/udp'),
      conn('fe80::1', '53', 'udp', [], '', 0, 1200, 2800, undefined, 'fe80::1/udp'),
      conn('cdn.discordapp.com', '443', 'tcp', out, 'C:\\Discord\\Discord.exe', 900 * 1024, 90 * MB, 3000, ''),
    ].filter(c => !(Date.now() - (mockClosed.get(c.id) || mockClosed.get('*') || 0) < 15000)) });
  },
  exitIp() { return wait(600).then(() => connected ? { ip: '91.108.4.12', country: 'DE', city: 'Frankfurt' } : { ip: '178.66.12.201', country: 'RU', city: 'Moscow' }); },
  // Close one live connection (Clash API DELETE /connections/{id}), or all with no id.
  // The mock hides them for a while — apps open new ones.
  closeConn(id) {
    mockClosed.set(id || '*', Date.now());
    return Promise.resolve();
  },
  // Speed Test through one server: onProgress({phase 0 latency / 1 download / 2 upload / 3 done,
  // down, up (bit/s), latency (ms), downRpm, final, error?}) as it goes; stops on signal.
  // sing-box's network quality test: latency, then download and upload at once (the steps
  // interleave phase 1 / 2), phase 3 + final at the end (core: runtime.dart speedTest).
  speedTest(n, onProgress, signal) {
    const ms = truthOf(n), down = 40e6 + Math.random() * 80e6, up = down * (0.25 + Math.random() * 0.2);
    let p = { phase: 0, down: 0, up: 0, latency: 0, downRpm: 0, elapsed: 0 };
    const step = async s => { await wait(250); if (signal.aborted) throw new DOMException('stopped', 'AbortError'); onProgress(p = { ...p, ...s, elapsed: p.elapsed + 1000 }); };
    return (async () => {
      if (ms < 0) { await wait(1500); if (!signal.aborted) onProgress({ ...p, elapsed: 5000, final: true, error: 'fetch config: Get "https://mensura.cdn-apple.com/api/v1/gm/config": net/http: TLS handshake timeout' }); return; }
      for (let i = 1; i <= 3; i++) await step({ latency: Math.round(ms * (1.3 - i * .1)) });
      for (let i = 1; i <= 16; i++) {
        const f = Math.min(1, i / 9) * (0.92 + Math.random() * 0.12);
        await step(i % 2 ? { phase: 1, down: down * f, downRpm: i > 4 ? Math.round(60000 / Math.max(ms, 20) * .4) : 0 } : { phase: 2, up: up * f });
      }
      onProgress({ ...p, phase: 3, final: true });
    })();
  },
  // A server's share link (vless://…), null when it has none (core: share.dart).
  shareLink(n) { return Promise.resolve(mockShareLink(n)); },
  // Logs tab: lines numbered `since` and later, and the number of the next one (core: logbook.dart).
  log(since) {
    mockLogTick();
    return Promise.resolve({ lines: mockLog.lines.filter(l => since == null || l.n >= since), next: mockLog.n });
  },
  clearLog() { mockLog.lines = []; return Promise.resolve(); },
  // Events journal (core: contract in docs/core.md): the events with id >= since (none given:
  // the last 200), oldest first; next = the id the next event gets, first = the oldest id
  // still kept. The UI adds its own (subscription results, user actions) and clears.
  events(since) { return Promise.resolve(mockEventsGet(since)); },
  addEvent(ev) { return Promise.resolve({ id: mockEventAdd(ev.cat, ev.type, ev.level || 'info', ev.data || {}, { own: ev.own }).id }); },
  clearEvents() { mockEvSeed(); mockEv.list = []; return Promise.resolve(); },
  // Settings → Data → About: versions and where the core keeps its data (mock: no core).
  version() { return Promise.resolve({ core: null, singBox: null, dataDir: null }); },
  // Backup: the state snapshot the core stores (95-live.js liveSnapshot), and back.
  exportState() { return Promise.resolve(liveSnapshot()); },
  importState(snap) { liveApply(snap); return Promise.resolve(); },
};

/* ── Mock data behind the seam ── */

function mockFetchFails(s) {
  if (/fail/i.test(s.url || '')) throw new Error('Connection timed out (15 s)');
}
const mockClosed = new Map();   // connection id → when it was closed (hidden for 15 s)
function mockNodeId(p) {
  let h = 5381;
  for (const c of [p.protocol, p.address, p.port, p.secret].join('|')) h = ((h * 33) ^ c.charCodeAt(0)) >>> 0;
  return 'm' + h.toString(36);
}
function mockShareLink(n) {
  if (n.unsupported) return null;
  const host = /:/.test(n.address) ? '[' + n.address + ']' : n.address;
  const name = '#' + encodeURIComponent((n.flag && n.flag !== '🌐' ? n.flag + ' ' : '') + n.name);
  const uuid = n.secret || '8c1f3a52-7d0e-4e2b-9d71-5b2e0c6f91d4', pw = encodeURIComponent(n.secret || 'tJ3vQx9pLm2');
  const sni = 'sni=' + (/^[\d.]+$/.test(n.address) ? 'www.microsoft.com' : n.address);
  switch (n.protocol) {
    case 'vless': return `vless://${uuid}@${host}:${n.port}?encryption=none&` + (n.reality
      ? 'flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba85179&type=tcp'
      : `security=tls&${sni}&fp=chrome&type=ws&path=%2Fws&host=${n.address}`) + name;
    case 'vmess': return 'vmess://' + btoa(unescape(encodeURIComponent(JSON.stringify({ v: '2', ps: n.name, add: n.address, port: String(n.port),
      id: uuid, aid: '0', scy: 'auto', net: 'ws', type: 'none', host: n.address, path: '/vm', tls: 'tls', sni: n.address }))));
    case 'ss': return `ss://${btoa('chacha20-ietf-poly1305:' + (n.secret || 'tJ3vQx9pLm2')).replace(/=+$/, '')}@${host}:${n.port}${name}`;
    case 'hy2': return `hysteria2://${pw}@${host}:${n.port}?${sni}&obfs=salamander&obfs-password=k8Qw2${name}`;
    case 'tuic': return `tuic://${uuid}:${pw}@${host}:${n.port}?congestion_control=bbr&alpn=h3&${sni}${name}`;
    case 'socks': {
      const [u = '', p = ''] = (n.secret || '').split(/:(.*)/);
      return `socks5://${u || p ? encodeURIComponent(u) + ':' + encodeURIComponent(p) + '@' : ''}${host}:${n.port}${name}`;
    }
    default: return `${n.protocol}://${pw}@${host}:${n.port}?${sni}${name}`;   // trojan, anytls
  }
}

// Logs: plausible sing-box output — its start, then traffic lines while connected.
const mockLog = { n: 0, lines: [], seeded: false };
function mockLogAdd(src, lvl, msg, t) {
  const n = mockLog.n++;
  mockLog.lines.push({ n, t: t || Date.now(), src, lvl, msg });
  if (mockLog.lines.length > 2000) mockLog.lines.shift();
  return n;
}
function mockLogLine() {
  const hosts = ['googlevideo.com:443', 'api.github.com:443', 'discord.com:443', 'gateway.discord.gg:443', 'www.youtube.com:443', 'update.googleapis.com:443', 'telegram.org:443'];
  const host = hosts[Math.floor(Math.random() * hosts.length)], id = 1e9 + Math.floor(Math.random() * 3e9), ms = Math.floor(Math.random() * 90);
  const n = unitNode(effectiveConnectId()), r = Math.random();
  if (r < 0.04) return ['error', `[${id} 5.0s] connection: open outbound connection: dial tcp 185.22.14.61:443: i/o timeout`];
  if (r < 0.1) return ['warn', `[${id} ${ms}ms] outbound/urltest[proxy]: outbound/vless[proxy/src2::n4]: context deadline exceeded`];
  if (r < 0.3) return ['info', `[${id} 0ms] inbound/mixed[mixed-in]: inbound connection from 127.0.0.1:${50000 + Math.floor(Math.random() * 9000)}`];
  if (r < 0.4) return ['info', `[${id} 0ms] router: found process path: C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe`];
  if (r < 0.5) return ['info', `[${id} 1ms] outbound/direct[direct]: outbound connection to 192.168.0.1:53`];
  if (r < 0.75) return ['info', `[${id} ${ms}ms] inbound/mixed[mixed-in]: inbound connection to ${host}`];
  return ['info', `[${id} ${ms}ms] outbound/${n ? n.protocol : 'vless'}[proxy/${n ? n.name : 'server'}]: outbound connection to ${host}`];
}
function mockLogTick() {
  if (!mockLog.seeded) {
    mockLog.seeded = true;
    const start = Date.now() - 95e3, port = connCfg.port || 2080;
    mockLogAdd('core', 'info', 'Connected: unit, proxy on 127.0.0.1:' + port, start);
    mockLogAdd('sing-box', 'info', 'network: updated default interface Ethernet, index 12', start + 40);
    mockLogAdd('sing-box', 'info', 'inbound/mixed[mixed-in]: tcp server started at 127.0.0.1:' + port, start + 80);
    mockLogAdd('sing-box', 'info', 'sing-box started (0.31s)', start + 120);
    for (let i = 0; i < 44; i++) { const [lvl, msg] = mockLogLine(); mockLogAdd('sing-box', lvl, msg, start + 2000 + i * 2100); }
  }
  if (!connected || connecting) return;
  for (let k = Math.floor(Math.random() * 4); k > 0; k--) { const [lvl, msg] = mockLogLine(); mockLogAdd('sing-box', lvl, msg); }
}

/* Events: a journal seeded with a believable history (yesterday and today, every category,
   the user's own actions too), then now and then a new one while connected. Ids and names
   come from the catalog as it is, so the rows resolve to real entries. */
const mockEv = { n: 1, list: [], seeded: false, lastRand: 0 };
// opts: own, at, raw (a line the core writes to the raw log at the same moment → ev.log)
function mockEventAdd(cat, type, level, data, opts) {
  mockEvSeed();
  const o = opts || {}, ev = { id: mockEv.n++, at: o.at || Date.now(), cat, type, level, own: !!o.own, data: data || {} };
  if (o.raw) { mockLogTick(); ev.log = mockLogAdd('core', level, o.raw); }
  else if (o.log != null) ev.log = o.log;
  mockEv.list.push(ev);
  if (mockEv.list.length > 1000) mockEv.list.shift();
  return ev;
}
function mockEvSeed() {
  if (mockEv.seeded) return;
  mockEv.seeded = true;
  mockLogTick();
  const ids = visibleOrder(), a = ids[0] || 'src1', b = ids[1] || a;
  const sid = sourceOrder.find(x => sourcesData[x].kind === 'sub') || 'src1', s = sourcesData[sid] || { name: 'Subscription', nodes: [] };
  const key = i => sid + '::' + ((s.nodes && s.nodes.length ? s.nodes[i % s.nodes.length] : { id: 'n' + i }).id);
  const now = Date.now(), d0 = new Date().setHours(0, 0, 0, 0);
  const warn = mockLog.lines.find(l => l.lvl === 'warn'), n0 = mockLog.lines[0];
  const Y = h => d0 - h * 36e5, M = m => Math.max(d0 + 1000, now - m * 6e4);
  const total = (s.nodes || []).length || 12;
  const bn = sourcesData[b] && sourcesData[b].nodes && sourcesData[b].nodes[0];
  const blocked = { host: 'rutracker.org', dest: 'rutracker.org:443', entry: a, server: key(0), route: a, via: b, viaServer: bn ? b + '::' + bn.id : undefined };
  const list = [
    [Y(15.5), 'user', 'connect', 'info', { action: 'connect', entry: a }, 1],
    [Y(15.5) + 500, 'conn', 'connected', 'info', { entry: a, mode: 'tun', route: 'rules' }],
    [Y(14), 'auto', 'switched', 'info', { from: a, to: b, reason: 'failover', fails: 3 }],
    [Y(13.9), 'site', 'blocked', 'warn', blocked], [Y(13.85), 'site', 'blocked', 'warn', blocked], [Y(13.8), 'site', 'blocked', 'warn', blocked],
    [Y(12), 'sub', 'updated', 'info', { source: sid, name: s.name, added: 2, removed: 0, total }],
    [Y(9), 'conn', 'lost', 'warn', {}], [Y(8.9), 'conn', 'restored', 'info', { downMs: 41000 }],
    [Y(6), 'sub', 'failed', 'error', { source: sid, name: s.name, error: 'Connection timed out (15 s)' }],
    [Y(5.95), 'sub', 'failed', 'error', { source: sid, name: s.name, error: 'Connection timed out (15 s)' }],
    [Y(5), 'rules', 'ruleSetFailed', 'warn', { tag: 'geosite-ru', url: 'https://example.net/rules/geosite-ru.srs', error: 'HTTP 503' }],
    [Y(2), 'user', 'pin', 'info', { action: 'pin', entry: a, server: key(1) }, 1],
    [Y(1), 'user', 'disconnect', 'info', { action: 'disconnect' }, 1], [Y(1) + 500, 'conn', 'disconnected', 'info', { by: 'user' }],
    [M(200), 'user', 'connect', 'info', { action: 'connect', entry: a }, 1],
    [M(200) + 500, 'conn', 'connected', 'info', { entry: a, mode: 'tun', route: 'rules' }, 0, n0 && n0.n],
    [M(170), 'user', 'mode', 'info', { action: 'mode', value: 'tun' }, 1], [M(160), 'user', 'route', 'info', { action: 'route', value: 'rules' }, 1],
    [M(150), 'sub', 'updated', 'info', { source: sid, name: s.name, added: 0, removed: 1, total }],
    [M(95), 'auto', 'fastest', 'info', { route: a, from: key(0), to: key(2) }],
    [M(60), 'core', 'sysProxy', 'warn', { on: true, error: 'Access is denied' }],
    [M(45), 'user', 'sysProxy', 'info', { action: 'sysProxy', on: true }, 1],
    [M(30), 'sub', 'dead', 'error', { source: sid, name: s.name }],
    [M(20), 'core', 'crashed', 'error', { code: 1 }], [M(19.9), 'core', 'restarted', 'info', { attempt: 1 }],
    [M(12), 'auto', 'unstable', 'warn', { id: b, strikes: 2, holdMs: 120000 }, 0, warn && warn.n],
    [M(8), 'sub', 'removed', 'warn', { source: sid, name: s.name, count: 2 }],
    [M(3), 'conn', 'offline', 'warn', {}], [M(2.5), 'conn', 'online', 'info', { downMs: 30000 }],
  ].sort((x, y) => x[0] - y[0]);
  list.forEach(([at, cat, type, level, data, own, log]) => mockEventAdd(cat, type, level, data, { at, own, log }));
  // a first run has seen everything but the last hour
  logCfg.seen = mockEv.list.filter(e => e.level !== 'info' && e.at < now - 36e5).map(e => e.id);
}
// A new event now and then while connected (not under automation: tests add their own).
function mockEventsGet(since) {
  mockEvSeed();
  if (connected && !connecting && !navigator.webdriver && Date.now() - mockEv.lastRand > 20000 && Math.random() < .5) {
    mockEv.lastRand = Date.now();
    const ids = visibleOrder(), a = ids[0], b = ids[1] || a, r = Math.random();
    if (r < .4) mockEventAdd('auto', 'switched', 'info', { from: a, to: b, reason: 'failover', fails: 3 }, { raw: 'Auto: switched ' + entryLabel(a) + ' → ' + entryLabel(b) });
    else if (r < .7) mockEventAdd('site', 'blocked', 'warn', { host: 'discord.com', dest: 'discord.com:443', entry: a, route: a, via: b }, { raw: 'discord.com:443 does not open via ' + entryLabel(a) });
    else mockEventAdd('auto', 'unstable', 'warn', { id: a, strikes: 2, holdMs: 120000 }, { raw: entryLabel(a) + ' is unstable' });
  }
  const events = since == null ? mockEv.list.slice(-200) : mockEv.list.filter(e => e.id >= since);
  return { events, next: mockEv.n, first: mockEv.list.length ? mockEv.list[0].id : mockEv.n };
}
