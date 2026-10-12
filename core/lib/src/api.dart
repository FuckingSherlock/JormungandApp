import 'dart:async';

import 'node.dart';

/// What the app (or the local HTTP adapter, daemon.dart) asks of the core. The payloads
/// are the maps the HTTP API has always carried (docs/core.md → API), so one method here is
/// one route there. [CoreService] is the in-process implementation, which the Flutter app
/// uses directly; a remote one (HTTP / IPC to a background engine or a Windows service) can
/// implement the same interface later.
///
/// Errors: a [FormatException] carries a message for the user (a bad form, a bad event);
/// anything else is a failure of the core (connect failed, sing-box did not answer).
abstract interface class CoreApi {
  /// Opens the data directory, the journal and the snapshot, takes care of a system proxy
  /// left by an earlier run, starts the subscription timer. Call once, before anything else.
  Future<void> init();

  /// Graceful stop: sing-box stopped, the system proxy back (unless the kill switch keeps
  /// it while the app is closed), the streams closed. The object is not used afterwards.
  Future<void> dispose();

  /// `{snapshot, status}`: the UI's one snapshot (state.dart) and the status.
  Future<Map<String, dynamic>> state();

  /// Stores the UI's snapshot (a source the timer updated meanwhile keeps its server fields).
  Future<Map<String, dynamic>> saveState(Map<String, dynamic>? snapshot);

  /// The status (docs/core.md → API, `GET /api/status`).
  Future<Map<String, dynamic>> status();

  /// `{connected?, validated?, captive?, type?, id?}` → the Sentinel's context (`status.context`, docs/failures.md):
  /// what the platform says of the network now (Android: `NET_CAPABILITY_VALIDATED`, `NET_CAPABILITY_CAPTIVE_PORTAL`,
  /// the transport, an id of the network), all of it each time; a field left out is "not said". `captive: true` makes the
  /// network `captive`, `connected: false` makes it `none`; `validated: false` alone is only a doubt.
  Map<String, dynamic> setNetwork(Map<String, dynamic> body);

  /// The status again whenever it changed (state transitions, Auto switches, the exit check,
  /// the network state) and every few seconds for the measurements inside it while someone
  /// listens; identical statuses are not repeated. Broadcast.
  Stream<Map<String, dynamic>> get statusChanges;

  /// Speed, session totals and open connections; `running: false` with zeros without sing-box.
  Future<Map<String, dynamic>> traffic();

  /// `{lines, next, hidden?}`: log lines numbered [since] and later (all kept ones without it).
  /// With [conns] off the flood of successful-connection / `found package name` lines is left
  /// out by the core and `hidden` says how many it left out (logbook.dart `since`; docs/logs.md).
  Map<String, dynamic> log({int? since, bool conns = true});

  /// Every log line as it is written (the Logs tab, Raw), the flood included. Broadcast.
  Stream<Map<String, dynamic>> get logStream;

  void clearLog();

  /// `{events, updated?, next, first}` (eventbook.dart): events with an id of [since] and later;
  /// `updated`: events changed in place lately (compare `rev`).
  Map<String, dynamic> events({int? since});

  /// Every journal event as it is written (the Events tab, notifications). Broadcast.
  Stream<Map<String, dynamic>> get eventStream;

  /// `{cat, type, level, own?, data?}` → `{id}`: an event the UI knew first. A bad shape is
  /// a [FormatException] with the reason.
  Map<String, dynamic> postEvent(Map<String, dynamic> body);

  void clearEvents();

  /// `{event}` (the id of a `site/*` event) → `{check}`: asks the external checker (check-host.net) about
  /// the event's site and changes that event in place with the result (`data.check`, `manual: true`;
  /// `events()` then carries it in `updated`). A bad id is a [FormatException].
  Future<Map<String, dynamic>> siteCheck(Map<String, dynamic> body);

  /// `{core, singBox, dataDir, dart, os}`.
  Future<Map<String, dynamic>> version();

  /// The support report (report.dart, docs/logs.md): one structured map (`format: 1`) with the
  /// app and device, the connection, settings, network, counters, all kept events with their data
  /// and every raw line — credentials and tokens masked (redact.dart), server names kept. [appInfo]
  /// is what only the host knows (version, versionCode, commit, platform, androidApi, device model,
  /// abis, locale, timezone, network type, …): it is taken as given, the core never guesses.
  /// Built from memory in one pass (rings of at most 5500 lines); the caller may gzip it.
  Future<Map<String, dynamic>> report({Map<String, dynamic> appInfo = const {}});

  /// "Send report": the same report (built with the strict masking, docs/logs.md → Отправка) plus
  /// the user's [note] (≤ 500 characters, masked too), gzipped and handed to the core's
  /// `ReportUploader`. → `{ok: true, id, bytes}` or `{ok: false, error, message?}`; `error` is
  /// `not-configured` (no receiver plugged in yet), `network`, `rejected`, `server`, `cancelled`,
  /// `timeout` (no result in a minute: it always ends) or `failed`. Does not throw for a delivery that
  /// failed. The upload goes direct first and, if that fails while the tunnel is up, through the
  /// tunnel (`via: 'direct' | 'vpn'` in the answer). A second call while one goes joins it.
  Future<Map<String, dynamic>> sendReport({String note = '', Map<String, dynamic> appInfo = const {}});

  /// Stops the send under way (it answers `cancelled`) → `{ok: true, cancelled: bool}`.
  Future<Map<String, dynamic>> cancelReport();

  /// `{protocol, address, port, secret, name, outbound?, unsupported?}` → the node (manual.dart).
  Node manualNode(Map<String, dynamic> body);

  /// `{outbound, name, flag, unsupported?}` → the share link, or null (share.dart).
  String? share(Map<String, dynamic> body);

  /// `{sid, source, rediscover}` → `{patch, title, notModified, via}` (updater.dart).
  Future<Map<String, dynamic>> fetchSource(Map<String, dynamic> body);

  /// `{text}` → `{nodes}` parsed from links.
  Map<String, dynamic> parse(Map<String, dynamic> body);

  /// `{name, text}` → `{source}`: a local source (`kind: 'file'`, no `id` — the catalog owner
  /// gives one) from the text of a picked file (localsource.dart). [name] is the file name,
  /// its extension is dropped. Nothing recognised — a [FormatException] with the reason.
  Map<String, dynamic> addSourceFromText(Map<String, dynamic> body);

  /// `{plan, systemProxy, killSwitch?, killOnDisconnect?, killWhileClosed?, downProxy?, dnsAuto?}`
  /// → the status. Throws when it did not connect (the status holds `error`).
  Future<Map<String, dynamic>> connect(Map<String, dynamic> body);

  /// Takes over a sing-box that outlived the previous core (Android: the engine was recreated
  /// while the tunnel stayed up) instead of starting another one. `{dnsAuto?, killSwitch?,
  /// killOnDisconnect?, killWhileClosed?, downProxy?, auto?}` — the app's settings now, as in a
  /// connect body. → `{adopted: false[, stopped: true]}` or `{adopted: true, plan, status}`;
  /// runners that cannot adopt answer `{adopted: false}`.
  Future<Map<String, dynamic>> adopt(Map<String, dynamic> body);

  Future<Map<String, dynamic>> disconnect();

  /// Takes the system proxy off now (down alert, blocked plaque).
  Future<Map<String, dynamic>> releaseSysProxy();

  /// A restart of a crashed sing-box now, instead of waiting out the pause.
  Future<Map<String, dynamic>> retry();

  /// `{killSwitch?, killOnDisconnect?, killWhileClosed?, downProxy?}` changed on the go.
  Future<Map<String, dynamic>> killSwitchSettings(Map<String, dynamic> body);

  /// `{auto}`: new Auto mode settings for the running AutoService.
  Future<Map<String, dynamic>> autoSettings(Map<String, dynamic> body);

  /// `{auto: bool}`: Settings → DNS → Switch automatically, live.
  Future<Map<String, dynamic>> dnsAutoSetting(Map<String, dynamic> body);

  /// `{provider}`: the latency of a DNS provider per side, measured by the failover's own check through the running
  /// sing-box (the colour of the side chips and the ping agree) → `{provider, live, direct, vpn, servers: [{id,
  /// side, kind, ms}]}`: `direct` / `vpn` = best ms of the provider's candidates on the side, -1 none answered, null
  /// no candidate there; `live: false` = not measured (sing-box off, or the provider is not in the running config).
  Future<Map<String, dynamic>> pingDnsSides(Map<String, dynamic> body);

  /// Checks where traffic leaves again; the result arrives in `status.exit`.
  Future<Map<String, dynamic>> recheckExit();

  /// `{nodes, pairs, url?, maxAgeMs?, …checkers}` → one `{kind, key, ms}` per result as it
  /// is measured, then `{done: true, network}`, or `{error}` when the tester could not run.
  /// The measuring goes on when the listener leaves (the pool keeps the results).
  Stream<Map<String, dynamic>> ping(Map<String, dynamic> body);

  /// `{node}` or `{pair}`, `configUrl?` → progress maps (`phase`, `down`, `up`, …), the last
  /// with `final: true` (and `error` when it failed). Cancelling the subscription stops the test.
  Stream<Map<String, dynamic>> speedTest(Map<String, dynamic> body);

  /// Closes one open connection ([id] from `traffic`) or all of them: `{ok}`.
  Future<Map<String, dynamic>> closeConnections([String? id]);

  // ── the app's own update (appupdate.dart, docs/updates.md); the platform installs ──

  /// `UpdateStatus.toJson` (phase idle / checking / upToDate / available / downloading / ready /
  /// failed, the offer, the bytes); `{phase: 'unavailable'}` when the host gave the core no app version.
  Map<String, dynamic> updateStatus();

  /// The update status again whenever it changed. Broadcast.
  Stream<Map<String, dynamic>> get updateChanges;

  /// `{channel?: stable|beta, manual?: bool}` → the status. Throws a [FormatException] when there is no updater.
  Future<Map<String, dynamic>> updateCheck(Map<String, dynamic> body);

  /// Downloads the offered file and checks it (size, sha256): the status `ready` or `failed`.
  Future<Map<String, dynamic>> updateDownload();

  /// Stops a download in progress (the partial file stays for a resume).
  void updateCancel();

  /// `{autoCheck: bool, channel: stable|beta, autoDownload: off|wifi|always, metered: bool}`: what the
  /// scheduled check does and whether it downloads what it finds (Settings → Data); `metered` is the
  /// platform's report of the underlying network (`wifi` downloads only while it is false).
  /// Also `{ignoredSites: [host…]}` (any of the keys alone): the sites the journal and the raw log stay
  /// quiet about (no `site/*` events; their failed-connection lines go to the noise ring); the host and
  /// its subdomains; takes effect at once, no reconnect, routing is not touched.
  /// Also `{screenOn: bool}` (alone): the platform's report of the phone's screen (Android); a `site/*`
  /// event found while it is false is marked `bg: true` in the journal. Never reported = on.
  /// Also `{closeOnSwitch: bool}` (default true): a live route move in Manual (`autoSettings {manual,
  /// entry}`) closes the main flow's open connections of the route left; false = they finish there.
  void updateSettings(Map<String, dynamic> body);

  /// The platform calls it right before it hands the downloaded file to the installer / after the
  /// install did not happen ([installFailed] with the reason).
  Future<void> updateBeginInstall();
  Future<void> updateInstallFailed(String reason);
}
