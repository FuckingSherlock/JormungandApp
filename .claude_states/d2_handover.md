# D2 handover (node address pre-resolve) - D2b wired; tests and docs left (see "Remaining")

`dart analyze` in core: clean (one old info in svc_fetch.dart:661). Service tests pass.

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

## D2b: wired (service.dart), analyze clean, service tests pass (no commit)
- `_startSingBox(plan, sys, why, waitAddresses)`: `_pinsFor` = `addresses.ensure(planHostnames, first: dnsHostnames(dns), wait 8 s)` (cache first;
  crash `_recover` passes waitAddresses:false = cache only, ensure unawaited), `pinsFor(.., ipv6: planIpv6)`, `buildConfig(pins:)`, summary line
  "address: config for <why>: N of M hostnames pinned ... kept as names: ...". `_pinned` (host->ip) set after start; stored in `r.keep({'pins':..})`,
  adopt reads it back (`pins:` to its buildConfig, `_pinned`). `_starting` makes `_addressSettings` read the plan being started.
- `_connect(body, {own, reason})`: reason -> `sentinel.context.starting(reason)` and the pins `why`; own connect clears `_triedAddrs`.
- Auto `onDown: _serverDown`: host = memberHostname(plan, tag, key); only if `_pinned` has it; per-host rate limit `reresolveEvery` (public, 5 min);
  gate `_addrReady` = runner.running && _recovering==null && sentinel.context.settled && network.state==up. `_reresolve`: step 1 next cached
  address not yet tried (`_triedAddrs`) -> setCursor + restart; step 2 (all tried) `addresses.lookup(host,'node down')`: same set -> log "unchanged", no restart;
  changed -> cursor 0, tried cleared, restart. Restart = `_restartForAddresses` (2 s debounce, gates rechecked, `_connect(.., own:false, reason:'reresolve')`
  with the current Auto index). Every step is a logBook.note (info).
- Seam: `CoreService(resolveAddresses: true)`; false = no pre-resolve at all (configs keep names). Set false in the service/report tests that build a CoreService
  (service_test, service_failures, sentinel_service, service_update, service_rulesets, speed_current, report_send, report_test). `Daemon` has no such param
  (report_test's Daemon tests do not connect with hostnames).
- address_pin.dart: ws `headers.Host` and httpupgrade `host` now `name:port` (sing-box's own default, measured).
- Verified: pinned outbounds (vless ws+tls, vless httpupgrade, trojan http, DoH/DoT DNS) pass `sing-box check`.

## Remaining
- Not done: buildTesterConfig is not pinned (optional); targets' groups (routing.targets) are not covered by `memberHostname` (route groups only), so a
  node of a rule target group never triggers re-resolve (still pinned from the cache); http (h2) transport `host` is the bare name (default not measured).
- Tests (none written in D2): dns_wire codec (A/AAAA, compression, ipv6 text); AddressResolver with a mock DoH (plain http seam,
  `DnsCandidate(kind:'doh', addr:'http://127.0.0.1:p/dns-query')`): order DoH->DoT->UDP/TCP->system, dead-skip, ipv6 on/off, negative cache, in-flight dedupe;
  AddressBook persist/expiry/fresh; pinOutbound / pinDnsServer table per type (incl. detour, ss plugin, grpc plain, own server_name, case-insensitive Host);
  planHostnames / memberHostname / pinsFor; service: pins land in the config handed to a fake runner, cache-only on recover, adopt reads `pins`,
  `_serverDown` policy (not pinned -> nothing, rate limit via reresolveEvery, no restart while offline/unsettled/recovering, IP-set change restarts with
  reason 'reresolve', unchanged does not) using `resolveAddresses:true` + a mock DoH + injected timer; live sing-box: start a pinned config and capture the
  Host/SNI at a loopback server (ws plain Host header measured manually: `domain:port` default, explicit value sent as is).
- Docs (Russian): rules.md section 6 (lines ~475-478 say pre-resolve is D2; add the SNI/Host table and the experiment results), core.md (~889, ~913 say D2
  pending; resolveAddresses seam, adopt record `pins`), logs.md (the `address:` log lines), subscription-parsing.md (update warms addresses),
  platforms.md "Работа вне туннеля" (address-resolve entry).
- Full suites to be run by the lead (test-runner): `dart test` in core.
- Noticed: AdGuard unfiltered 94.140.14.140/.141 time out from this network (443 and 853), only .14.14 answers; with the default list the AdGuard DoH/DoT
  there are dead from here.

## D2b experiment results (sing-box 1.14.2, 2026-10-12)
- `sing-box check` accepts DoH/DoT/DoQ DNS server with `tls.server_name` and (https) `headers: {Host: ...}`: field names confirmed.
- Default Host sing-box sends for a DOMAIN-named server, captured on loopback: ws `Host: domain:port` and httpupgrade `Host: domain:port`
  (port always included, also 80/443, no TLS). With an explicit headers.Host / host the value is sent as is. So pinning sets
  ws headers.Host / httpupgrade host = `name:port` to keep the old wire behaviour (changed in address_pin.dart). http (h2) host list: bare name (not measured).
- Certs with IP SANs (Dart SecureSocket verified as IP literal, TLS 443+853): 1.1.1.1 (cloudflare-dns.com), 8.8.8.8 (dns.google),
  94.140.14.14 (dns.adguard-dns.com). 94.140.14.140/.141 (unfiltered) are unreachable from this net (timeout), cert not seen; same AdGuard
  cert family, so no provider-hostname fallback was added. The defaults are IP literals: nothing is pinned for them anyway; the IP
  literal path matters only for our own DoT lookups (SecureSocket.secure(host: ip) verifies the IP SAN: works for CF/Google/AdGuard .14.14).

## Per-outbound table (implemented in pinOutbound; `server` becomes the IP in all pinned cases)
- tls.enabled (vless, vmess, trojan, anytls, hysteria, hysteria2, tuic, http over TLS, ws/grpc/h2/httpupgrade/quic over TLS):
  tls.server_name = domain only when empty and not disable_sni; own value (Reality's too) never touched.
- transport ws: headers.Host = domain if no Host header (case-insensitive). httpupgrade: host = domain if empty. http (h2): host = [domain] if empty.
- grpc over TLS: nothing more (authority = server_name). grpc without TLS: not pinned (old behaviour).
- ss with plugin: not pinned. ssh, socks, plain http, plain ss/vless/vmess/trojan: server -> IP only.
- Any outbound with `detour` (chain exit; also memberHostname/planHostnames skip it): not pinned (entry resolves remotely).
- DNS servers (pinDnsServer): https/tls/quic -> server=IP + tls.server_name=host (if empty); https also headers.Host (host[:port]);
  udp/tcp -> IP only; `domain_resolver` removed; VPN-side (detour) servers pinned too. No pin -> unchanged (domain_resolver stays).
