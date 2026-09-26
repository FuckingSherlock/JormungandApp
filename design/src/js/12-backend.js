/* ══════════════════════ BACKEND SEAM ══════════════════════
   Everything the UI asks the core for goes through `backend`. Here it is faked; when
   the page is served by the Dart core (core/bin/jormd.dart sets window.JORMD),
   95-live.js swaps in the real one. (Flutter: the service layer over jormungand_core —
   SubscriptionService, PingService, ConnectionService.) */

const wait = ms => new Promise(r => setTimeout(r, ms));

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
    return wait(900 + Math.random() * 600).then(() => { mockFetchFails(s); if (s.demoChurn) demoProviderChurn(s); s.updatedAt = Date.now(); });
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
  connect()    { exitInfo = null; return wait(1100).then(() => { exitInfo = { ip: '91.108.4.12', country: 'DE', city: 'Frankfurt' }; }); },
  disconnect() { return Promise.resolve(); },
  // Live traffic (see renderTraffic): the mock keeps the numbers the cards show.
  // out = where each connection really goes, exit first (the core gives 'proxy/<sid::nid>' tags).
  traffic() {
    const id = effectiveConnectId(), c = chainsData[id];
    const out = c ? [chainExitNode(c), chainEntryNode(c)].filter(Boolean) : id ? [unitNode(id)].filter(Boolean) : [];
    const MB = 1048576, ago = s => new Date(Date.now() - s * 1000).toISOString();
    const conn = (host, port, net, via, process, downRate, down, s) =>
      ({ id: host, host, port, net, rule: via === out ? 'final' : 'ip_is_private=true => route(direct)', out: via.length ? via : ['direct'], process, down, up: down / 20 | 0, downRate, upRate: downRate / 30 | 0, start: ago(s) });
    return Promise.resolve({ running: true, down: 48.3 * MB, up: 6.1 * MB, downTotal: 1.84 * 1024 * MB, upTotal: 312 * MB, tcp: 43, udp: 8, conns: [
      conn('googlevideo.com', '443', 'tcp', out, 'C:\\Program Files\\Google\\Chrome\\chrome.exe', 3.2 * MB, 410 * MB, 95),
      conn('api.github.com', '443', 'tcp', out, 'C:\\Code\\Code.exe', 4096, 2 * MB, 40),
      conn('192.168.0.1', '53', 'udp', [], 'C:\\Windows\\System32\\svchost.exe', 0, 900, 3),
      conn('discord.com', '443', 'tcp', out, 'C:\\Discord\\Discord.exe', 128 * 1024, 30 * MB, 600),
    ].filter(c => !(Date.now() - (mockClosed.get(c.id) || 0) < 15000)) });
  },
  exitIp() { return wait(600).then(() => connected ? { ip: '91.108.4.12', country: 'DE', city: 'Frankfurt' } : { ip: '178.66.12.201', country: 'RU', city: 'Moscow' }); },
  // Close one live connection (Clash API DELETE /connections/{id}), or all with no id.
  // The mock hides them for a while — apps open new ones.
  closeConn(id) {
    (id ? [id] : ['googlevideo.com', 'api.github.com', '192.168.0.1', 'discord.com']).forEach(x => mockClosed.set(x, Date.now()));
    return Promise.resolve();
  },
  // A server's share link (vless://…), null when it has none (core: share.dart).
  shareLink(n) { return Promise.resolve(mockShareLink(n)); },
  // Logs tab: lines numbered `since` and later, and the number of the next one (core: logbook.dart).
  log(since) {
    mockLogTick();
    return Promise.resolve({ lines: mockLog.lines.filter(l => since == null || l.n >= since), next: mockLog.n });
  },
  clearLog() { mockLog.lines = []; return Promise.resolve(); },
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
  mockLog.lines.push({ n: mockLog.n++, t: t || Date.now(), src, lvl, msg });
  if (mockLog.lines.length > 2000) mockLog.lines.shift();
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
