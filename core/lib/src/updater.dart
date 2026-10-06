import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'fetch.dart';
import 'localsource.dart';
import 'merge.dart';
import 'state.dart';

/// Fetches subscription [s] (a source as the UI keeps it: url, userAgent, uaStrategy,
/// discoveredAt, nodes, gone, hwid, filter, channel) with its own settings and returns
/// `{patch, title, notModified}`: [patch] holds the [sourceServerFields] to put on the
/// source, `title` is a name suggestion (not applied here). One path for a tap on Update
/// in the UI and for the timer ([SubscriptionUpdater]).
///
/// A full answer replaces the provider's page / support / announce / interval (one that
/// stopped sending an announce clears it); a 304 only adds what it carries. Usage and
/// expiry are taken whenever `subscription-userinfo` came, 304 included.
Future<Map<String, dynamic>> updateSubscription(
  Map<String, dynamic> s, {
  Map<String, String>? hwid,
  int? proxyPort,
  bool rediscover = false,
  DateTime? now,
  HttpClient? client,
}) async {
  // a local source has no URL: nothing to fetch, it changes only by importing the file again
  if (s['kind'] == localSourceKind) throw const FormatException('A local file has nothing to update: import the file again');
  List<Map<String, dynamic>> maps(Object? l) => [for (final x in (l as List? ?? const [])) (x as Map).cast<String, dynamic>()];
  final prevNodes = maps(s['nodes']);
  final r = await fetchSubscription(
    '${s['url'] ?? ''}',
    userAgent: (s['userAgent'] as String?) ?? 'Auto',
    strategy: maps(s['uaStrategy']),
    discoveredAt: (s['discoveredAt'] as num?)?.toInt() ?? 0,
    prevCount: prevNodes.length,
    rediscover: rediscover,
    filter: (s['filter'] as String?) ?? '',
    headers: s['hwid'] == true && hwid != null ? hwid : const {},
    channel: Channel.of(s['channel'] as String?),
    proxyPort: proxyPort,
    client: client,
  );
  final patch = <String, dynamic>{'updatedAt': (now ?? DateTime.now()).millisecondsSinceEpoch};
  if (!r.notModified) {
    final m = mergeUpdate(prevNodes, maps(s['gone']), r.nodes, now: now);
    // servers the user's filter leaves out were not dropped by the provider: no "Unavailable"
    // entry for them (they could not come back while the filter stands anyway)
    final re = filterRegExp((s['filter'] as String?) ?? '');
    final gone = re == null
        ? m.gone
        : [
            for (final g in m.gone)
              if (filterKeeps(re, '${g['rawName'] ?? g['name'] ?? ''}', '${g['flag'] ?? ''}')) g,
          ];
    patch.addAll({
      'nodes': m.nodes,
      'gone': gone,
      'count': m.nodes.length,
      'uaStrategy': r.strategy,
      'discoveredAt': r.discoveredAt,
      'format': r.format,
    });
  }
  if (r.hasUserInfo) {
    patch['usage'] = {'used': r.usedGb ?? 0, 'total': r.totalGb ?? 0};
    patch['expire'] = r.expire;
  }
  void put(String k, Object? v) {
    if (v != null || !r.notModified) patch[k] = v;
  }

  put('providerInterval', r.updateHours);
  put('webPage', r.webPage);
  put('supportUrl', r.supportUrl);
  put('announce', r.announce);
  return {'patch': patch, 'title': r.title, 'notModified': r.notModified, 'via': r.via};
}

/// A failed automatic update is tried again after this (or the source's own period, if
/// shorter).
const retryAfterFailure = Duration(minutes: 30);

/// How often subscription [s] updates itself; null = never
/// (docs/subscription-parsing.md → «Автообновление»). `updateInterval`: a number of seconds
/// (0 = never; at least 10 s) is the user's own period. `'auto'` (default): the provider's
/// `profile-update-interval` (at least 1 h) if it sent one, else the global [subsEvery]
/// (seconds, Auto mode; default 12 h); a global 0 switches all automatic updates off.
/// Switched-off sources, server groups and local file sources (`kind: 'file'`) never update.
Duration? autoUpdatePeriod(Map s, Object? subsEvery) {
  if (s['kind'] != 'sub' || s['enabled'] == false || '${s['url'] ?? ''}'.isEmpty) return null;
  final own = s['updateInterval'];
  final secs = own is num ? own : (own is String ? num.tryParse(own) : null);
  if (secs != null) return secs > 0 ? Duration(seconds: max(10, secs.round())) : null;
  final global = subsEvery is num ? subsEvery : 12 * 3600;
  if (global <= 0) return null;
  final provider = s['providerInterval'];
  if (provider is num && provider > 0) return Duration(minutes: max(60, (provider * 60).round()));
  return Duration(seconds: global.round());
}

/// Sources of [snap] whose automatic update is due at [now] (ms), in the Nodes order.
/// [triedAt]: the last attempt per source (failed ones wait [retryAfterFailure]).
List<String> dueSubscriptions(Map<String, dynamic>? snap, int now, {Map<String, int> triedAt = const {}}) {
  final src = snap?['sourcesData'];
  if (src is! Map) return const [];
  final every = (snap!['autoCfg'] as Map?)?['subsEvery'];
  final order = snap['sourceOrder'] is List ? [for (final x in snap['sourceOrder'] as List) '$x'] : [for (final k in src.keys) '$k'];
  return [
    for (final sid in order)
      if (src[sid] is Map)
        if (autoUpdatePeriod(src[sid] as Map, every) case final period?)
          if (now - ((src[sid] as Map)['updatedAt'] as num? ?? 0) >= period.inMilliseconds)
            if (now - (triedAt[sid] ?? 0) >= min(period.inMilliseconds, retryAfterFailure.inMilliseconds)) sid,
  ];
}

/// Keeps subscriptions fresh with the UI closed: every [tick] it updates the due ones in
/// the stored snapshot (see [SnapshotStore] for how that meets the UI's own saves), one at
/// a time. A manual update from the UI runs under [guard], so the timer skips that source
/// meanwhile. (Flutter: the same service over the app's store, woken by WorkManager /
/// a background fetch on mobile.)
class SubscriptionUpdater {
  SubscriptionUpdater({
    required this.store,
    this.hwid,
    this.proxyPort,
    this.tick = const Duration(minutes: 1),
    this.firstRun = const Duration(seconds: 20),
    this.update = updateSubscription,
    this.onEvent,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final SnapshotStore store;

  /// Device headers for sources with HWID on (device.dart).
  final Future<Map<String, String>> Function()? hwid;

  /// The running tunnel's mixed port, null when not connected ("Download via" Proxy).
  final int? Function()? proxyPort;
  final Duration tick;
  final Duration firstRun;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> s,
      {Map<String, String>? hwid, int? proxyPort, bool rediscover, DateTime? now, HttpClient? client}) update;
  final DateTime Function() clock;

  /// What the timer's updates did, for the events journal: `('updated', {source, name,
  /// added, removed, total})` when the server list changed, `('failed', {source, name,
  /// error})` on the first failure after a good update (not on every retry). The UI's own
  /// updates are the UI's to report.
  final void Function(String type, Map<String, dynamic> data)? onEvent;

  final _busy = <String>{};
  final _triedAt = <String, int>{};
  Timer? _timer;
  bool _stopped = true;
  Future<List<String>>? _running;

  void start() {
    _stopped = false;
    _timer = Timer(firstRun, _loop);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  Future<void> _loop() async {
    try {
      await runDue();
    } catch (e) {
      stderr.writeln('[updater] $e');
    }
    if (!_stopped) _timer = Timer(tick, _loop);
  }

  /// Runs [fn] (a manual update of [sid]) with the timer keeping off that source.
  Future<T> guard<T>(String? sid, Future<T> Function() fn) async {
    if (sid == null) return fn();
    _busy.add(sid);
    try {
      return await fn();
    } finally {
      _busy.remove(sid);
      _triedAt[sid] = clock().millisecondsSinceEpoch;
    }
  }

  // What the source must still have for a result to land (the user did not edit, update or
  // delete it meanwhile).
  static Map<String, dynamic> _expect(Map<String, dynamic> s) =>
      {for (final k in const ['url', 'userAgent', 'filter', 'hwid', 'gone', 'updatedAt']) k: s[k]};

  void _report(String sid, Map<String, dynamic> s, Map<String, dynamic> patch) {
    final now = patch['nodes'];
    if (onEvent == null || now is! List) return;
    Set<String> keys(Object? l) => {for (final n in (l as List? ?? const [])) '${(n as Map)['key'] ?? n['id']}'};
    final was = keys(s['nodes']), nowKeys = keys(now);
    final added = nowKeys.difference(was).length, removed = was.difference(nowKeys).length;
    if (added == 0 && removed == 0) return;
    onEvent!('updated', {'source': sid, 'name': '${s['name'] ?? sid}', 'added': added, 'removed': removed, 'total': now.length});
  }

  /// Updates every due subscription now; the ids updated (a failure only notes
  /// `lastError` on the source).
  Future<List<String>> runDue() => _running ??= _runDue().whenComplete(() => _running = null);

  Future<List<String>> _runDue() async {
    final done = <String>[];
    final due = dueSubscriptions(await store.read(), clock().millisecondsSinceEpoch, triedAt: _triedAt);
    for (final sid in due) {
      if (_busy.contains(sid)) continue;
      final s = await store.source(sid);
      if (s == null) continue;
      _busy.add(sid);
      try {
        final r = await update(
          s,
          hwid: s['hwid'] == true ? await hwid?.call() : null,
          proxyPort: proxyPort?.call(),
          now: clock(),
        );
        final patch = Map<String, dynamic>.of((r['patch'] as Map).cast<String, dynamic>());
        if (s['lastError'] != null) patch['lastError'] = null; // the card's error strip goes
        if (await store.patchSource(sid, _expect(s), patch)) {
          done.add(sid);
          _report(sid, s, patch);
        }
      } catch (e) {
        stderr.writeln('[updater] ${s['name'] ?? sid}: $e');
        if (s['lastError'] == null) onEvent?.call('failed', {'source': sid, 'name': '${s['name'] ?? sid}', 'error': '$e'});
        // the card shows it with Retry (33-source-error.js); updatedAt stays, so the UI's
        // own save still wins over it
        await store.patchSource(sid, _expect(s), {
          'lastError': {'msg': '$e', 'at': clock().millisecondsSinceEpoch},
        });
      } finally {
        _busy.remove(sid);
        _triedAt[sid] = clock().millisecondsSinceEpoch;
      }
    }
    return done;
  }
}
