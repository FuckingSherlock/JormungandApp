// Server lists sorted By latency (`Catalog.sortedNodes(list, 'latency', nodeOf)`), the decision of
// 2026-10-20 (docs/connect-model.md, «Сортировка списков серверов By latency»): enabled with an answer
// by ping; enabled without an answer; switched off in Nodes last, always below the enabled ones.
// "Off in Nodes" = the server is in its source's `disabledNodes`, or the whole source is `enabled == false`.
// Among the off ones: by last ping; without a ping the provider (incoming) order.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'catalog_model_test.dart' show clock, make, ping, t0;

CatalogNode at(Catalog c, String key) {
  final parts = key.split('::');
  return c.sourcesData[parts[0]]!.nodes.firstWhere((n) => n.id == parts[1]);
}

/// The ids of [keys] (`sid::nid`) sorted By latency with the identity `nodeOf`.
List<String> latency(Catalog c, List<String> keys) => [
      for (final n in c.sortedNodes([for (final k in keys) at(c, k)], 'latency', (n) => n)) n.id,
    ];

void main() {
  setUp(() => clock = t0);

  group('By latency: enabled servers', () {
    test('with an answer by ping, quickest first; then the ones without an answer', () {
      final c = make();
      ping(c, 'a::a1', 300);
      ping(c, 'a::a2', 20);
      ping(c, 'b::b1', 5);
      ping(c, 'a::a3', -1); // dead
      // a3 is dead, b2 is not measured
      final r = latency(c, ['a::a1', 'a::a3', 'b::b2', 'a::a2', 'b::b1']);
      expect(r.take(3), ['b1', 'a2', 'a1']);
      expect(r.skip(3), unorderedEquals(['a3', 'b2']));
    });

    test('without an answer keep the incoming order', () {
      final c = make();
      expect(latency(c, ['b::b2', 'b::b1', 'a::a3', 'a::a2', 'a::a1']), ['b2', 'b1', 'a3', 'a2', 'a1']);
    });

    test('empty list gives an empty list', () {
      final c = make();
      expect(latency(c, []), isEmpty);
    });
  });

  group('By latency: switched off in Nodes', () {
    test('a single server off goes below every enabled one, even a faster ping and a dead enabled one', () {
      final c = make();
      c.sourcesData['a']!.disabledNodes = ['a2'];
      ping(c, 'a::a2', 5); // off, but the fastest of all
      ping(c, 'a::a1', 300);
      ping(c, 'a::a3', -1); // enabled, dead
      final r = latency(c, ['a::a2', 'a::a1', 'a::a3', 'b::b1', 'b::b2']);
      expect(r.length, 5);
      expect(r.first, 'a1');
      expect(r.last, 'a2');
      expect(r.sublist(1, 4), unorderedEquals(['a3', 'b1', 'b2']));
    });

    test('a whole source off (enabled == false) goes below every enabled server', () {
      final c = make();
      c.sourcesData['b']!.enabled = false;
      ping(c, 'b::b1', 1); // off source, fastest ping
      ping(c, 'a::a1', 500);
      ping(c, 'a::a3', 700);
      // a2 is enabled and not measured: above the off source
      expect(latency(c, ['b::b1', 'b::b2', 'a::a1', 'a::a2', 'a::a3']), ['a1', 'a3', 'a2', 'b1', 'b2']);
    });

    test('among themselves by last ping, quickest first', () {
      final c = make();
      c.sourcesData['a']!.disabledNodes = ['a1', 'a3'];
      c.sourcesData['b']!.disabledNodes = ['b1'];
      ping(c, 'a::a2', 400); // enabled
      ping(c, 'b::b2', 800); // enabled
      ping(c, 'a::a1', 200); // off
      ping(c, 'a::a3', 30); // off
      ping(c, 'b::b1', 90); // off
      expect(latency(c, ['a::a1', 'b::b1', 'a::a2', 'a::a3', 'b::b2']), ['a2', 'b2', 'a3', 'b1', 'a1']);
    });

    test('without a ping keep the provider order (the incoming order), below the enabled ones', () {
      final c = make();
      c.sourcesData['a']!.disabledNodes = ['a1', 'a3'];
      c.sourcesData['b']!.disabledNodes = ['b1'];
      ping(c, 'a::a2', 10); // enabled, answered
      // b2 enabled, not measured; a1, a3, b1 off and not measured; input reversed on purpose
      expect(latency(c, ['b::b1', 'a::a3', 'b::b2', 'a::a2', 'a::a1']), ['a2', 'b2', 'b1', 'a3', 'a1']);
    });
  });

  group('other sorts are not changed', () {
    test('order and name sorts ignore the switched-off mark', () {
      final c = make();
      c.sourcesData['a']!.disabledNodes = ['a2'];
      final list = [for (final k in ['a::a2', 'b::b1', 'a::a1']) at(c, k)];
      expect([for (final n in c.sortedNodes(list, 'order', (n) => n)) n.id], ['a2', 'b1', 'a1']);
      expect([for (final n in c.sortedNodes(list, 'name', (n) => n)) n.id], ['a1', 'a2', 'b1']);
    });

    test('byPing ignores the switched-off mark', () {
      final c = make();
      c.sourcesData['a']!.disabledNodes = ['a1'];
      ping(c, 'a::a1', 5);
      ping(c, 'a::a2', 300);
      final list = [at(c, 'a::a2'), at(c, 'a::a1')];
      expect([for (final n in c.byPing(list, (n) => n)) n.id], ['a1', 'a2']);
    });
  });
}
