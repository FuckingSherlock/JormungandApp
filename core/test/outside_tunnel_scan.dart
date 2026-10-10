// The guard behind core/lib/src/outside_tunnel.dart, shared by core/test/outside_tunnel_test.dart and
// app/test/outside_tunnel_guard_test.dart: scans sources for code that opens a connection (or
// starts a process) and compares the files found with the registry. No `package:test` here, so the
// app's tests can import it by path.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';

/// One place to scan: [dir] is repo-relative, [exts] the file endings, [patterns] what counts as
/// opening a connection there.
class ScanScope {
  const ScanScope(this.name, this.dir, this.exts, this.patterns);

  final String name;
  final String dir;
  final List<String> exts;
  final List<String> patterns;
}

/// Dart: HTTP / socket / DNS lookup / process APIs. A helper that wraps one of them is found where
/// the wrapped call stands, so the file with the call is what gets listed.
const dartNetworkPatterns = [
  r'\bHttpClient\(',
  r'\bHttpServer\.',
  r'\b(?:Secure|Raw|RawSecure)?Socket\.(?:connect|startConnect|secure)\b',
  r'\b(?:Raw|Secure|RawSecure)?ServerSocket\.',
  r'\bRawDatagramSocket\.',
  r'\bWebSocket\.connect\b',
  r'\bClientChannel\(',
  r'\bInternetAddress\.lookup\(',
  r'\bNetworkImage\(|\bImage\.network\(',
  r'package:(?:http|dio|web_socket_channel|http2|cronet_http|cupertino_http)/',
  r'\bProcess\.(?:start|run|runSync)\(',
];

/// Kotlin: URL / socket / resolver APIs, the places a libbox instance or the platform's sockets are
/// made or protected, and the network-state callbacks.
const kotlinNetworkPatterns = [
  r'\bHttps?URLConnection\b',
  r'\.openConnection\(',
  r'\bURL\(',
  r'\bjava\.net\.(?:Socket|DatagramSocket|ServerSocket|URL)\b',
  r'\bOkHttp|\bokhttp3\b',
  r'\bDnsResolver\b',
  r'\bgetAllByName\(',
  r'\.protect\(',
  r'\bautoDetectInterfaceControl\b',
  r'\bLibboxBox\(',
  r'\.bindSocket\(',
  r'\bbindProcessToNetwork\(',
  r'\bProcessBuilder\b|\bRuntime\.getRuntime\(\)\.exec',
  r'\bWebView\b|\bDownloadManager\b',
  r'\b(?:requestNetwork|registerNetworkCallback|registerDefaultNetworkCallback|registerBestMatchingNetworkCallback)\(',
];

const coreScope = ScanScope('core', 'core/lib/src', ['.dart'], dartNetworkPatterns);
const appDartScope = ScanScope('app (Dart)', 'app/lib', ['.dart'], dartNetworkPatterns);
// the overlay is the source of the generated app/android/**/*.kt
const appKotlinScope = ScanScope('app (Kotlin)', 'app/android_overlay/kotlin', ['.kt', '.kt.tmpl'], kotlinNetworkPatterns);

/// The repository root: the nearest directory upwards (from the test's working directory) that holds
/// `core/lib/src/outside_tunnel.dart`.
Directory repoRoot() {
  var d = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    if (File('${d.path}/core/lib/src/outside_tunnel.dart').existsSync()) return d;
    d = d.parent;
  }
  throw StateError('repo root not found from ${Directory.current.path}');
}

bool _comment(String l) {
  final t = l.trimLeft();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

/// Files of [scope] that use a network API → the first matching lines (`line: text`).
Map<String, List<String>> scanScope(Directory root, ScanScope scope) {
  final dir = Directory('${root.path}/${scope.dir}');
  final res = [for (final p in scope.patterns) RegExp(p)];
  final out = <String, List<String>>{};
  for (final e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !scope.exts.any(e.path.endsWith)) continue;
    final rel = '${scope.dir}/${e.path.substring(dir.path.length + 1).replaceAll('\\', '/')}';
    final lines = e.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (_comment(l)) continue;
      if (res.any((r) => r.hasMatch(l))) out.putIfAbsent(rel, () => []).add('${i + 1}: ${l.trim()}');
    }
  }
  return out;
}

const _howTo = 'Register it in core/lib/src/outside_tunnel.dart (an OutsideEntry with `how`: ownRule / '
    'protectedSocket / loopback / noConnection — make sure that way is true: a connection of the app\'s '
    'own enters the TUN and must be matched by the self rule), and update docs/platforms.md → «Работа вне туннеля».';

/// What is wrong with [scope] against the registry; empty = fine.
List<String> scopeProblems(Directory root, ScanScope scope) {
  final found = scanScope(root, scope);
  final registered = {
    for (final e in outsideTunnel)
      for (final f in e.files) f: e.id,
  };
  final out = <String>[];
  for (final f in found.keys) {
    if (!registered.containsKey(f)) {
      out.add('$f opens a connection or a process but is not in the outside-tunnel registry '
          '(${scope.name}):\n    ${found[f]!.take(3).join('\n    ')}\n  $_howTo');
    }
  }
  for (final e in outsideTunnel) {
    for (final f in e.files) {
      if (!f.startsWith('${scope.dir}/')) continue;
      if (!File('${root.path}/$f').existsSync()) {
        out.add('Registry entry "${e.id}" lists $f, which does not exist: remove or fix the path in core/lib/src/outside_tunnel.dart.');
      } else if (!found.containsKey(f)) {
        out.add('Registry entry "${e.id}" lists $f, which no longer uses a network API: remove it from '
            'core/lib/src/outside_tunnel.dart (and from docs/platforms.md if it is named there), or extend '
            'the patterns in core/test/outside_tunnel_scan.dart if the file now opens connections another way.');
      }
    }
  }
  return out;
}

/// Sanity of the registry itself, independent of the sources.
List<String> registryProblems(Directory root) {
  final out = <String>[];
  final ids = <String>{};
  const scopes = [coreScope, appDartScope, appKotlinScope];
  for (final e in outsideTunnel) {
    if (!ids.add(e.id)) out.add('Duplicate registry id "${e.id}".');
    if (e.files.isEmpty) out.add('Registry entry "${e.id}" has no files.');
    if (e.what.trim().isEmpty) out.add('Registry entry "${e.id}" says nothing in `what`.');
    for (final f in e.files) {
      if (!scopes.any((s) => f.startsWith('${s.dir}/'))) {
        out.add('Registry entry "${e.id}": $f is outside the scanned places (${scopes.map((s) => s.dir).join(', ')}).');
      }
    }
  }
  return out;
}
