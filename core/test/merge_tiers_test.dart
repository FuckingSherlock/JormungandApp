import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

// Made-up VLESS servers on *.example. `acc` is the account (uuid: the credentials), `sni` the
// variant (another SNI is another variant of the same server), `port` the server port.
String _uuid(int acc) => '11111111-2222-3333-4444-${acc.toString().padLeft(12, '0')}';

Node vl(int acc, String host, String sni, {String name = 'Srv', int port = 443}) =>
    parseLink('vless://${_uuid(acc)}@$host:$port?security=tls&sni=$sni#$name')!;

List<Node> servers(int acc, List<int> idx) =>
    [for (final i in idx) vl(acc, 's$i.example', 's$i.example', name: 'S$i')];

List<String> idsOf(List<Map<String, dynamic>> nodes) => [for (final n in nodes) n['id'] as String];

void main() {
  group('tier 3: same protocol, address, port and variant, other credentials', () {
    test('keeps the id of a 1:1 pair, even when the name changed', () {
      final prev = mergeUpdate([], [], [vl(1, 't3.example', 'a.example', name: 'Old')]);
      final next = mergeUpdate(prev.nodes, prev.gone, [vl(2, 't3.example', 'a.example', name: 'Renamed')]);
      expect(next.nodes.single['id'], prev.nodes.single['id']);
      expect(next.gone, isEmpty);
    });

    test('compares the address in lowercase', () {
      final prev = mergeUpdate([], [], [vl(1, 't3.example', 'a.example')]);
      final oldUpper = {...prev.nodes.single, 'address': 'T3.EXAMPLE'};
      final next = mergeUpdate([oldUpper], [], [vl(2, 't3.example', 'a.example')]);
      expect(next.nodes.single['id'], prev.nodes.single['id']);
      expect(next.gone, isEmpty);
    });
  });

  group('tier 4: same protocol, address and port, variant and credentials both changed', () {
    test('keeps the id', () {
      final prev = mergeUpdate([], [], [vl(1, 't4.example', 'a.example')]);
      final next = mergeUpdate(prev.nodes, prev.gone, [vl(2, 't4.example', 'b.example')]);
      expect(next.nodes.single['id'], prev.nodes.single['id']);
      expect(next.gone, isEmpty);
    });

    test('another address or port is another server: new id, old one goes to gone', () {
      final prev = mergeUpdate([], [], [vl(1, 't4.example', 'a.example')]);
      for (final c in [('other.example', 443), ('t4.example', 8443)]) {
        final next = mergeUpdate(prev.nodes, [], [vl(2, c.$1, 'b.example', port: c.$2)]);
        expect(next.nodes.single['id'], isNot(prev.nodes.single['id']), reason: '${c.$1}:${c.$2}');
        expect(next.gone.map((n) => n['id']), [prev.nodes.single['id']], reason: '${c.$1}:${c.$2}');
      }
    });
  });

  group('ambiguous group: pair by name', () {
    test('tier 2: one account, one server, two variants renamed in the same group', () {
      final prev = mergeUpdate([], [], [
        vl(1, 'g2.example', 'x.example', name: 'Alpha'),
        vl(1, 'g2.example', 'y.example', name: 'Beta'),
      ]);
      final alpha = prev.nodes[0]['id'], beta = prev.nodes[1]['id'];
      // fresh order is swapped, so position alone would pair them wrongly
      final next = mergeUpdate(prev.nodes, [], [
        vl(1, 'g2.example', 'q.example', name: 'Beta'),
        vl(1, 'g2.example', 'p.example', name: 'Alpha'),
      ]);
      expect(idsOf(next.nodes), [beta, alpha]);
      expect(next.gone, isEmpty);
    });

    test('tier 3: old name "Omega-N" (with or without rawName) pairs with fresh "Omega"', () {
      final prev = mergeUpdate([], [], [
        vl(1, 'g3.example', 's.example', name: 'Omega'),
        vl(2, 'g3.example', 's.example', name: 'Psi'),
      ]);
      final omega = prev.nodes[0]['id'], psi = prev.nodes[1]['id'];
      for (final oldOmega in [
        {...prev.nodes[0], 'name': 'Omega-1', 'rawName': 'Omega'},
        {...prev.nodes[0], 'name': 'Omega-2', 'num': 2},
      ]) {
        final next = mergeUpdate([oldOmega, prev.nodes[1]], [], [
          vl(4, 'g3.example', 's.example', name: 'Psi'),
          vl(3, 'g3.example', 's.example', name: 'Omega'),
        ]);
        expect(idsOf(next.nodes), [psi, omega], reason: '${oldOmega['name']}');
        expect(next.gone, isEmpty, reason: '${oldOmega['name']}');
      }
    });

    test('tier 4: two servers of one host, both variant and credentials changed', () {
      final prev = mergeUpdate([], [], [
        vl(1, 'g4.example', 'a.example', name: 'Alpha'),
        vl(2, 'g4.example', 'b.example', name: 'Beta'),
      ]);
      final alpha = prev.nodes[0]['id'], beta = prev.nodes[1]['id'];
      final next = mergeUpdate(prev.nodes, [], [
        vl(4, 'g4.example', 'd.example', name: 'Beta'),
        vl(3, 'g4.example', 'c.example', name: 'Alpha'),
      ]);
      expect(idsOf(next.nodes), [beta, alpha]);
      expect(next.gone, isEmpty);
    });

    test('a name repeated among the old nodes of the group is not paired; the unique one still is', () {
      final prev = mergeUpdate([], [], [
        vl(1, 'dup.example', 's.example', name: 'Alpha'),
        vl(2, 'dup.example', 's.example', name: 'Dup'),
        vl(3, 'dup.example', 's.example', name: 'Dup'),
      ]);
      final alpha = prev.nodes[0]['id'];
      final oldDup = [prev.nodes[1]['id'], prev.nodes[2]['id']];
      final next = mergeUpdate(prev.nodes, [], [
        vl(4, 'dup.example', 's.example', name: 'Alpha'),
        vl(5, 'dup.example', 's.example', name: 'Dup'),
        vl(6, 'dup.example', 's.example', name: 'Dup'),
      ]);
      expect(next.nodes[0]['id'], alpha);
      for (final n in next.nodes.skip(1)) {
        expect(oldDup, isNot(contains(n['id'])));
      }
      expect(next.gone.map((n) => n['id']).toSet(), oldDup.toSet());
    });

    test('a name repeated among the fresh nodes of the group is not paired', () {
      final prev = mergeUpdate([], [], [
        vl(1, 'rep.example', 's.example', name: 'Alpha'),
        vl(2, 'rep.example', 's.example', name: 'Beta'),
      ]);
      final oldIds = idsOf(prev.nodes);
      final next = mergeUpdate(prev.nodes, [], [
        vl(3, 'rep.example', 's.example', name: 'Alpha'),
        vl(4, 'rep.example', 's.example', name: 'Alpha'),
      ]);
      for (final id in idsOf(next.nodes)) {
        expect(oldIds, isNot(contains(id)));
      }
      expect(next.gone.map((n) => n['id']).toSet(), oldIds.toSet());
    });
  });

  test('a node matched by an earlier tier is no candidate for a later tier', () {
    final prev = mergeUpdate([], [], [
      vl(1, 'o.example', 'a.example', name: 'Ann'),
      vl(2, 'o.example', 'a.example', name: 'Bob'),
    ]);
    final ann = prev.nodes[0]['id'], bob = prev.nodes[1]['id'];
    // Ann is matched by tier 1; Cid is then the only fresh node left for Bob's group
    final next = mergeUpdate(prev.nodes, [], [
      vl(1, 'o.example', 'a.example', name: 'Ann'),
      vl(3, 'o.example', 'a.example', name: 'Cid'),
    ]);
    expect(idsOf(next.nodes), [ann, bob]);
    expect(next.gone, isEmpty);
  });

  test('scenario: URL to account B, then account C, keeps every id and brings gone nodes back', () {
    final a = mergeUpdate([], [], servers(1, [1, 2, 3, 4, 5]));
    final original = idsOf(a.nodes);

    // B: s4 and s5 are gone
    final b = mergeUpdate(a.nodes, a.gone, servers(2, [1, 2, 3]));
    expect(idsOf(b.nodes), original.sublist(0, 3));
    expect(b.gone.map((n) => n['id']).toSet(), original.sublist(3).toSet());

    // C: s4 and s5 come back from gone with their original ids
    final c = mergeUpdate(b.nodes, b.gone, servers(3, [1, 2, 3, 4, 5]));
    expect(idsOf(c.nodes), original);
    expect(c.gone, isEmpty);
  });
}
