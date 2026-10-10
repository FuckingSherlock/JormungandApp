// The outside-tunnel registry (lib/src/outside_tunnel.dart) against the core's sources: a file that
// opens a connection or starts a process and is not registered fails here, so that code which has
// to work outside the tunnel cannot be added (or brought over from the other platform) and
// forgotten. The app's own Dart and Kotlin are checked by app/test/outside_tunnel_guard_test.dart
// with the same scanner. Failure messages say what to do.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'outside_tunnel_scan.dart';

void main() {
  final root = repoRoot();

  test('the registry is well formed: unique ids, files inside the scanned places', () {
    expect(registryProblems(root), isEmpty);
    expect(OutsideHow.values, hasLength(4));
    expect(outsideTunnel.map((e) => e.how).toSet(), containsAll(OutsideHow.values), reason: 'every kind is in use');
  });

  test('every file of the core that opens a connection or a process is registered, and every registered one still does', () {
    final problems = scopeProblems(root, coreScope);
    expect(problems, isEmpty, reason: '\n${problems.join('\n\n')}');
  });

  test('the scan is not blind: it finds the known network files and ignores comments', () {
    final found = scanScope(root, coreScope).keys.toSet();
    expect(found, containsAll(['core/lib/src/fetch.dart', 'core/lib/src/dns_probe.dart', 'core/lib/src/runtime.dart', 'core/lib/src/probe.dart']));
    expect(found, isNot(contains('core/lib/src/outside_tunnel.dart')), reason: 'names in comments are not usage');

    final tmp = Directory.systemTemp.createTempSync('jorm-scan');
    try {
      Directory('${tmp.path}/x').createSync();
      File('${tmp.path}/x/a.dart').writeAsStringSync("// HttpClient() in a comment\nfinal c = HttpClient();\n");
      File('${tmp.path}/x/b.dart').writeAsStringSync("/// Process.run('x')\nfinal ok = 1;\n");
      final hits = scanScope(tmp, const ScanScope('t', 'x', ['.dart'], dartNetworkPatterns));
      expect(hits.keys, ['x/a.dart']);
      expect(hits['x/a.dart'], ['2: final c = HttpClient();']);
      // an unregistered file in a scope is reported with what to do; a registered path that is gone too
      final problems = scopeProblems(tmp, const ScanScope('t', 'x', ['.dart'], dartNetworkPatterns));
      expect(problems.single, allOf(contains('x/a.dart'), contains('outside_tunnel.dart'), contains('platforms.md')));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('the self rules are in the config for every kind that needs them (ownRule entries exist)', () {
    // the registry says the app has connections that rely on the self rule: the builder must make one
    expect(outsideTunnel.any((e) => e.how == OutsideHow.ownRule), isTrue);
    expect(selfRules(packages: ['dev.jormungand.app']), [
      {'package_name': ['dev.jormungand.app'], 'action': 'route', 'outbound': 'direct'},
    ]);
    expect(selfRules(paths: [Platform.resolvedExecutable]).single['outbound'], 'direct');
    expect(selfRules(), isEmpty);
  });
}
