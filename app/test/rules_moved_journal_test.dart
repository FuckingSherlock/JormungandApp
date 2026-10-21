// The one-time move of own rules with an app condition into the apps' rules, on an Android load (docs/rules.md
// «Перенос при обновлении»). A real LiveCoreHost over a CoreService with a fake runner: the catalog does the move,
// the host writes the one `rulesMoved` journal line of that load (count and names).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/live_core_host.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'live_core_host_test.dart' show FakeRunner, snapshot, testBoxes;

/// An own rule as the catalog stores it: a non-inverted process group for [pkgs] and a domain group.
Map<String, dynamic> _ownRule(String id, String name, List<String> pkgs) => {
  ...(newRule(
    groups: {
      'process': {'not': false, 'v': {'process': pkgs}},
      'domain': {'not': false, 'v': {'domain_suffix': ['$id.example']}},
    },
  )..action = 'direct').toJson(),
  'id': id,
  'name': name,
  'enabled': true,
};

void main() {
  test('an Android load moves the process rules into the apps and journals exactly one rulesMoved line', () async {
    final dir = Directory.systemTemp.createTempSync('jorm_moved_');
    try {
      final s = snapshot()
        ..['rulesData'] = {
          'r1': _ownRule('r1', 'Work', ['com.a', 'com.b']),
          'r2': _ownRule('r2', 'Home', ['com.a', 'com.b']),
        }
        ..['ruleOrder'] = ['r1', 'r2'];
      File('${dir.path}/ui-state.json').writeAsStringSync(jsonEncode(s));

      final core = CoreService(
        singBox: '',
        dataDir: dir.path,
        runner: FakeRunner(),
        boxFactory: testBoxes,
        sysProxy: NoSystemProxy(),
        isElevated: () => true,
        resolveAddresses: false,
      );
      final host = LiveCoreHost(api: core, isAndroid: true);
      try {
        await host.init();

        final events = [
          for (final e in (core.eventBook.since(null)['events'] as List).cast<Map>())
            if (e['type'] == 'rulesMoved') e,
        ];
        expect(events, hasLength(1), reason: 'one line for the whole move');
        final data = events.single['data'] as Map;
        expect(data['count'], 2);
        expect(data['names'], ['Work', 'Home']);

        expect(host.catalog.rulesData, isEmpty, reason: 'the own rules are now in the apps');
        for (final pkg in ['com.a', 'com.b']) {
          expect(
            [for (final r in host.catalog.appRules[pkg]!.rules) r.name],
            ['Work', 'Home'],
            reason: pkg,
          );
        }
      } finally {
        await host.shutdown();
        host.dispose();
      }
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
