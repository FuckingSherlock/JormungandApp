// The Priority order, live (docs/connect-model.md → «Порядок Priority — вживую»). nodeKeyOfTag (plan.dart) takes the node
// key out of a group member's sing-box tag; priorityReorder (plan_order.dart) says whether two plans differ only in
// the order of nodes inside Priority groups, and gives that order per selector tag.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

// a server of a group, as plan_builder.dart's livePlan() shapes it
Map<String, dynamic> _node(String key) => {
  'key': key,
  'outbound': {'type': 'trojan', 'tag': key, 'server': '192.0.2.10', 'server_port': 443, 'password': 'pw'},
  'flag': 'NL',
};

Map<String, dynamic> _group(String pick, List<String> keys, String chosen) => {
  'pick': pick,
  'chosen': chosen,
  'nodes': [for (final k in keys) _node(k)],
};

// A plan in livePlan()'s shape: unit route 'u0' on [r0] (Priority), chain route 'c1' (entry and main on [r1EntryPick] /
// [r1MainPick]), rule targets 'chain:c' (entry and main Priority) and 'profile:p1' (on [profilePick]). Lists are server orders.
Map<String, dynamic> _base({
  List<String> r0 = const ['a', 'b', 'c'],
  List<String> r1Entry = const ['e1', 'e2'],
  String r1EntryPick = 'fastest',
  List<String> r1Main = const ['m1', 'm2', 'm3'],
  String r1MainPick = 'fastest',
  List<String> chainEntry = const ['ce1', 'ce2'],
  List<String> chainMain = const ['cm1', 'cm2'],
  List<String> profile = const ['f1', 'f2'],
  String profilePick = 'fastest',
}) => {
  'mode': 'proxy',
  'mixedPort': 2080,
  'tunStack': 'mixed',
  'current': 0,
  'routes': [
    {'id': 'u0', 'kind': 'unit', 'main': _group('priority', r0, 'a')},
    {
      'id': 'c1',
      'kind': 'chain',
      'entry': _group(r1EntryPick, r1Entry, 'e1'),
      'main': _group(r1MainPick, r1Main, 'm1'),
    },
  ],
  'routing': {
    'apps': [],
    'rules': [
      {'action': 'proxy', 'target': 'chain:c', 'match': {'domain': ['example.com']}},
    ],
    'quick': {'ads': false, 'final': 'main'},
    'fallback': 'main',
    'targets': {
      'profile:p1': {'kind': 'unit', 'main': _group(profilePick, profile, 'f1')},
      'chain:c': {
        'kind': 'chain',
        'entry': _group('priority', chainEntry, 'ce1'),
        'main': _group('priority', chainMain, 'cm1'),
      },
    },
    'dns': {'servers': ['192.0.2.53']},
  },
};

Map<String, dynamic> _routeMain(Map<String, dynamic> plan, int i) =>
    ((plan['routes'] as List)[i] as Map<String, dynamic>)['main'] as Map<String, dynamic>;

void main() {
  group('nodeKeyOfTag', () {
    for (final (tag, key) in <(String, String?)>[
      ('route0/src2::n3aa', 'src2::n3aa'),
      ('route0-entry/s::n', 's::n'),
      ('chain:c/s::n', 's::n'),
      ('chain:c>entry/s::n', 's::n'),
      ('route0/x/y::n', 'x/y::n'),
      ('s::n', 's::n'),
      ('direct', null),
      ('block', null),
      ('proxy', null),
      ('', null),
      ('route0/s', null),
    ]) {
      test('"$tag" -> ${key == null ? 'null' : '"$key"'}', () => expect(nodeKeyOfTag(tag), key));
    }
  });

  group('priorityReorder', () {
    test('equal plans -> {} (not null)', () {
      expect(priorityReorder(_base(), _base()), equals(<String, List<String>>{}));
    });

    final reorders = <(String, Map<String, dynamic>, Map<String, dynamic>, Map<String, List<String>>)>[
      ('a Priority route group', _base(), _base(r0: ['c', 'a', 'b']), {'route0': ['c', 'a', 'b']}),
      (
        'a Priority chain entry (routeEntryTag)',
        _base(r1EntryPick: 'priority'),
        _base(r1EntryPick: 'priority', r1Entry: ['e2', 'e1']),
        {'route1-entry': ['e2', 'e1']},
      ),
      (
        'a Priority chain main (routeTag)',
        _base(r1MainPick: 'priority'),
        _base(r1MainPick: 'priority', r1Main: ['m3', 'm1', 'm2']),
        {'route1': ['m3', 'm1', 'm2']},
      ),
      ('a rule target chain entry', _base(), _base(chainEntry: ['ce2', 'ce1']), {'chain:c>entry': ['ce2', 'ce1']}),
      ('a rule target chain main', _base(), _base(chainMain: ['cm2', 'cm1']), {'chain:c': ['cm2', 'cm1']}),
      (
        'a Priority rule target unit',
        _base(profilePick: 'priority'),
        _base(profilePick: 'priority', profile: ['f2', 'f1']),
        {'profile:p1': ['f2', 'f1']},
      ),
      (
        'two groups at once: only they are listed',
        _base(),
        _base(r0: ['c', 'a', 'b'], chainMain: ['cm2', 'cm1']),
        {'route0': ['c', 'a', 'b'], 'chain:c': ['cm2', 'cm1']},
      ),
    ];
    for (final (name, from, to, want) in reorders) {
      test('order only changed, $name -> {selector tag: new order}', () {
        expect(priorityReorder(from, to), equals(want));
      });
    }

    // a node set change, a Fastest group's order, or a pinned pick moved: no order-only change
    final nulls = <(String, Map<String, dynamic>)>[
      ('a node added to a Priority group', _base(r0: ['a', 'b', 'c', 'd'])),
      ('a node removed from a Priority group', _base(r0: ['a', 'b'])),
      ('a node swapped for another', _base(r0: ['c', 'a', 'x'])),
      ('a Fastest route group reordered', _base(r1MainPick: 'fastest', r1Main: ['m3', 'm2', 'm1'])),
      ('a Fastest rule target reordered', _base(profile: ['f2', 'f1'])),
      ('a Priority and a Fastest group reordered together', _base(r0: ['c', 'a', 'b'], r1Main: ['m3', 'm1', 'm2'])),
    ];
    for (final (name, to) in nulls) {
      test('$name -> null', () => expect(priorityReorder(_base(), to), isNull));
    }

    // any other field changed: null, alone and together with a Priority reorder
    final changes = <(String, void Function(Map<String, dynamic> p))>[
      ('mode', (Map<String, dynamic> p) {
        p['mode'] = 'tun';
      }),
      ('a rule', (Map<String, dynamic> p) {
        ((p['routing'] as Map)['rules'] as List)[0] = {'action': 'direct', 'target': '', 'match': {'domain': ['example.com']}};
      }),
      ('dns', (Map<String, dynamic> p) {
        ((p['routing'] as Map)['dns'] as Map)['servers'] = ['192.0.2.99'];
      }),
      ('the flag of a server in a Priority group', (Map<String, dynamic> p) {
        (((_routeMain(p, 0)['nodes'] as List)[1]) as Map<String, dynamic>)['flag'] = 'DE';
      }),
      ('the outbound of a server in a Priority group', (Map<String, dynamic> p) {
        ((((_routeMain(p, 0)['nodes'] as List)[1]) as Map<String, dynamic>)['outbound'] as Map<String, dynamic>)['server'] =
            '192.0.2.99';
      }),
      ('an extra route', (Map<String, dynamic> p) {
        (p['routes'] as List).add({'id': 'u9', 'kind': 'unit', 'main': _group('fastest', ['x1'], 'x1')});
      }),
    ];
    for (final (name, change) in changes) {
      test('$name changed -> null, alone or with a Priority reorder', () {
        final alone = _base();
        change(alone);
        final withReorder = _base(r0: ['c', 'a', 'b']);
        change(withReorder);
        expect(priorityReorder(_base(), alone), isNull);
        expect(priorityReorder(_base(), withReorder), isNull);
      });
    }

    test('a pinned group: a different chosen -> null, with or without a reorder', () {
      Map<String, dynamic> pinned(String chosen, List<String> order) {
        final p = _base(r0: order);
        _routeMain(p, 0)
          ..['pinned'] = true
          ..['chosen'] = chosen;
        return p;
      }

      expect(priorityReorder(pinned('a', ['a', 'b', 'c']), pinned('b', ['a', 'b', 'c'])), isNull);
      expect(priorityReorder(pinned('a', ['a', 'b', 'c']), pinned('b', ['c', 'a', 'b'])), isNull);
    });

    // a route group that is not pinned: its chosen is the core's to move, so it is ignored (planSigOf's rule)
    test('a non-pinned route group: a different chosen is ignored, the order is still returned', () {
      final moved = _base(r0: ['c', 'a', 'b']);
      _routeMain(moved, 0)['chosen'] = 'b';
      expect(priorityReorder(_base(), moved), equals({'route0': ['c', 'a', 'b']}));
      final movedOnly = _base();
      _routeMain(movedOnly, 0)['chosen'] = 'b';
      expect(priorityReorder(_base(), movedOnly), equals(<String, List<String>>{}));
    });

    // a rule target's Priority pick does count: only a new plan moves it (planSigOf's rule)
    Map<String, dynamic> target(Map<String, dynamic> plan, String t, String part) =>
        (((plan['routing'] as Map)['targets'] as Map)[t] as Map)[part] as Map<String, dynamic>;

    test('a Priority rule target (chain main): a different chosen -> null', () {
      final moved = _base();
      target(moved, 'chain:c', 'main')['chosen'] = 'cm2';
      expect(priorityReorder(_base(), moved), isNull);
    });

    test('a Priority rule target (unit): a different chosen -> null', () {
      final moved = _base(profilePick: 'priority');
      target(moved, 'profile:p1', 'main')['chosen'] = 'f2';
      expect(priorityReorder(_base(profilePick: 'priority'), moved), isNull);
    });
  });
}
