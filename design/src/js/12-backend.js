/* ══════════════════════ BACKEND SEAM ══════════════════════
   Everything the UI asks the core for goes through `backend`. Here it is faked; when
   the page is served by the Dart core (core/bin/jormd.dart sets window.JORMD),
   95-live.js swaps in the real one. (Flutter: the service layer over jormungand_core —
   SubscriptionService, PingService, ConnectionService.) */

const wait = ms => new Promise(r => setTimeout(r, ms));

let backend = {
  live: false,
  // First fetch of a new subscription: fills s.nodes (and usage / expire).
  fetchSource(s) {
    return wait(1200).then(() => {
      s.nodes = genNodes(8 + Math.floor(Math.random() * 20), 'sub');
      s.usage = { used: 0, total: 0 };
    });
  },
  // Update: new s.nodes, dropped servers into s.gone (see connect-model.md → gone).
  updateSource(s) {
    return wait(900 + Math.random() * 600).then(() => { if (s.demoChurn) demoProviderChurn(s); });
  },
  // A server added by hand. Resolves to the node, or rejects with a message.
  manualNode(f) {
    return Promise.resolve({ id: 'n' + Date.now(), flag: '🌐', name: f.name, protocol: f.protocol, address: f.address, port: f.port, secret: f.secret });
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
    const out = c ? [chainExitNode(c), chainEntryNode(c)].filter(Boolean) : [unitNode(id)].filter(Boolean);
    const MB = 1048576, ago = s => new Date(Date.now() - s * 1000).toISOString();
    const conn = (host, port, net, via, process, downRate, down, s) =>
      ({ id: host, host, port, net, rule: via === out ? 'final' : 'ip_is_private=true => route(direct)', out: via.length ? via : ['direct'], process, down, up: down / 20 | 0, downRate, upRate: downRate / 30 | 0, start: ago(s) });
    return Promise.resolve({ running: true, down: 48.3 * MB, up: 6.1 * MB, downTotal: 1.84 * 1024 * MB, upTotal: 312 * MB, tcp: 43, udp: 8, conns: [
      conn('googlevideo.com', '443', 'tcp', out, 'C:\\Program Files\\Google\\Chrome\\chrome.exe', 3.2 * MB, 410 * MB, 95),
      conn('api.github.com', '443', 'tcp', out, 'C:\\Code\\Code.exe', 4096, 2 * MB, 40),
      conn('192.168.0.1', '53', 'udp', [], 'C:\\Windows\\System32\\svchost.exe', 0, 900, 3),
      conn('discord.com', '443', 'tcp', out, 'C:\\Discord\\Discord.exe', 128 * 1024, 30 * MB, 600),
    ] });
  },
  exitIp() { return wait(600).then(() => connected ? { ip: '91.108.4.12', country: 'DE', city: 'Frankfurt' } : { ip: '178.66.12.201', country: 'RU', city: 'Moscow' }); },
};
