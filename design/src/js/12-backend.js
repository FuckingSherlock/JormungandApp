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
  connect()    { return wait(1100); },
  disconnect() { return Promise.resolve(); },
};
