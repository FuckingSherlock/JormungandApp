// The editors' draft operations of the Nodes screen (profile / chain forms, the source entry
// sheet, server sort): ports of the mockup's cpSourceState / toggleCpNode / pickChainSide / ... .
import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

import 'catalog_model_test.dart' show clock, make, ping, t0;

void main() {
  setUp(() => clock = t0);

  group('server lists', () {
    test('sortedNodes: order keeps, name is case-insensitive and stable, latency by rank', () {
      final c = make();
      final a = c.sourcesData['a']!;
      a.nodes[0] = CatalogNode(id: 'a1', name: 'beta');
      a.nodes[1] = CatalogNode(id: 'a2', name: 'Alpha');
      a.nodes[2] = CatalogNode(id: 'a3', name: 'alpha');
      expect(c.sortedNodes(a.nodes, 'order', (n) => n).map((n) => n.id), ['a1', 'a2', 'a3']);
      expect(c.sortedNodes(a.nodes, 'name', (n) => n).map((n) => n.id), ['a2', 'a3', 'a1']);
      ping(c, 'a::a1', 300);
      ping(c, 'a::a2', 20);
      ping(c, 'a::a3', -1);
      expect(c.sortedNodes(a.nodes, 'latency', (n) => n).map((n) => n.id), ['a2', 'a1', 'a3']);
      expect(c.byPing(a.nodes, (n) => n).map((n) => n.id), ['a2', 'a1', 'a3']);
    });

    test('reorderKeys: hidden items keep their slots, new ones follow', () {
      expect(reorderKeys(['x', 'h', 'y', 'z'], ['x', 'y', 'z'], ['z', 'x', 'y']), ['z', 'h', 'x', 'y']);
      expect(reorderKeys(['h'], ['x', 'y'], ['y', 'x']), ['h', 'y', 'x']);
    });
  });

  group('profile editor', () {
    test('source tick: none -> all -> none, a switched-off source only drops out', () {
      final c = make();
      final d = Profile(id: 'draft');
      expect(c.profileDraftSourceState(d, 'a'), PickState.none);
      c.toggleProfileDraftSource(d, 'a');
      expect(d.sources, ['a']);
      expect(c.profileDraftSourceState(d, 'a'), PickState.all);
      c.toggleProfileDraftSource(d, 'a');
      expect(d.sources, isEmpty);
      c.toggleProfileDraftNode(d, 'a', 'a1');
      expect(c.profileDraftSourceState(d, 'a'), PickState.some);
      c.toggleProfileDraftSource(d, 'a'); // some -> the whole source
      expect(d.sources, ['a']);
      expect(d.nodes, isEmpty);
      c.sourcesData['a']!.enabled = false;
      c.toggleProfileDraftSource(d, 'a');
      expect(d.sources, isEmpty);
    });

    test('server tick: untick one of a whole source = all but this; the last tick collapses', () {
      final c = make();
      final d = Profile(id: 'draft', sources: ['a']);
      c.toggleProfileDraftNode(d, 'a', 'a2');
      expect(d.sources, isEmpty);
      expect(d.nodes, ['a::a1', 'a::a3']);
      c.toggleProfileDraftNode(d, 'a', 'a2');
      expect(d.sources, ['a']);
      expect(d.nodes, isEmpty);
    });

    test('source list: switched-off source shows only while the draft uses it', () {
      final c = make();
      c.sourcesData['b']!.enabled = false;
      final d = Profile(id: 'draft');
      expect(c.profileDraftSourceIds(d), ['a']);
      d.sources = ['b'];
      expect(c.profileDraftSourceIds(d), ['a', 'b']);
    });

    test('saveProfile: problem when empty, new one appended with a default name, edit keeps unknown', () {
      final c = make();
      expect(c.saveProfile(Profile(id: 'draft')), isNotNull);
      expect(c.profilesData.length, 1);
      expect(c.saveProfile(Profile(id: 'draft', sources: ['a'])), isNull);
      expect(c.profilesData.length, 2);
      final id = c.catalogOrder['profiles']!.last;
      expect(id, isNot('p'));
      expect(c.profilesData[id]!.name, 'Profile 2');
      expect(c.profileSeq, 2);
      // edit
      c.profilesData['p']!.unknown['color'] = 'red';
      final d = Profile(id: 'draft', name: 'Renamed', nodes: ['b::b1'], pickMode: 'priority', inAuto: false);
      expect(c.saveProfile(d, editId: 'p'), isNull);
      final p = c.profilesData['p']!;
      expect(p.name, 'Renamed');
      expect(p.sources, isEmpty);
      expect(p.nodes, ['b::b1']);
      expect(p.pickMode, 'priority');
      expect(p.inAuto, isFalse);
      expect(p.unknown['color'], 'red');
      expect(c.profilesData.length, 2);
    });

    test('newProfileId never repeats within the same millisecond', () {
      final c = make();
      expect(c.saveProfile(Profile(id: 'd', sources: ['a'])), isNull);
      expect(c.saveProfile(Profile(id: 'd', sources: ['b'])), isNull);
      expect(c.profilesData.keys.toSet().length, 3);
    });

    test('Priority drag keeps the order of hidden picks', () {
      final c = make();
      final d = Profile(id: 'draft', sources: ['a'], pickMode: 'priority');
      c.reorderProfileDraftPick(d, ['a::a3', 'a::a1', 'a::a2']);
      expect(d.pickOrder, ['a::a3', 'a::a1', 'a::a2']);
    });
  });

  group('chain editor', () {
    test('pickChainSide forgets the left-out servers of the old unit', () {
      final c = make();
      final d = c.newChainDraft('a', 'b')..inOff = ['a::a1'];
      d
        ..outOff = ['b::b1']
        ..exitOrder = ['b::b2'];
      c.chainPickSide(d, 'in', 'a');
      expect(d.inOff, ['a::a1']);
      c.chainPickSide(d, 'out', 'a');
      expect(d.outOff, isEmpty);
      expect(d.exitOrder, isEmpty);
      expect(d.outId, 'a');
    });

    test('swap: ends and their ticks change places, exit order resets', () {
      final c = make();
      final d = c.newChainDraft('a', 'b')
        ..inOff = ['a::a1']
        ..outOff = ['b::b1']
        ..exitOrder = ['b::b2'];
      c.chainSwapEnds(d);
      expect((d.inId, d.outId), ('b', 'a'));
      expect(d.inOff, ['b::b1']);
      expect(d.outOff, ['a::a1']);
      expect(d.exitOrder, isEmpty);
    });

    test('toggle and All / None of an end', () {
      final c = make();
      final d = c.newChainDraft('a', 'b');
      c.chainToggleNode(d, 'in', 'a::a2');
      expect(d.inOff, ['a::a2']);
      c.chainToggleNode(d, 'in', 'a::a2');
      expect(d.inOff, isEmpty);
      c.chainToggleNode(d, 'out', 'b::b1');
      c.chainSetNodesAll(d, 'out'); // some off -> everything on
      expect(d.outOff, isEmpty);
      d.outOff = ['b::gone'];
      c.chainSetNodesAll(d, 'out'); // all on -> everything off, a dropped server keeps its tick
      expect(d.outOff, ['b::gone', 'b::b1', 'b::b2']);
    });

    test('saveChain: validation, default name, tab, edit', () {
      final c = make();
      expect(c.saveChain(c.newChainDraft('a', 'a')), isNotNull);
      expect(c.saveChain(c.newChainDraft('a', null)), isNotNull);
      expect(c.chainsData.length, 1);
      expect(c.saveChain(c.newChainDraft('a', 'b')), isNull);
      final id = c.catalogOrder['simple']!.last;
      expect(c.chainsData[id]!.name, 'Chain 2');
      final d = c.chainDraftOf('c1')
        ..name = 'Renamed'
        ..exitMode = 'priority';
      expect(c.saveChain(d, editId: 'c1'), isNull);
      expect(c.chainsData['c1']!.name, 'Renamed');
      expect(c.chainsData['c1']!.exitMode, 'priority');
      expect(c.chainsData.length, 2);
    });

    test('exit drag', () {
      final c = make();
      final d = c.newChainDraft('b', 'a');
      c.chainReorderExit(d, ['a::a3', 'a::a2', 'a::a1']);
      expect(d.exitOrder, ['a::a3', 'a::a2', 'a::a1']);
    });

    group('disabled in subscription, switched on for this chain', () {
      List<String> keys(Iterable<NodeRef> rs) => [for (final r in rs) r.key];

      test('offered only for a source end; forcing puts it into the chain group, not into the source', () {
        final c = make();
        c.sourcesData['a']!.offNodes = ['a2'];
        final d = c.chainDraftOf('c1'); // b -> a
        expect(keys(c.chainOffRefs(d, 'out')), ['a::a2']);
        expect(keys(c.chainOffRefs(d, 'in')), isEmpty);
        expect(keys(c.chainExitRefs(d)), ['a::a1', 'a::a3']);
        c.chainForceNode(d, 'out', 'a::a2');
        c.chainForceNode(d, 'out', 'a::a1'); // not off in the subscription: nothing to force
        expect(d.outOn, ['a::a2']);
        expect(keys(c.chainExitRefs(d)), ['a::a1', 'a::a3', 'a::a2']);
        expect(c.saveChain(d, editId: 'c1'), isNull);
        final nodes = [for (final n in (c.planRoute('c1')['main'] as Map)['nodes'] as List) n['key']];
        expect(nodes, containsAll(['a::a1', 'a::a2', 'a::a3']));
        // the subscription itself, Simple (its own entry) and Nodes keep it disabled
        expect(keys(c.unitRefs('a')), ['a::a1', 'a::a3']);
        expect(c.sourcesData['a']!.offNodes, ['a2']);
        expect(c.isNodeOff(c.sourcesData['a']!, 'a2'), isTrue);
        final p = c.planRoute('a')['main']['nodes'] as List;
        expect(p.map((n) => n['key']), isNot(contains('a::a2')));
        expect(keys(c.unitRefs('p')), contains('a::a2')); // a profile does not read offNodes
      });

      test('a tap on a forced server sends it back; None leaves it; ends swap with it; a new unit forgets it', () {
        final c = make();
        c.sourcesData['a']!.offNodes = ['a2'];
        final d = c.newChainDraft('b', 'a');
        c.chainForceNode(d, 'out', 'a::a2');
        c.chainSetNodesAll(d, 'out');
        expect(d.outOn, ['a::a2']);
        c.chainSwapEnds(d);
        expect(d.inId, 'a');
        expect(d.inOn, ['a::a2']);
        expect(d.outOn, isEmpty);
        expect(d.inOff, ['a::a1', 'a::a3']); // None ticked the normal ones off, the forced one stays
        expect(keys(c.chainEntryRefs(d)), ['a::a2']);
        c.chainToggleNode(d, 'in', 'a::a2');
        expect(d.inOn, isEmpty);
        expect(d.inOff, ['a::a1', 'a::a3']);
        c.chainForceNode(d, 'in', 'a::a2');
        c.chainPickSide(d, 'in', 'b');
        expect(d.inOn, isEmpty);
      });

      test('a chain whose only servers are forced on is valid', () {
        final c = make();
        c.sourcesData['b']!.offNodes = ['b1', 'b2'];
        final d = c.newChainDraft('b', 'a');
        expect(c.chainEntryRefs(d), isEmpty);
        c.chainForceNode(d, 'in', 'b::b2');
        expect(c.chainProblems(d), isEmpty);
        expect(c.saveChain(d, editId: 'c1'), isNull);
        expect(keys(c.chainEntryRefs(c.chainsData['c1']!)), ['b::b2']);
        expect((c.planRoute('c1')['entry']['nodes'] as List).map((n) => n['key']), ['b::b2']);
      });

      test('survives a refresh by identity, waits while the server is dropped, is forgotten with it', () {
        final c = make();
        final a = c.sourcesData['a']!;
        a.offNodes = ['a2'];
        c.chainsData['c1']!.outOn = ['a::a2'];
        final n2 = a.nodes.firstWhere((n) => n.id == 'a2');
        a.nodes = a.nodes.where((n) => n.id != 'a2').toList(); // the provider dropped it
        a.gone = [n2];
        expect(keys(c.chainExitRefs(c.chainsData['c1']!)), ['a::a1', 'a::a3']);
        expect(c.chainsData['c1']!.outOn, ['a::a2']);
        a.nodes = [...a.nodes, n2]; // it came back with the same id
        a.gone = [];
        expect(keys(c.chainExitRefs(c.chainsData['c1']!)), contains('a::a2'));
        c.deleteNode('a', 'a2');
        expect(c.chainsData['c1']!.outOn, isEmpty);
        c.chainsData['c1']!.inOn = ['b::b1'];
        c.deleteSource('b');
        expect(c.chainsData.containsKey('c1'), isFalse);
      });

      test('JSON: written only when non-empty, unknown keys stay', () {
        final c = make();
        final j = c.chainsData['c1']!.toJson();
        expect(j.containsKey('inOn'), isFalse);
        expect(j.containsKey('outOn'), isFalse);
        c.chainsData['c1']!
          ..inOn = ['b::b1']
          ..outOn = ['a::a2'];
        final back = Chain.fromJson(jsonDecode(jsonEncode(c.chainsData['c1']!.toJson())) as Map<String, dynamic>);
        expect(back.inOn, ['b::b1']);
        expect(back.outOn, ['a::a2']);
        expect(Catalog.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>).chainsData['c1']!.outOn, ['a::a2']);
        expect(c.chainDraftOf('c1').outOn, ['a::a2']);
      });
    });
  });

  group('entry settings and source entry', () {
    test('setEntryPickMode / Order for a source, a profile and a chain', () {
      final c = make();
      c.setEntryPickMode('a', 'priority');
      c.setEntryPickOrder('a', ['a::a2']);
      expect(c.sourcesData['a']!.pickMode, 'priority');
      expect(c.sourcesData['a']!.pickOrder, ['a::a2']);
      c.setEntryPickMode('p', 'priority');
      expect(c.profilesData['p']!.pickMode, 'priority');
      c.setEntryPickMode('c1', 'priority');
      c.setEntryPickOrder('c1', ['a::a3']);
      expect(c.chainsData['c1']!.exitMode, 'priority');
      expect(c.chainsData['c1']!.exitOrder, ['a::a3']);
    });

    test('offNodes toggle and All / None', () {
      final c = make();
      expect(c.offNodesToggled('a', 'a1'), ['a1']);
      c.sourcesData['a']!.offNodes = ['a1', 'zz'];
      expect(c.offNodesToggled('a', 'a1'), ['zz']);
      expect(c.offNodesAll('a'), ['zz']); // some off -> all on, a dropped one keeps its mark
      c.sourcesData['a']!.offNodes = [];
      expect(c.offNodesAll('a'), ['a1', 'a2', 'a3']);
    });

    test('source entry order includes left-out servers; drag merges into pickOrder', () {
      final c = make();
      final s = c.sourcesData['a']!..offNodes = ['a2'];
      expect(c.sourceEntryRefs('a').map((r) => r.key), ['a::a1', 'a::a2', 'a::a3']);
      c.reorderSourceEntry('a', ['a::a3', 'a::a2', 'a::a1']);
      expect(s.pickOrder, ['a::a3', 'a::a2', 'a::a1']);
      expect(c.sourceEntryRefs('a').map((r) => r.key), ['a::a3', 'a::a2', 'a::a1']);
    });
  });
}
