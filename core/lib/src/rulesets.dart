/// Rule-set lists (geosite / geoip and the user's own, see [ruleSetsNeeded]) cached in the
/// data dir. sing-box gets them as `type: local` files: a connect never waits on sing-box
/// downloading them, and a list that cannot be fetched keeps working from its last copy.
///
/// - fresh (younger than its `every`): used as is;
/// - stale: used as is; replaced when [RuleSetCache.ensure] runs with `refresh` (the daemon
///   does that once the tunnel is up; sing-box reloads a replaced local file by itself);
/// - missing: downloaded before the config is built. A list "via VPN" needs a running
///   tunnel ([proxyPort]); without one it stays pending, its rules are left out with a
///   warning, and the daemon fetches it through the new tunnel and reconnects.
///
/// URLs are tried in order and only a 404 / 410 moves on (runetfreedom → SagerNet for a
/// category runetfreedom does not build). A body that is not a rule set (a captive portal's
/// page) is refused, so it never replaces a good copy.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'routing.dart';

class RuleSetFetch {
  RuleSetFetch(this.files, this.errors, this.pending);

  /// tag → path of every list on disk (fresh or stale): buildConfig's `ruleSetFiles`.
  final Map<String, String> files;

  /// Downloads that failed (a stale copy, if any, is still in [files]).
  final List<String> errors;

  /// Not on disk and not fetched now (no tunnel for a list via VPN, or the download failed).
  final List<String> pending;
}

class RuleSetCache {
  RuleSetCache(
    this.dir, {
    this.timeout = const Duration(seconds: 20),
    this.retryAfter = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String dir;

  /// Per step of a download (connect, headers, body).
  final Duration timeout;

  /// A failed list is not asked for again sooner (a blocked source must not slow every connect).
  final Duration retryAfter;
  final DateTime Function() _now;
  final _failedAt = <String, DateTime>{};
  final _running = <String, Future<void>>{};

  /// A download that failed (once per download, however many callers waited on it): the
  /// tag, the last URL tried and the reason. The daemon writes the events journal from it.
  void Function(String tag, String url, String error)? onFailed;

  /// A list replaced by a newer copy, or downloaded after a failure (not the first
  /// download of a missing one: that is what a connect does anyway).
  void Function(String tag)? onUpdated;

  String pathOf(RuleSetSource s) => p.join(dir, '${s.tag}.${s.binary ? 'srs' : 'json'}');

  /// [proxyPort]: a loopback mixed inbound that always goes through the tunnel; lists "via
  /// VPN" download only through it. Direct lists use the system's proxy from the environment.
  Future<RuleSetFetch> ensure(List<RuleSetSource> sets, {int? proxyPort, bool refresh = false}) async {
    final files = <String, String>{}, errors = <String>[], pending = <String>[];
    if (sets.isEmpty) return RuleSetFetch(files, errors, pending);
    await Directory(dir).create(recursive: true);
    await Future.wait(
      sets.map((s) async {
        final f = File(pathOf(s));
        final have = await f.exists();
        final stale = !have || _now().difference(await f.lastModified()) >= s.every;
        final canFetch = !s.viaVpn || proxyPort != null;
        final failed = _failedAt[s.tag];
        final backoff = failed != null && _now().difference(failed) < retryAfter;
        if (stale && canFetch && !backoff && (!have || refresh)) {
          try {
            await (_running[s.tag] ??= _fetch(s, f, s.viaVpn ? proxyPort : null, notable: have || failed != null).whenComplete(() {
              _running.remove(s.tag); // not returned: whenComplete would wait on this very future
            }));
            _failedAt.remove(s.tag);
          } catch (e) {
            _failedAt[s.tag] = _now();
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
  Future<RuleSetFetch> ensureFor(Map plan, {int? proxyPort, bool refresh = false}) =>
      ensure(ruleSetsNeeded(plan), proxyPort: proxyPort, refresh: refresh);

  Future<void> _fetch(RuleSetSource s, File f, int? proxyPort, {required bool notable}) async {
    try {
      await _download(s, f, proxyPort);
    } catch (e) {
      final url = e is _DownloadFailed ? e.url : s.urls.last;
      onFailed?.call(s.tag, url, '${e is _DownloadFailed ? e.cause : e}');
      rethrow;
    }
    if (notable) onUpdated?.call(s.tag);
  }

  Future<void> _download(RuleSetSource s, File f, int? proxyPort) async {
    final c = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = proxyPort == null ? HttpClient.findProxyFromEnvironment : (_) => 'PROXY 127.0.0.1:$proxyPort';
    var tried = s.urls.isEmpty ? '' : s.urls.first;
    try {
      var last = '';
      for (final url in s.urls) {
        tried = url;
        final res = await (await c.getUrl(Uri.parse(url)).timeout(timeout)).close().timeout(timeout);
        if (res.statusCode == 404 || res.statusCode == 410) {
          await res.drain<void>();
          last = 'HTTP ${res.statusCode}';
          continue;
        }
        if (res.statusCode != 200) {
          await res.drain<void>();
          throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
        }
        final b = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d)).timeout(timeout * 3);
        final data = b.takeBytes();
        _check(s, data);
        final part = File('${f.path}.part');
        await part.writeAsBytes(data, flush: true);
        await part.rename(f.path);
        return;
      }
      throw HttpException('not found ($last)');
    } catch (e) {
      throw _DownloadFailed(tried, e);
    } finally {
      c.close(force: true);
    }
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
  _DownloadFailed(this.url, this.cause);
  final String url;
  final Object cause;
  @override
  String toString() => '$cause';
}

/// The warnings of one connect as one toast: blanks and repeats dropped, at most three.
String? joinWarnings(List<String> w) {
  final l = w.where((x) => x.isNotEmpty).toSet().toList();
  if (l.isEmpty) return null;
  return l.length <= 3 ? l.join('; ') : '${l.take(3).join('; ')}; …and ${l.length - 3} more';
}
