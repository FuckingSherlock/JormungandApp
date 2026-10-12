/// Rule-set lists (geosite / geoip and the user's own, see [ruleSetsNeeded]) cached in the
/// data dir. sing-box gets them as `type: local` files: a connect never waits on sing-box
/// downloading them, and a list that cannot be fetched keeps working from its last copy.
///
/// - fresh (younger than its `every`): used as is;
/// - stale: used as is; replaced when [RuleSetCache.ensure] runs with `refresh` (the daemon
///   does that on a timer while connected, once the Sentinel's context is settled; sing-box
///   reloads a replaced local file by itself, so a refresh never restarts it);
/// - missing: downloaded before the config is built. A list "via VPN" needs a running
///   tunnel ([RuleSetCache.ensure]'s `tunnel`); without one it stays pending, its rules are left
///   out with a warning, and the daemon fetches it through the new tunnel and reconnects.
///
/// The download is the core's service traffic ([ServiceFetch], purpose `ruleset`): it races the paths
/// (a list "via VPN" only the tunnel's). URLs are tried in order and only a 404 / 410 moves on
/// (runetfreedom → SagerNet for a category runetfreedom does not build). A body that is not a rule set
/// (a captive portal's page) is refused, so it never replaces a good copy.
///
/// A failed list waits as the [RetryPolicy] advises (1 → 2 → 5 → 15 min, the network's return, or the
/// core's settle after an own restart) before it is asked for again. A failure of an own restart is
/// not reported at all. The sources are data ([RuleSetSource]: tag, urls, format, via, every), so a
/// list the user adds later is one more source in the list [RuleSetCache.ensure] gets.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'routing.dart';
import 'sentinel/retry.dart';
import 'svc_fetch.dart';
import 'svc_in.dart';

class RuleSetFetch {
  RuleSetFetch(this.files, this.errors, this.pending);

  /// tag → path of every list on disk (fresh or stale): buildConfig's `ruleSetFiles`.
  final Map<String, String> files;

  /// Downloads that failed (a stale copy, if any, is still in [files]).
  final List<String> errors;

  /// Not on disk and not fetched now (no tunnel for a list via VPN, or the download failed).
  final List<String> pending;
}

/// A download that failed, as the journal and the Sentinel get it.
class RuleSetFailure {
  RuleSetFailure(this.tag, this.url, this.error, {required this.hasCopy, this.svc});

  final String tag;

  /// The last URL tried.
  final String url;
  final String error;

  /// A previous copy of the list is on disk (and is used).
  final bool hasCopy;

  /// Set when no path brought an answer: the suspicion to judge ([SvcFailure.suspicion]) comes from it.
  /// Null = the server answered, with something that is no rule set (the failure is the list's own).
  final SvcFailure? svc;
}

class RuleSetCache {
  /// [fetch]: the service traffic ([CoreService.svcFetch]); without one (and without [fetchSource]) the
  /// requests go over one plain direct socket (the tests, a cache used alone).
  RuleSetCache(this.dir, {ServiceFetch? fetch, DateTime Function()? now})
      : fetchSource = fetch == null ? null : (() => fetch),
        _now = now ?? DateTime.now;

  final String dir;

  /// Where the [ServiceFetch] comes from (the service sets it lazily).
  ServiceFetch Function()? fetchSource;
  ServiceFetch? _plain;
  final DateTime Function() _now;

  /// A failed list waits here until the retry advice is over.
  final _hold = <String, Future<void>>{};
  final _running = <String, Future<void>>{};

  // lists whose last download failed (the next success is told as an update)
  final _failed = <String>{};

  ServiceFetch get _fetchApi => fetchSource?.call() ?? (_plain ??= ServiceFetch(endpoint: () => null));

  /// A download that failed (once per download, however many callers waited on it). Not told for a
  /// failure of our own restart (the retry comes after the settle). The daemon writes the journal from it.
  void Function(RuleSetFailure failure)? onFailed;

  /// A list replaced by a newer copy, or downloaded after a failure (not the first
  /// download of a missing one: that is what a connect does anyway).
  void Function(String tag)? onUpdated;

  String pathOf(RuleSetSource s) => p.join(dir, '${s.tag}.${s.binary ? 'srs' : 'json'}');

  /// When each list of Rules → Rule sets was last downloaded (epoch ms, from the file's time), by
  /// the list's name there: a user's set by its name, the built-in `geosite` / `geoip` by the
  /// newest of their category files. A list never downloaded is absent.
  Future<Map<String, int>> updatedTimes() async {
    final out = <String, int>{};
    final d = Directory(dir);
    if (!await d.exists()) return out;
    await for (final e in d.list()) {
      if (e is! File) continue;
      final file = p.basename(e.path);
      final m = RegExp(r'^(geosite|geoip|set)-(.+)\.(srs|json)$').firstMatch(file);
      if (m == null) continue;
      final at = (await e.lastModified()).millisecondsSinceEpoch;
      final name = m[1] == 'set' ? m[2]! : m[1]!;
      if (at > (out[name] ?? 0)) out[name] = at;
    }
    return out;
  }

  /// [tunnel]: the core's sing-box runs, so the way "via VPN" exists; lists via VPN download only
  /// through it and stay pending without it. Direct lists prefer the direct path.
  Future<RuleSetFetch> ensure(List<RuleSetSource> sets, {bool tunnel = false, bool refresh = false}) async {
    final files = <String, String>{}, errors = <String>[], pending = <String>[];
    if (sets.isEmpty) return RuleSetFetch(files, errors, pending);
    await Directory(dir).create(recursive: true);
    await Future.wait(
      sets.map((s) async {
        final f = File(pathOf(s));
        final have = await f.exists();
        final stale = !have || _now().difference(await f.lastModified()) >= s.every;
        final canFetch = !s.viaVpn || tunnel;
        if (stale && canFetch && !_hold.containsKey(s.tag) && (!have || refresh)) {
          try {
            await (_running[s.tag] ??= _fetch(s, f, notable: have || _failed.contains(s.tag)).whenComplete(() {
              _running.remove(s.tag); // not returned: whenComplete would wait on this very future
            }));
            _failed.remove(s.tag);
          } catch (e) {
            _failed.add(s.tag);
            errors.add('${s.tag}: $e');
          }
        }
        if (await f.exists()) {
          files[s.tag] = f.path;
        } else {
          pending.add(s.tag);
        }
      }),
    );
    return RuleSetFetch(files, errors, pending);
  }

  /// [ensure] for everything [plan]'s routing uses.
  Future<RuleSetFetch> ensureFor(Map plan, {bool tunnel = false, bool refresh = false}) =>
      ensure(ruleSetsNeeded(plan), tunnel: tunnel, refresh: refresh);

  Future<void> _fetch(RuleSetSource s, File f, {required bool notable}) async {
    try {
      await _download(s, f);
    } catch (e) {
      final d = e is _DownloadFailed ? e : _DownloadFailed(s.urls.isEmpty ? '' : s.urls.last, e);
      final api = _fetchApi;
      // when to ask again: the policy's advice for a path failure; a server's answer that is no list
      // counts as a failure of the network kind (the escalating wait)
      final advice = d.svc?.advice ?? api.retryFor('ruleset').advise(RetryKind.network);
      _hold[s.tag] = api.retryFor('ruleset').wait(advice).whenComplete(() => _hold.remove(s.tag));
      // our own restart cut it: the settle brings the retry, nothing is told
      if (advice.waitFor != RetryWait.settled) {
        onFailed?.call(RuleSetFailure(s.tag, d.url, '${d.cause}', hasCopy: await f.exists(), svc: d.svc));
      }
      throw d;
    }
    if (notable) onUpdated?.call(s.tag);
  }

  Future<void> _download(RuleSetSource s, File f) async {
    final api = _fetchApi;
    // "via VPN" is the main flow or a route; a direct list takes whichever path works, the direct one first
    final policy = s.viaVpn ? const SvcPolicy.race(kinds: {SvcKind.main, SvcKind.route}) : const SvcPolicy.race();
    final prefer = s.viaVpn ? SvcPrefer.tunnel : SvcPrefer.direct;
    var tried = s.urls.isEmpty ? '' : s.urls.first;
    var last = '';
    for (final url in s.urls) {
      tried = url;
      final SvcResult res;
      try {
        res = await api.get(Uri.parse(url), purpose: 'ruleset', policy: policy, prefer: prefer);
      } catch (e) {
        throw _DownloadFailed(tried, e);
      }
      final fail = res.failure;
      if (fail != null) throw _DownloadFailed(tried, fail, svc: fail.code == 'allFailed' ? fail : null);
      final r = res.response!;
      if (r.status == 404 || r.status == 410) {
        last = 'HTTP ${r.status}';
        continue;
      }
      if (r.status != 200) throw _DownloadFailed(tried, 'HTTP ${r.status}');
      try {
        _check(s, r.body);
        // atomically: sing-box reloads the file when it changes, and must never read a half-written one
        final part = File('${f.path}.part');
        await part.writeAsBytes(r.body, flush: true);
        await part.rename(f.path);
      } catch (e) {
        throw _DownloadFailed(tried, e);
      }
      return;
    }
    throw _DownloadFailed(tried, 'not found ($last)');
  }

  static void _check(RuleSetSource s, Uint8List data) {
    if (s.binary) {
      // sing-box binary rule sets start with "SRS"
      if (data.length < 4 || data[0] != 0x53 || data[1] != 0x52 || data[2] != 0x53) {
        throw const FormatException('not a sing-box binary rule set');
      }
      return;
    }
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(data));
    } catch (_) {
      throw const FormatException('not a sing-box JSON rule set');
    }
    if (j is! Map || j['rules'] is! List) throw const FormatException('not a sing-box JSON rule set');
  }
}

// A failed download with the URL it stopped at; reads as the plain reason.
class _DownloadFailed implements Exception {
  _DownloadFailed(this.url, this.cause, {this.svc});
  final String url;
  final Object cause;
  final SvcFailure? svc;
  @override
  String toString() => '$cause';
}

/// The warnings of one connect as one toast: blanks and repeats dropped, at most three.
String? joinWarnings(List<String> w) {
  final l = w.where((x) => x.isNotEmpty).toSet().toList();
  if (l.isEmpty) return null;
  return l.length <= 3 ? l.join('; ') : '${l.take(3).join('; ')}; …and ${l.length - 3} more';
}
