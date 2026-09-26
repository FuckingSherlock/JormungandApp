/* ══════════════════════ PING CACHE ══════════════════════
   One latency store for every screen. Keyed by server (protocol://address:port), so a
   server that appears in two subscriptions shares its result. Values: ms, -1 = timeout,
   'testing' while a ping is in flight; `at` = when it was measured. Every ping goes
   through pingNodes(); every view reads ping(n). (Flutter: a PingService over
   sing-box's URL test, results in one provider.) */

const PING_FRESH_MS = 5 * 60 * 1000;          // older results are re-measured before use
const pingCache = new Map();                   // serverKey -> { ms, at }
const serverKey = n => n.protocol + '://' + n.address + ':' + n.port;

function ping(n)    { const e = pingCache.get(serverKey(n)); return e ? e.ms : null; }
function pingAge(n) { const e = pingCache.get(serverKey(n)); return e && typeof e.ms === 'number' ? Date.now() - e.at : Infinity; }
const isAlive = n => { const v = ping(n); return typeof v === 'number' && v >= 0; };
function setPing(n, ms) { pingCache.set(serverKey(n), { ms, at: Date.now() }); }

/* Mock network: each server has a hidden "true" latency (some are dead); a ping returns
   it with jitter and the occasional timeout. Pairs (entry -> exit) add a per-pair block
   chance, like an exit that refuses the entry's IP. */
const mockTruth = new Map();
function truthOf(n) {
  const k = serverKey(n);
  if (!mockTruth.has(k)) mockTruth.set(k, randLatency());
  return mockTruth.get(k);
}
function hash(str) { let h = 0; for (const c of str) h = (h * 31 + c.charCodeAt(0)) | 0; return Math.abs(h); }
function mockPing(n) {
  const t = truthOf(n);
  if (t < 0 || Math.random() < .04) return -1;
  return Math.max(10, Math.round(t * (.9 + Math.random() * .2)));
}
function mockPairPing(entry, exit) {
  const a = truthOf(entry), b = truthOf(exit);
  if (a < 0 || b < 0 || hash(serverKey(entry) + '>' + serverKey(exit)) % 4 === 0) return -1;
  return Math.round((a + b) * (.95 + Math.random() * .15) + 8);
}
// Pings nodes in parallel; resolves when all are done. Views refresh as results land.
function pingNodes(nodes) {
  nodes.forEach(n => pingCache.set(serverKey(n), { ms: 'testing', at: Date.now() }));
  refreshSourceViews();
  return backend.ping(nodes, (n, ms) => {
    setPing(n, ms);
    refreshSourceViews();
  });
}

// Ping one exit through one entry.
function pingPair(entry, exit) { return backend.pingPair(entry, exit); }

// Seed: results from earlier sessions, some older than PING_FRESH_MS.
Object.values(sourcesData).forEach(s => s.nodes.forEach(n => {
  const t = truthOf(n);
  pingCache.set(serverKey(n), { ms: t < 0 ? -1 : t, at: Date.now() - Math.random() * 9 * 60e3 });
}));
