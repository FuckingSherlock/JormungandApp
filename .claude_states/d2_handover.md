# D2 handover (node address pre-resolve) - stage stopped at budget; no commit, no tests, no docs yet

`dart analyze` in core: clean (one old info in svc_fetch.dart:661). outside_tunnel/config/updater tests pass.

## Done (all in core/lib/src, exported from jormungand_core.dart)
- dns_wire.dart: dnsQueryOf(name,type,id) A/AAAA, parseDnsAnswer (compression, TTL, IPv6 text), dohParam.
- address_book.dart: AddressEntry{v4,v6,at,ttl,via,with6,cursor; ips(ipv6), pick(ipv6), sameSet}; AddressBook(file) -> addresses.json
  (atomic), maxAge 30 d, fresh() = TTL clamped 10 min..6 h, setCursor.
- address_resolver.dart: AddressResolver(book, fetch, settings(), alive, log, attempt 3 s, budget 8 s, parallel 8, negativeFor 2 min).
  lookup(host, why) (in-flight dedupe, parallel limit) and ensure(hosts, why, wait, first, refreshAll) (cache first, missing waited
  up to `wait`, stale in background). Order: direct-side candidates DoH, DoT, then UDP/TCP, OS resolver last; dead (alive==false)
  skipped; DoQ skipped. DoH = GET via ServiceFetch direct path (http:// URL works as test seam); DoT = Socket + SecureSocket.secure
  (host = server name, IP literal verified as IP - NOT yet checked live against 1.1.1.1/8.8.8.8/94.140.14.140); hostname-named
  DoT/UDP servers use the book's IP. Logs via `log(level,text)` (info per try, warn when nothing answered).
- address_pin.dart: hostnameOf, pinOutbound(ob,pins), pinDnsServer(s,pins), planHostnames(plan), nodesHostnames(nodes),
  memberHostname(plan,groupTag,key), dnsHostnames(dns), pinsFor(hosts,book,ipv6).
- config.dart: buildConfig(..., pins) -> group() uses pinOutbound; routing.dnsServers re-written with pinDnsServer.
- routing.dart: dnsSidesOf(dnsPlan) -> candidates per side without building a config.
- plan_builder.dart: Json dnsPlan() extracted (routingPlan uses it).
- auto.dart: AutoService(onDown: (groupTag,key)) fired from _test and _heal when misses >= failAfter.
- updater.dart: SubscriptionUpdater(onNodes: (sid,nodes)) after a landed patch with nodes.
- outside_tunnel.dart: entry `address-resolve` (ownRule, address_resolver.dart).
- service.dart: addressBook, addresses, _addressSettings (plan routing.dns or snapshot via Catalog; plan without dns = OS only,
  keeps tests hermetic), _warmNodes (timer path via updater.onNodes, manual via fetchSource).

## NOT wired yet
- _startSingBox: collect planHostnames(plan), `await addresses.ensure(hosts, first: dnsHostnames(dns), wait ~8 s)` (cache-only /
  unawaited for the crash `_recover` call, line ~1234), `pins = pinsFor(hosts, addressBook, ipv6: planIpv6(plan))`, pass `pins:` to buildConfig;
  keep `_pinned` (host->ip) and store `pins` in `r.keep({...})`, read it back in adopt. Log a summary (cached/fresh/unresolved).
  `_plan` is null while connecting: _addressSettings must read the plan being started (add a `_starting` field).
- Auto hook in _startAuto: `onDown: _serverDown`. Handler plan: host = memberHostname(_plan,tag,key); act only if _pinned has host;
  rate limit per host (`reresolveEvery`, 5 min, public field for tests); gates: runner.running, sentinel.context.settled, net state up,
  _recovering == null; step 1 untried IP (cursor+1 in book entry) -> setCursor + restart; step 2 addresses.lookup(host,'node down'),
  `before.sameSet(after)` false -> restart (cursor 0), true -> log "unchanged". Restart = debounced (~2 s) `_connect({'plan': current
  index merged, 'systemProxy': _sysWanted}, own:false, reason:'reresolve')` - `_connect` needs a `reason` param for
  sentinel.context.starting. Log every re-resolve and restart (logBook.note).
- Tester configs (buildTesterConfig) not pinned (optional).

## To do after wiring
- Tests: dns_wire codec; resolver with a mock DoH (plain http seam, DnsCandidate(kind:'doh', addr:'http://127.0.0.1:p/dns-query')),
  fallback order, dead-skip, ipv6 on/off, cache persist/expiry; pin/config table per outbound; re-resolve policy (in-use only, rate
  limit, no restart offline/unsettled); live sing-box: `sing-box check` + start of a pinned config, and capture of Host/SNI (ws plain:
  Host header; ws+TLS needs `sing-box generate tls-keypair`; DoH DNS server `headers.Host` + `tls.server_name` field names are
  UNVERIFIED - run `sing-box check`). Check sing-box's default ws Host for a domain server (may be `domain:port`) vs ours (bare name).
- Verify cert IP SANs for 1.1.1.1, 8.8.8.8, 94.140.14.140 with a one-off Dart SecureSocket; if none, use official hostname as TLS name.
- Docs (Russian): rules.md section 6 (lines ~475-478 say pre-resolve is D2), core.md (lines ~889, ~913 say D2 pending), logs.md (log lines),
  subscription-parsing.md (update warms addresses), platforms.md "Работа вне туннеля" (address-resolve).
- Check existing service tests stay hermetic (no real DoH); run service_test, service_update_test, sentinel_service_test, auto_test.

## Per-outbound table (implemented in pinOutbound; `server` becomes the IP in all pinned cases)
- tls.enabled (vless, vmess, trojan, anytls, hysteria, hysteria2, tuic, http over TLS, ws/grpc/h2/httpupgrade/quic over TLS):
  tls.server_name = domain only when empty and not disable_sni; own value (Reality's too) never touched.
- transport ws: headers.Host = domain if no Host header (case-insensitive). httpupgrade: host = domain if empty. http (h2): host = [domain] if empty.
- grpc over TLS: nothing more (authority = server_name). grpc without TLS: not pinned (old behaviour).
- ss with plugin: not pinned. ssh, socks, plain http, plain ss/vless/vmess/trojan: server -> IP only.
- Any outbound with `detour` (chain exit; also memberHostname/planHostnames skip it): not pinned (entry resolves remotely).
- DNS servers (pinDnsServer): https/tls/quic -> server=IP + tls.server_name=host (if empty); https also headers.Host (host[:port]);
  udp/tcp -> IP only; `domain_resolver` removed; VPN-side (detour) servers pinned too. No pin -> unchanged (domain_resolver stays).
