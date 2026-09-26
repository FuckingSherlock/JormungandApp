/* ══════════════════════ PING CACHE ══════════════════════
   One latency store for every screen. Keyed by node variant (pingKey: protocol://address:
   port#id — the id is the variant: SNI, fingerprint, transport…, see subscription-parsing.md
   → dedup), so variants of one server keep their own results (a dead one never looks alive
   because another answered), and the same variant in two subscriptions shares one.
   Values: ms, -1 = timeout, 'testing' while a ping is in flight; `at` = when it was
   measured; `fails` = timeouts in a row (Auto's failAfter, see knownDead). Every ping goes
   through pingNodes(); every view reads ping(n); the core's Auto checks land here too
   (95-live.js). (Flutter: a PingService over sing-box's URL test, results in one provider.) */

const PING_FRESH_MS = 5 * 60 * 1000;          // older results are re-measured before use
const pingCache = new Map();                   // pingKey -> { ms, at, fails }
const serverKey = n => n.protocol + '://' + n.address + ':' + n.port;   // the server, any variant
const pingKey = n => serverKey(n) + '#' + n.id;

const pingEntry = n => pingCache.get(pingKey(n));
function ping(n)    { const e = pingEntry(n); return e ? e.ms : null; }
function pingAge(n) { const e = pingEntry(n); return e && typeof e.ms === 'number' ? Date.now() - e.at : Infinity; }
const isAlive = n => { const v = ping(n); return typeof v === 'number' && v >= 0; };
function setPing(n, ms) {
  const prev = pingEntry(n);
  pingCache.set(pingKey(n), { ms, at: Date.now(), fails: ms === -1 ? ((prev && prev.fails) || 0) + 1 : 0 });
}
/* Stored results from before the per-variant key (keyed protocol://address:port): one goes
   to its node only when exactly one variant of that server exists — with several, nobody
   knows which one answered, so they start unmeasured. A -1 counts as one timeout. */
function restorePings(list) {
  pingCache.clear();
  const variants = new Map();
  Object.values(sourcesData).forEach(s => (s.nodes || []).concat(s.gone || []).forEach(n => {
    const k = serverKey(n);
    if (!variants.has(k)) variants.set(k, new Set());
    variants.get(k).add(pingKey(n));
  }));
  (list || []).forEach(([k, e]) => {
    if (!e || typeof e.ms !== 'number') return;
    if (e.fails == null) e = Object.assign({}, e, { fails: e.ms === -1 ? 1 : 0 });
    if (k.includes('#')) { pingCache.set(k, e); return; }
    const v = variants.get(k);
    if (v && v.size === 1 && !pingCache.has([...v][0])) pingCache.set([...v][0], e);
  });
}
// Batch order by the cache: alive by ms (fastest first), then never measured, dead last.
// The core pings in the order given, so servers that answered before get fresh numbers
// first and dead ones (each waits out the timeout) do not hold up the rest.
const pingRank = n => isAlive(n) ? ping(n) : typeof ping(n) === 'number' ? 2e9 : 1e9;
const byPingRank = list => list.slice().sort((a, b) => pingRank(a) - pingRank(b));

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
  nodes = byPingRank(nodes);   // before 'testing' overwrites what the cache knew
  // 'testing' keeps when and how often it missed, so Auto's knownDead holds meanwhile
  nodes.forEach(n => pingCache.set(pingKey(n), Object.assign({ at: 0, fails: 0 }, pingEntry(n), { ms: 'testing' })));
  refreshSourceViews();
  return backend.ping(nodes, (n, ms) => {
    setPing(n, ms);
    refreshSourceViews();
  });
}

// Ping one exit through one entry.
function pingPair(entry, exit) { return backend.pingPair(entry, exit); }

// Seed: results from earlier sessions, some older than PING_FRESH_MS (dead ones missed a few).
Object.values(sourcesData).forEach(s => s.nodes.forEach(n => {
  const t = truthOf(n);
  pingCache.set(pingKey(n), { ms: t < 0 ? -1 : t, at: Date.now() - Math.random() * 9 * 60e3, fails: t < 0 ? 3 : 0 });
}));
