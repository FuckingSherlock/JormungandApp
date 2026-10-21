/// Quick start on the last servers (docs/core.md → «Быстрый старт на последнем сервере»): the pure part. The record of
/// the servers the core's groups were on when the connection ended, the decision whether a fresh connect may start on
/// them at once (while the usual check of connectPicks runs in parallel), and the verdict of that check per group.
/// Nothing here knows sing-box or the service; service.dart does the starting, the select and the journal.
library;

import 'dart:convert';
import 'dart:io';

import 'durable.dart';
import 'plan.dart';

/// The record: the network the connection ended on ([network] null = unknown, never matches), when ([at], ms since
/// epoch) and per group (tag → server key) the servers that were alive then. One file, overwritten by each disconnect.
class LastServers {
  const LastServers({this.network, required this.at, this.groups = const {}});

  final String? network;
  final int at;
  final Map<String, String> groups;

  Map<String, dynamic> toJson() => {'v': 1, 'network': ?network, 'at': at, 'groups': groups};

  /// null = not a record.
  static LastServers? fromJson(Object? j) {
    if (j is! Map || j['at'] is! num) return null;
    final g = j['groups'];
    return LastServers(
      network: j['network'] is String && (j['network'] as String).isNotEmpty ? j['network'] as String : null,
      at: (j['at'] as num).toInt(),
      groups: g is Map ? {for (final e in g.entries) if (e.value is String) '${e.key}': e.value as String} : const {},
    );
  }

  /// null = no file, or not readable.
  static LastServers? load(File f) {
    try {
      if (!f.existsSync()) return null;
      return fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  /// Atomic (the old file or the new one); a failed write throws (the caller logs it).
  void save(File f) {
    f.parent.createSync(recursive: true);
    writeFileDurableSync(f, jsonEncode(toJson()));
  }
}

/// The record of a disconnect: [servers] (group tag → key, the core's own: `_coreServers()`) of the groups in [alive].
LastServers lastServersRecord({String? network, required int at, required Map<String, String> servers, required Set<String> alive}) =>
    LastServers(network: network, at: at, groups: {for (final e in servers.entries) if (alive.contains(e.key)) e.key: e.value});

/// The tags of the groups whose server answered the last check and that are not in failover. [auto]: `AutoService.toJson`
/// (a route is alive when its last check answered with no miss since; a chain's entry and exit both), [fallback]:
/// `FallbackService.toJson` (a target is alive when it is not down and its last check answered; its entry too).
Set<String> aliveGroups({Map<String, dynamic>? auto, Map<String, dynamic>? fallback}) {
  final out = <String>{};
  final routes = auto?['routes'];
  if (routes is List) {
    for (var i = 0; i < routes.length; i++) {
      final r = routes[i];
      if (r is! Map || r['ms'] is! num || (r['ms'] as num) < 0 || (r['fails'] is num && (r['fails'] as num) > 0)) continue;
      out
        ..add(routeTag(i))
        ..add(routeEntryTag(i));
    }
  }
  final targets = fallback?['targets'];
  if (targets is List) {
    for (final t in targets) {
      if (t is! Map || t['down'] == true || t['ms'] is! num || (t['ms'] as num) < 0 || (t['fails'] is num && (t['fails'] as num) > 0)) continue;
      out
        ..add('${t['target']}')
        ..add(targetEntryTag('${t['target']}'));
    }
  }
  return out;
}

/// What a fresh connect starts on: [started] group tag → server key, for the groups the check covers (the route's own
/// groups and the rule targets') that the record has a usable server for.
class QuickStart {
  const QuickStart(this.started);
  final Map<String, String> started;
}

/// Whether [plan] may start on [rec] now ([network]: the id of the network now). Same network (no id on either side:
/// no); the route group (a chain's entry) has a record server that is a member of it in [plan] and the group is not
/// pinned; at least one such group has a choice to check. null = the usual path.
QuickStart? quickStartFor(LastServers? rec, String? network, Map<String, dynamic> plan) {
  if (rec == null || network == null || rec.network != network || rec.groups.isEmpty) return null;
  final started = <String, String>{};
  void take(String tag, Object? g) {
    final key = rec.groups[tag];
    if (g is! Map || key == null || g['pinned'] == true) return;
    if ((g['nodes'] as List? ?? const []).any((n) => n is Map && '${n['key']}' == key)) started[tag] = key;
  }

  final rs = planRoutes(plan);
  final i = planCurrent(plan, rs.length), r = rs[i];
  final chain = r['kind'] == 'chain';
  take(routeTag(i), r['main']);
  if (chain) take(routeEntryTag(i), r['entry']);
  if (!started.containsKey(chain ? routeEntryTag(i) : routeTag(i))) return null;
  if (plan['global'] != true) {
    for (final (tag, g) in planTargetGroups(plan)) {
      take(tag, g);
    }
  }
  bool choice(Object? g) => g is Map && (g['nodes'] as List? ?? const []).length >= 2;
  final groups = {
    routeTag(i): r['main'],
    if (chain) routeEntryTag(i): r['entry'],
    if (plan['global'] != true) for (final (tag, g) in planTargetGroups(plan)) tag: g,
  };
  if (!started.keys.any((t) => choice(groups[t]))) return null;
  return QuickStart(started);
}

/// What the check made of a group started from the record: [result] `same` | `switched` | `dropped`.
class QuickGroup {
  const QuickGroup({required this.group, required this.started, required this.result, this.to, this.why, this.note});

  final String group, started, result;

  /// The server the group went to ([result] switched; dropped: the one that was picked).
  final String? to;

  /// `noAnswer` (the started server did not answer) | `higherBack` (Priority: a server above it answers), when switched.
  final String? why;

  /// A dropped one: what stopped it (the Raw line only), default «moved by Auto».
  final String? note;

  Map<String, dynamic> toJson() => {'group': group, 'started': started, 'result': result, 'to': ?to, 'why': ?why};

  /// `connect: <group> quick start on <server>; check: same|switched to <server>: <why>|dropped: moved by Auto`
  String line() => 'connect: $group quick start on $started; check: '
      '${switch (result) {
        'switched' => 'switched to $to: $why',
        'dropped' => 'dropped: ${note ?? 'moved by Auto'}',
        _ => 'same',
      }}';
}

/// conn/connected `quick`: `{groups: [{group, started, result, to?, why?}], tookMs}`.
Map<String, dynamic> quickReportJson(List<QuickGroup> groups, int tookMs) => {'groups': [for (final g in groups) g.toJson()], 'tookMs': tookMs};

/// The verdict of the check for one group: [keys] the group's servers in the user's order, [started] the server it
/// started on, [picked] the server the check chose (null = nobody answered: nothing moves), [startedAnswered] whether
/// the started server answered (only asked for Fastest). Returns `(null, null)` = stay, else `(to, why)`.
///
/// Priority picked another: ours did not answer (a lower server was picked) or a higher one is back. Fastest picked
/// another: switch only when ours did not answer.
(String?, String?) quickVerdict({required bool priority, required List<String> keys, required String started, String? picked, bool startedAnswered = true}) {
  if (picked == null || picked == started) return (null, null);
  if (priority) return (picked, keys.indexOf(picked) < keys.indexOf(started) ? 'higherBack' : 'noAnswer');
  return startedAnswered ? (null, null) : (picked, 'noAnswer');
}
