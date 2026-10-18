import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'fetch.dart';
import 'localsource.dart';
import 'merge.dart';
import 'sentinel/retry.dart';
import 'state.dart';
import 'svc_fetch.dart';

/// Fetches subscription [s] (a source as the UI keeps it: url, userAgent, uaStrategy,
/// discoveredAt, nodes, gone, hwid, filter, channel) with its own settings and returns
/// `{patch, title, notModified}`: [patch] holds the [sourceServerFields] to put on the
/// source, `title` is a name suggestion (not applied here). One path for a tap on Update
/// in the UI and for the timer ([SubscriptionUpdater]).
///
/// An answer clearly older than the copy applied before (by the freshness the strategy entries keep, see
/// [Freshness]) changes nothing but `updatedAt`: the result is `notModified` and has `stale`, the data for the
/// journal line (the caller writes it).
///
/// A full answer replaces the provider's page / support / announce / interval (one that
/// stopped sending an announce clears it); a 304 only adds what it carries. Usage and
/// expiry are taken whenever `subscription-userinfo` came, 304 included.
///
/// The request goes through [svc] (the service traffic, "Download via" says which paths); [sid] keys its retry
/// count; [onDiverged] gets `{source, name, host, ua, …}` when in Auto the direct and the tunnel's answers differ.
Future<Map<String, dynamic>> updateSubscription(
  Map<String, dynamic> s, {
  Map<String, String>? hwid,
  ServiceFetch? svc,
  String? sid,
  bool rediscover = false,
  DateTime? now,
  void Function(Map<String, dynamic> data)? onDiverged,
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
    svc: svc,
    retryKey: sid,
    onDiverged: onDiverged == null ? null : (d) => onDiverged({'source': sid, 'name': '${s['name'] ?? sid ?? ''}', ...d}),
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
  return {
    'patch': patch,
    'title': r.title,
    'notModified': r.notModified,
    'via': r.via,
    // an older copy than the applied one came and was left out: {source, name, ua, why, applied, received, nodes}
    if (r.stale != null) 'stale': {'source': sid, 'name': '${s['name'] ?? sid ?? ''}', ...r.stale!},
  };
}

/// The fetch failed because of our own restart of sing-box (`RetryKind.ownRestart`): not a failure of the subscription,
/// so nothing is told and nothing is noted on the card; the load is asked again when the core has settled.
bool isOwnRestartFailure(Object e) =>
    e is SubscriptionFetchException && e.failure.code == 'allFailed' && e.failure.advice?.waitFor == RetryWait.settled;

/// The `sub/*` events one update of source [s] (as it was before) with [patch] (what [updateSubscription] put together)
/// makes, as `(type, data)` in the order they are written: `updated` `{source, name, added, removed, total}` (only when the
/// servers changed, when the provider dropped servers in use, or [always]), with `lost` / `lostCount` when it dropped
/// servers in use (the owner makes it a warn one and adds `affected`), then `back` `{source, name, count, names}` for the
/// dropped servers it brought back (the `gone` list moved). Servers are told apart by `key ?? id`. [inUse]: is this
/// server the main flow's or a rule target's now. `names` / `lost`: at most [subEventNames].
List<(String, Map<String, dynamic>)> subUpdateEvents(String sid, Map<String, dynamic> s, Map<String, dynamic> patch,
    {bool always = false, bool Function(Map<String, dynamic> node)? inUse}) {
  List<Map<String, dynamic>> maps(Object? l) => [for (final x in (l as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
  String keyOf(Map n) => '${n['key'] ?? n['id']}';
  final prev = maps(s['nodes']);
  final fresh = patch['nodes'] is List;
  if (!fresh && !always) return const [];
  final nodes = fresh ? maps(patch['nodes']) : prev;
  final name = '${s['name'] ?? sid}';
  final was = {for (final n in prev) keyOf(n)}, nowKeys = {for (final n in nodes) keyOf(n)};
  final added = nowKeys.difference(was).length, removed = was.difference(nowKeys).length;
  final out = <(String, Map<String, dynamic>)>[];
  final canGone = fresh && patch['gone'] is List;
  final dropped = canGone ? subDropped(s, patch) : const <Map<String, dynamic>>[];
  final back = canGone ? subReturned(s, patch) : const <Map<String, dynamic>>[];
  String label(Map n) => '${n['name'] ?? n['rawName'] ?? n['id']}';
  // the used servers the provider dropped make the update a warn one: `lost`, `lostCount` (the owner adds `affected`)
  final used = inUse == null ? const <Map<String, dynamic>>[] : [for (final n in dropped) if (inUse(n)) n];
  if (always || added != 0 || removed != 0 || used.isNotEmpty) {
    out.add((
      'updated',
      {
        'source': sid,
        'name': name,
        'added': added,
        'removed': removed,
        'total': nodes.length,
        if (used.isNotEmpty) 'lost': [for (final n in used.take(subEventNames)) label(n)],
        if (used.isNotEmpty) 'lostCount': used.length,
      }
    ));
  }
  if (back.isNotEmpty) {
    out.add(('back', {
      'source': sid,
      'name': name,
      'count': back.length,
      'names': [for (final n in back.take(subEventNames)) label(n)],
    }));
  }
  return out;
}

/// The servers update [patch] of source [s] (as it was before) drops: the `gone` list moved by them.
List<Map<String, dynamic>> subDropped(Map<String, dynamic> s, Map<String, dynamic> patch) {
  List<Map<String, dynamic>> maps(Object? l) => [for (final x in (l as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
  final wasGone = {for (final g in maps(s['gone'])) '${g['id']}'};
  return [for (final g in maps(patch['gone'])) if (!wasGone.contains('${g['id']}')) g];
}

/// The dropped servers of [s] the update [patch] brings back (they are among its nodes again).
List<Map<String, dynamic>> subReturned(Map<String, dynamic> s, Map<String, dynamic> patch) {
  List<Map<String, dynamic>> maps(Object? l) => [for (final x in (l as List? ?? const [])) if (x is Map) x.cast<String, dynamic>()];
  String keyOf(Map n) => '${n['key'] ?? n['id']}';
  final nodes = maps(patch['nodes']);
  final nowIds = {for (final n in nodes) '${n['id']}'}, nowKeys = {for (final n in nodes) keyOf(n)};
  return [for (final g in maps(s['gone'])) if (nowIds.contains('${g['id']}') || nowKeys.contains(keyOf(g))) g];
}

/// How many server names `sub/removed` / `back` carry.
const subEventNames = 10;

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
    this.svc,
    this.tick = const Duration(minutes: 1),
    this.firstRun = const Duration(seconds: 20),
    this.update = updateSubscription,
    this.onEvent,
    this.onReport,
    this.onSvcFailed,
    this.onDiverged,
    this.onStale,
    this.onNodes,
    this.onFetched,
    this.newOp,
    this.nodeInUse,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final SnapshotStore store;

  /// Device headers for sources with HWID on (device.dart).
  final Future<Map<String, String>> Function()? hwid;

  /// The core's service traffic ("Download via" picks the paths); null = a plain direct socket.
  final ServiceFetch? Function()? svc;
  final Duration tick;
  final Duration firstRun;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> s,
      {Map<String, String>? hwid,
      ServiceFetch? svc,
      String? sid,
      bool rediscover,
      DateTime? now,
      void Function(Map<String, dynamic> data)? onDiverged}) update;
  final DateTime Function() clock;

  /// No path brought the subscription (every one failed): the failure to judge ([SvcFailure.suspicion]) and the
  /// data of the `failed` event. Set, it replaces the `failed` event of [onEvent] for such a failure (the owner
  /// writes it, for a confirmed verdict only); a failure of our own restart reaches neither (retried at the next
  /// tick, nothing told).
  final void Function(SvcFailure failure, Map<String, dynamic> data)? onSvcFailed;

  /// Auto: the direct and the tunnel's answers differ (the newer one or the merge was used, `used` says which): `{source, name, host, ua, …}`.
  final void Function(Map<String, dynamic> data)? onDiverged;

  /// The answer was a clearly older copy than the applied one and was left out (`stale` of [updateSubscription]).
  final void Function(Map<String, dynamic> data)? onStale;

  /// An update that landed brought a server list (not a 304): the source's id and the nodes it now holds. The
  /// core resolves their hostnames then (address_resolver.dart); the UI's own updates do the same in the service.
  final void Function(String sid, List<Map<String, dynamic>> nodes)? onNodes;

  /// The source's fetch came through (whatever it changed): its last failure, if any, is over.
  final void Function(String sid)? onFetched;

  /// A new operation of [kind] (`subUpdate`, `subUpdateAll`): the events of one update share its `{id, kind}`. A tick
  /// that updates several sources is one `subUpdateAll`, a single source is its own `subUpdate`. [op] is the current one.
  final Map<String, Object?> Function(String kind)? newOp;

  /// Is this server of a subscription in use now (the main flow's or a rule target's): for `sub/removed` / `back`.
  final bool Function(Map<String, dynamic> node)? nodeInUse;

  Map<String, Object?>? _op;

  /// The operation of the update under way; read by [onEvent] / [onSvcFailed] while they run.
  Map<String, Object?>? get op => _op;

  /// What the timer's updates did, for the events journal: `('updated', {source, name,
  /// added, removed, total, lost?, lostCount?})` when the server list changed or used servers were dropped,
  /// `('back', {source, name, count, names})` when the provider brought dropped servers back ([subUpdateEvents]), `('failed', {source, name, error})` on every
  /// failure (the owner of the hook folds the same error of the same source into one event, ×N). The manual update of
  /// the UI is told by [CoreService.fetchSource] with the same helper.
  final void Function(String type, Map<String, dynamic> data)? onEvent;

  /// Set, an update that landed is told to this ([s]: the source before, [patch]: what was applied) instead of
  /// [subUpdateEvents] being run for [onEvent]: the owner needs both to tell what the update affects. [onEvent] still
  /// gets the failures.
  final FutureOr<void> Function(String sid, Map<String, dynamic> s, Map<String, dynamic> patch)? onReport;

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

  /// [sid] was not fetched because of our own restart: the timer asks again at its next tick, not after the retry wait,
  /// and whether the source is due by its period or not (a manual update of a fresh source is not due).
  void askAgain(String sid) {
    _triedAt.remove(sid);
    _again.add(sid);
  }

  final _again = <String>{};

  // What the source must still have for a result to land (the user did not edit, update or
  // delete it meanwhile).
  static Map<String, dynamic> _expect(Map<String, dynamic> s) =>
      {for (final k in const ['url', 'userAgent', 'filter', 'hwid', 'gone', 'updatedAt']) k: s[k]};

  Future<void> _report(String sid, Map<String, dynamic> s, Map<String, dynamic> patch) async {
    if (onReport != null) {
      try {
        await onReport!(sid, s, patch);
      } catch (e) {
        stderr.writeln('[updater] events of ${s['name'] ?? sid}: $e'); // told wrongly is not a failed fetch
      }
      return;
    }
    if (onEvent == null) return;
    for (final (type, data) in subUpdateEvents(sid, s, patch, inUse: nodeInUse)) {
      onEvent!(type, data);
    }
  }

  /// Updates every due subscription now; the ids updated (a failure only notes
  /// `lastError` on the source).
  Future<List<String>> runDue() => _running ??= _runDue().whenComplete(() => _running = null);

  Future<List<String>> _runDue() async {
    final done = <String>[];
    final snap = await store.read();
    final due = [...dueSubscriptions(snap, clock().millisecondsSinceEpoch, triedAt: _triedAt)];
    final asked = _again.toList();
    for (final sid in asked) {
      final src = snap?['sourcesData'];
      if (src is! Map || src[sid] is! Map) {
        _again.remove(sid); // deleted meanwhile
      } else if (!due.contains(sid)) {
        due.add(sid);
      }
    }
    // several sources due at one tick are one operation, a single one is its own
    final batch = due.length > 1 ? newOp?.call('subUpdateAll') : null;
    for (final sid in due) {
      if (_busy.contains(sid)) continue;
      final s = await store.source(sid);
      if (s == null) continue;
      _busy.add(sid);
      _op = batch ?? newOp?.call('subUpdate');
      final wasAsked = _again.remove(sid);
      var retrySoon = false;
      try {
        final r = await update(
          s,
          hwid: s['hwid'] == true ? await hwid?.call() : null,
          svc: svc?.call(),
          sid: sid,
          now: clock(),
          onDiverged: onDiverged,
        );
        final patch = Map<String, dynamic>.of((r['patch'] as Map).cast<String, dynamic>());
        onFetched?.call(sid);
        if (s['lastError'] != null) patch['lastError'] = null; // the card's error strip goes
        if (r['stale'] case final Map stale) onStale?.call(stale.cast<String, dynamic>());
        if (await store.patchSource(sid, _expect(s), patch)) {
          done.add(sid);
          await _report(sid, s, patch);
          final nodes = patch['nodes'];
          if (nodes is List) onNodes?.call(sid, [for (final n in nodes) if (n is Map) n.cast<String, dynamic>()]);
        }
      } catch (e) {
        stderr.writeln('[updater] ${s['name'] ?? sid}: $e');
        final data = {'source': sid, 'name': '${s['name'] ?? sid}', 'error': fetchErrorText(e)};
        final svcFail = e is SubscriptionFetchException && e.failure.code == 'allFailed' ? e.failure : null;
        if (isOwnRestartFailure(e)) {
          // our own restart cut it: nothing is told, no error on the card, the next tick asks again
          retrySoon = true;
          if (wasAsked) _again.add(sid);
        } else {
          if (svcFail != null && onSvcFailed != null) {
            onSvcFailed!(svcFail, data); // the Sentinel judges every failure (a standing root says nothing twice)
          } else {
            onEvent?.call('failed', data); // every failure: no ceiling (the same error of a source is ×N on one event)
          }
          // the card shows it with Retry (33-source-error.js); updatedAt stays, so the UI's
          // own save still wins over it
          await store.patchSource(sid, _expect(s), {
            'lastError': {'msg': fetchErrorText(e), 'at': clock().millisecondsSinceEpoch},
          });
        }
      } finally {
        _op = null;
        _busy.remove(sid);
        if (!retrySoon) _triedAt[sid] = clock().millisecondsSinceEpoch;
      }
    }
    return done;
  }
}
