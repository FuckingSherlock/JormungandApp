/* ══════════════════════ ROUTING PLAN (rules → the core) ══════════════════════
   The Rules screen, apps and Settings → DNS as the model the core turns into sing-box route
   rules and DNS (core/lib/src/routing.dart; contract in docs/core.md). The UI sends its own
   model — condition groups, targets, "If unavailable" — not sing-box JSON, so the Flutter
   app reuses the Dart builder. The one thing resolved here is each target: the catalog lives
   in the UI, so every target a rule or app names goes along as its server group(s), or null
   while it is unavailable (off in Nodes, no server the core can use, deleted). */

// A rule / app target as groups (same shape as the main flow's), or null = unavailable.
function routingTarget(t) {
  if (!targetInfo(t).ok) return null;
  const at = t.indexOf(':'), kind = t.slice(0, at), ref = t.slice(at + 1);
  try {
    if (kind === 'src') return { kind: 'unit', main: planGroup(liveNodes(sourcesData[ref]).map(node => ({ sid: ref, node })), 'fastest') };
    if (kind === 'node') {
      const [sid, nid] = ref.split('::'), r = { sid, node: sourcesData[sid].nodes.find(n => n.id === nid) };
      return { kind: 'unit', main: planGroup([r], 'priority', r) };
    }
    if (kind === 'profile') {
      const refs = unitPickRefs(ref), n = unitNode(ref);
      return { kind: 'unit', main: planGroup(refs, unitPriority(ref) ? 'priority' : 'fastest', refs.find(r => r.node === n)) };
    }
    const c = chainsData[ref], exits = chainExitRefs(c), exitNode = chainExitNode(c);
    return { kind: 'chain', entry: planGroup(chainEntryRefs(c), 'fastest'),
      main: planGroup(exits, c.exitMode === 'priority' ? 'priority' : 'fastest', exits.find(r => r.node === exitNode)) };
  } catch (e) { return null; }   // nothing here sing-box can use (XHTTP only)
}

function routingPlan() {
  const rules = ruleOrder.map(id => rulesData[id]).filter(r => r.enabled).map(r => {
    // a rule's Fallback only means something for Proxy (a target of its own or the main flow);
    // "Proxy via X" (fallback 'main' + fallbackTarget) goes as the target id X
    const o = { id: r.id, name: r.name, action: r.action, target: r.target || '',
      fallback: r.action === 'proxy' ? (r.fallback === 'main' && r.fallbackTarget ? r.fallbackTarget : r.fallback || 'default') : 'default',
      block: r.block, dns: r.dns || 'auto', groups: r.groups };
    if (r.composite) {
      const { action, outbound, method, ...match } = r.composite;
      o.composite = match;
    }
    if (r.extra && Object.keys(r.extra).length) o.extra = r.extra;
    if (r.ipTunOnly) o.ipTunOnly = true;   // no `resolve` for its IP conditions
    return o;
  });
  // an app: the top-level fields are all its traffic (TCP when split), udp the other half
  // "If unavailable → Proxy via X" (fallback 'main' + fallbackTarget) goes as the target id X;
  // 'main' alone = no fallback. Only Proxy and Default (= the main flow) have one: on Default or
  // Proxy with the main flow an explicit block / direct / target id gives the main flow its own
  // "If unavailable"; 'default' / 'main' there = none (Default without one has no rule)
  const fb = h => h.fallback === 'main' && h.fallbackTarget ? h.fallbackTarget : h.fallback || 'default';
  const half = h => ({ act: h.act || 'default', target: h.act === 'proxy' ? h.target || '' : '',
    fallback: h.act === 'proxy' || !h.act || h.act === 'default' ? fb(h) : 'default' });
  const apps = Object.entries(appRules).map(([pkg, a]) => {
    const app = APPS.find(x => x.pkg === pkg) || {};
    return { id: pkg, kind: app.kind || 'package', name: app.name || pkg, ...half(a), split: !!a.split, udp: half(a.udp || {}) };
  });
  const named = new Set();
  // a fallback that is not a keyword is a target: its group(s) must exist in the config too
  const addFb = f => { if (f && !['default', 'main', 'block', 'direct'].includes(f)) named.add(f); };
  rules.forEach(r => { if (r.action === 'proxy') { if (r.target) named.add(r.target); addFb(r.fallback); } });
  apps.forEach(a => [a, ...(a.split ? [a.udp] : [])].forEach(h => {
    if (h.act === 'proxy' && h.target) named.add(h.target);
    if (h.act === 'proxy' || h.act === 'default') addFb(h.fallback);
  }));
  const geo = id => { const s = ruleSets.find(x => x.id === id) || {}; return { via: s.via || 'vpn', every: s.every || 7 * 86400 }; };
  return {
    apps, rules,
    quick: { ads: quickCfg.ads, region: quickCfg.regionOn ? quickCfg.region : null, final: quickCfg.final,
      services: Object.fromEntries(SERVICES.filter(([k]) => quickCfg.services[k] && quickCfg.services[k] !== 'default').map(([k]) => [k, quickCfg.services[k]])) },
    fallback: quickCfg.fallback,
    targets: Object.fromEntries([...named].map(t => [t, routingTarget(t)])),
    ruleSets: ruleSets.filter(s => !s.builtin).map(s => ({ name: s.name, url: s.url, format: s.format, via: s.via, every: s.every })),
    geo: { geosite: geo('geosite'), geoip: geo('geoip') },
    dns: { servers: dnsOrder.map(id => dnsServers[id]).map(s => ({ id: s.id, addr: s.addr, via: s.via, on: s.on })),
      resolve: dnsCfg.resolve,   // 'auto' | 'off' | a server id: the `resolve` step before IP rules
      hijack: dnsCfg.hijack !== false },   // TUN only: the core answers every DNS query
  };
}
