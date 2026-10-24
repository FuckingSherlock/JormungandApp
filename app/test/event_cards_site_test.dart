// Model tests of siteCard (docs/connect-model.md «Карточка сайта», visuals .claude_states/dns_site_schemes.html §4;
// English texts as the app shows them). The title counts the servers: own + tried + the opening one, the checker is
// not counted; blocked reads «K of N». Checked: a bad row per tried node, blocked has an ok row of the via node (no
// «opens in»), the checker row by its result. The Rule row: an existing rule («<host> rule», «<route>: <target>») or
// «Create <host> rule» (Fallback = the opening node, blocked only). Buttons: Details first, then Ignore site, no
// Check again. Old events without the new fields still give a card.
// Per-row recheck (app-site-wire): data.nodes drives the Checked rows and the counts (own + nodes; K = own + red); a
// green node makes the title «K of N», the Cause line «<own> — the site opens through another server» and the new
// Rule row «Fallback: <first green node>» (any type); no green: the unreachable wording and no Fallback. The route row
// is a CheckRow above the Checked section (retry = own key, go). Busy comes from ctx.busy(key). The checker row is
// busy while pending (drawn from prev when it has one). earlierChecks reads kind node lines by name.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/core/event_cards_site.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/widgets/event_card.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

const _t0 = 1800000000000; // a fixed clock, in ms
const _host = 'shop.example';
const _own = 'src1::n1'; // «One» of «Alpha», the own route of the failed connection
const _via = 'src2::m1'; // «Remote» of «Beta», where the site opened (blocked)
const _tried = <Map<String, dynamic>>[
  {'entry': 'src1', 'server': 'src1::n2'}, // «Two»
  {'entry': 'src1', 'server': 'src1::n3'}, // «Three»
];

final _en = lookupAppLocalizations(const Locale('en'));

const _names = {'src1::n1': 'One', 'src1::n2': 'Two', 'src1::n3': 'Three', 'src2::m1': 'Remote'};
const _subs = {'src1': 'Alpha', 'src2': 'Beta'};
const _protos = {'src1::n1': 'vless', 'src1::n2': 'hysteria2', 'src1::n3': 'vless', 'src2::m1': 'vless'};

/// The catalog the event rows look names up in: the same subscriptions and nodes as [_names] and [_subs].
final _words = () {
  final host = FakeCoreHost();
  host.catalog.addSource(
    Source(
      id: 'src1',
      kind: 'sub',
      name: 'Alpha',
      url: 'https://sub.example/alpha',
      nodes: [
        CatalogNode(id: 'n1', name: 'One', protocol: 'vless', address: 'one.example.com'),
        CatalogNode(id: 'n2', name: 'Two', protocol: 'hysteria2', address: 'two.example.com'),
        CatalogNode(id: 'n3', name: 'Three', protocol: 'vless', address: 'three.example.com'),
      ],
    ),
  );
  host.catalog.addSource(
    Source(
      id: 'src2',
      kind: 'sub',
      name: 'Beta',
      url: 'https://sub.example/beta',
      nodes: [CatalogNode(id: 'm1', name: 'Remote', protocol: 'vless', address: 'remote.example.com')],
    ),
  );
  return EventWords(_en, host.catalog);
}();

({String sub, String proto, String node})? _nodeInfo(String key) {
  final sid = key.split('::').first;
  final node = _names[key];
  if (node == null) return null;
  return (sub: _subs[sid] ?? sid, proto: _protos[key] ?? '', node: node);
}

/// The event as the journal holds it (`site/<type>`, level warn).
EventRecord _ev(String type, Map<String, dynamic> data) => EventRecord.fromJson({
  'id': 1,
  'at': _t0,
  'cat': 'site',
  'type': type,
  'level': 'warn',
  'own': false,
  'data': data,
});

/// `site/unreachable` data (logs.md: host, entry, server, dest, tried, rule, check?).
Map<String, dynamic> _unreachable({List<Map<String, dynamic>> tried = const [], Map<String, dynamic>? check}) => {
  'host': _host,
  'entry': 'src1',
  'server': _own,
  'dest': '$_host:443',
  'tried': tried,
  'rule': {'kind': 'final'},
  'check': ?check,
};

/// `site/blocked` data (logs.md: host, entry, server, dest, via, viaServer, rule; tried when other nodes were tried).
Map<String, dynamic> _blocked({
  List<Map<String, dynamic>> tried = const [],
  bool via = true,
  Map<String, dynamic>? check,
}) => {
  'host': _host,
  'entry': 'src1',
  'server': _own,
  'dest': '$_host:443',
  if (via) 'via': 'src2',
  if (via) 'viaServer': _via,
  if (tried.isNotEmpty) 'tried': tried,
  'rule': {'kind': 'final'},
  'check': ?check,
};

Map<String, dynamic> _data(String type, {List<Map<String, dynamic>> tried = const [], Map<String, dynamic>? check}) =>
    type == 'blocked' ? _blocked(tried: tried, check: check) : _unreachable(tried: tried, check: check);

/// A checker result as the core writes it (`check`: state, at, kind, via, total).
Map<String, dynamic> _checker(String state) => {
  'state': state,
  'at': _t0,
  'kind': 'http',
  'via': 'tunnel',
  'total': 8,
};

/// Records what the buttons and rows call, in order.
class _Calls {
  final List<String> log = [];

  /// The row keys (a node key, the own key, or 'checker') that are busy now.
  final Set<String> busyKeys = {};

  SiteCardCtx ctx({int repeats = 1, bool background = false, ({String id, String route, String target})? rule}) =>
      SiteCardCtx(
        l: _en,
        words: _words,
        repeats: repeats,
        background: background,
        nodeLabel: (k) => _names[k] ?? k,
        sourceLabel: (id) => _subs[id] ?? id,
        nodeInfo: _nodeInfo,
        ruleFor: (host) => rule,
        onDetails: () => log.add('details'),
        onIgnore: (_) => log.add('ignore'),
        onOpenApp: () => log.add('app'),
        onOpenRule: (id) => log.add('rule:$id'),
        onCreateRule: () => log.add('createRule'),
        onGoNode: (k) => log.add('go:$k'),
        onRecheckNode: (k) => log.add('recheck:$k'),
        onRecheckChecker: () => log.add('checker'),
        busy: (k) => busyKeys.contains(k),
      );
}

EventCardModel _card(String type, Map<String, dynamic> data, SiteCardCtx ctx) => siteCard(_ev(type, data), ctx)!;

List<KeyRow> _keys(EventCardModel m) =>
    m.blocks.whereType<DataBox>().expand((b) => b.rows).whereType<KeyRow>().toList();

List<CheckRow> _checks(EventCardModel m) =>
    m.blocks.whereType<DataBox>().expand((b) => b.rows).whereType<CheckRow>().toList();

/// The rows under the «Checked» section (the route row above that section is not one of them).
List<CheckRow> _checkedRows(EventCardModel m) {
  final rows = m.blocks.whereType<DataBox>().expand((b) => b.rows).toList();
  final i = rows.indexWhere((r) => r is CardSection && r.title == 'Checked');
  return i < 0 ? const [] : rows.sublist(i + 1).whereType<CheckRow>().toList();
}

/// The words of a check row: its value and its sub line.
String _text(CheckRow r) => '${r.value} ${r.sub ?? ''}';

/// The own route row (sub «└ One»; its value «Alpha · vless» is shared with another vless node of the source).
CheckRow _route(EventCardModel m) => _checks(m).singleWhere((r) => r.sub == '└ One');

KeyRow _keyRow(EventCardModel m, String value) => _keys(m).singleWhere((r) => r.value == value);

/// The check row of a node (its name is in the sub line, `└ <node>`) or of the checker (its value names it).
CheckRow _check(EventCardModel m, String text) =>
    _checks(m).singleWhere((r) => r.value.contains(text) || (r.sub ?? '').contains(text));

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  group('title', () {
    test('unreachable: N = own + tried; the checker is not counted', () {
      final m = _card('unreachable', _data('unreachable', tried: _tried, check: _checker('failed')), _Calls().ctx());
      expect(m.title, 'shop.example did not open on 3 servers');
    });

    test('unreachable with nothing tried: one server, singular', () {
      expect(_card('unreachable', _data('unreachable'), _Calls().ctx()).title, 'shop.example did not open on 1 server');
    });

    test('blocked: K of N, N = own + tried + the opening one, K = those that did not open', () {
      expect(
        _card('blocked', _data('blocked', tried: _tried), _Calls().ctx()).title,
        'shop.example did not open on 3 of 4 servers',
      );
    });

    test('blocked with nothing tried: own and the opening one, 1 of 2', () {
      expect(_card('blocked', _blocked(), _Calls().ctx()).title, 'shop.example did not open on 1 of 2 servers');
    });

    test('the copy part of the title is the host, for unreachable and blocked', () {
      for (final type in ['unreachable', 'blocked']) {
        expect(_card(type, _data(type), _Calls().ctx()).copy, _host);
      }
    });
  });

  group('header', () {
    for (final type in ['unreachable', 'blocked']) {
      test('$type: warn level, the repeats and the background of the call, a time', () {
        final m = _card(type, _data(type), _Calls().ctx(repeats: 3, background: true));
        expect(m.level, CardLevel.warn);
        expect(m.repeats, 3);
        expect(m.background, isTrue);
        expect(m.time, isNotNull);
      });

      test('$type: not a background call, no background', () {
        expect(_card(type, _data(type), _Calls().ctx()).background, isFalse);
      });
    }
  });

  group('Checked', () {
    for (final type in ['unreachable', 'blocked']) {
      test('$type: a Checked section, a bad row per tried node; retry and go on the row; own route not repeated', () {
        final c = _Calls();
        final m = _card(type, _data(type, tried: _tried), c.ctx());
        expect(m.blocks.whereType<DataBox>().expand((b) => b.rows).whereType<CardSection>().map((s) => s.title),
            contains('Checked'));
        expect(_checkedRows(m).any((r) => _text(r).contains('One')), isFalse, reason: 'the own route is not a checked row');

        final two = _check(m, 'Two');
        expect(two.ok, isFalse);
        two.onRetry!();
        two.onGo!();
        expect(c.log, ['recheck:src1::n2', 'go:src1::n2']);
        expect(_check(m, 'Three').ok, isFalse);
      });
    }

    test('blocked: a green row of the via node, no «opens in», retry through it', () {
      final c = _Calls();
      final m = _card('blocked', _blocked(), c.ctx());
      final via = _check(m, 'Remote');
      expect(via.ok, isTrue);
      expect(via.value, contains('Beta'));
      expect(via.sub ?? '', isNot(contains('opens')));
      via.onRetry!();
      expect(c.log, ['recheck:src2::m1']);
    });

    test('unreachable without a checker: no ok row at all', () {
      final m = _card('unreachable', _data('unreachable', tried: _tried), _Calls().ctx());
      expect(_checks(m).where((r) => r.ok == true), isEmpty);
    });

    for (final s in [('opens', true), ('down', false), ('failed', false)]) {
      test('checker row: «check-host.net · …», ok by the result (${s.$1}), retry on the row', () {
        final c = _Calls();
        final m = _card('unreachable', _data('unreachable', check: _checker(s.$1)), c.ctx());
        final row = _check(m, 'check-host.net');
        expect(row.value, contains('check-host.net'));
        expect(row.ok, s.$2);
        row.onRetry!();
        expect(c.log, ['checker']);
      });
    }
  });

  group('Rule row', () {
    for (final type in ['unreachable', 'blocked']) {
      test('$type: an existing rule shows «<host> rule» and «<route>: <target>», tap opens its form, no Fallback', () {
        final c = _Calls();
        final m = _card(type, _data(type), c.ctx(rule: (id: 'r1', route: 'Proxy', target: 'main flow')));
        final row = _keyRow(m, 'shop.example rule');
        expect(row.sub, 'Proxy: main flow');
        row.onTap!();
        expect(c.log, ['rule:r1']);
        expect(_keys(m).any((r) => r.value.startsWith('Create')), isFalse);
      });
    }

    test('unreachable: a new rule has no sub line (Fallback is Default), tap opens the rule form', () {
      final c = _Calls();
      final m = _card('unreachable', _data('unreachable'), c.ctx());
      final row = _keyRow(m, 'Create shop.example rule');
      expect(row.sub, isNull);
      row.onTap!();
      expect(c.log, ['createRule']);
    });

    test('blocked: a new rule has «Fallback: <the opening node>»', () {
      final c = _Calls();
      final m = _card('blocked', _blocked(), c.ctx());
      final row = _keyRow(m, 'Create shop.example rule');
      expect(row.sub, startsWith('Fallback: '));
      expect(row.sub, contains('Remote'));
      row.onTap!();
      expect(c.log, ['createRule']);
    });
  });

  group('Route row', () {
    for (final type in ['unreachable', 'blocked']) {
      test('$type: the own route is a bad CheckRow «<sub> · <proto>», sub «└ <node>», above the Checked section, no Route label', () {
        final m = _card(type, _data(type, tried: _tried), _Calls().ctx());
        final rows = m.blocks.whereType<DataBox>().expand((b) => b.rows).toList();
        final route = _route(m);
        expect(route.sub, '└ One');
        expect(route.ok, isFalse);
        expect(route.marquee, isTrue);
        expect(rows.indexOf(route), lessThan(rows.indexWhere((r) => r is CardSection && r.title == 'Checked')));
        expect(_keys(m).where((r) => r.name == 'Route'), isEmpty);
      });

      test('$type: the own route retries the own node (its key), go opens Routes at the node', () {
        final c = _Calls();
        final route = _route(_card(type, _data(type), c.ctx()));
        route.onRetry!();
        route.onGo!();
        expect(c.log, ['recheck:src1::n1', 'go:src1::n1']);
      });
    }
  });

  group('Cause', () {
    test('blocked: bold is the node of the original route, the rest says the site opens through another server', () {
      final m = _card('blocked', _blocked(), _Calls().ctx());
      expect(m.cause, isNotNull);
      expect(m.cause!.$1, contains('One'));
      expect(m.cause!.$2, 'the site opens through another server');
    });

    test('unreachable: there is a cause line', () {
      expect(_card('unreachable', _data('unreachable'), _Calls().ctx()).cause, isNotNull);
    });
  });

  group('data.nodes drives the rows, the counts and the Fallback (app-site-wire)', () {
    // three checked nodes: one bad, two that opened (the first one with its time)
    final nodes = [
      {'entry': 'src1', 'server': 'src1::n3', 'ok': false},
      {'entry': 'src1', 'server': 'src1::n2', 'ok': true, 'ms': 120},
      {'entry': 'src2', 'server': 'src2::m1', 'ok': true},
    ];

    /// The base data of [type] with [nodes] in place of the legacy tried/via fields.
    Map<String, dynamic> withNodes(String type, List<Map<String, dynamic>> items) => {
      ...(type == 'blocked' ? _blocked(via: false) : _unreachable()),
      'nodes': items,
    };

    test('one Checked row per item in its order, colour by ok, «opens in N ms» only when ok with ms', () {
      final m = _card('unreachable', withNodes('unreachable', nodes), _Calls().ctx());
      final rows = _checkedRows(m);
      expect(rows.map((r) => r.ok), [false, true, true]);
      expect(_text(rows[0]), contains('Three'));
      expect(_text(rows[1]), contains('Two'));
      expect(_text(rows[1]), contains('opens in 120 ms'), reason: 'the opensInMs string');
      expect(_text(rows[2]), contains('Remote'));
      expect(rows[2].sub ?? '', isNot(contains('opens in')));
    });

    test('data.nodes replaces the legacy tried/via: only its items are rows', () {
      final m = _card(
        'unreachable',
        {..._unreachable(tried: _tried), 'nodes': [{'entry': 'src2', 'server': 'src2::m1', 'ok': true}]},
        _Calls().ctx(),
      );
      final rows = _checkedRows(m);
      expect(rows, hasLength(1));
      expect(rows.single.ok, isTrue);
      expect(_text(rows.single), contains('Remote'));
    });

    for (final type in ['unreachable', 'blocked']) {
      test('$type with a green node: the title is «did not open on K of N servers», K = own + the red ones, N = own + the items', () {
        expect(_card(type, withNodes(type, nodes), _Calls().ctx()).title, 'shop.example did not open on 2 of 4 servers');
      });

      test('$type with no green node: «did not open on N servers», N = own + the items', () {
        final red = [
          {'entry': 'src1', 'server': 'src1::n3', 'ok': false},
          {'entry': 'src1', 'server': 'src1::n2', 'ok': false},
        ];
        expect(_card(type, withNodes(type, red), _Calls().ctx()).title, 'shop.example did not open on 3 servers');
      });

      test('$type with a green node: the Rule row says «Fallback: <first green node>»', () {
        final m = _card(type, withNodes(type, nodes), _Calls().ctx());
        final row = _keyRow(m, 'Create shop.example rule');
        expect(row.sub, startsWith('Fallback: '));
        expect(row.sub, contains('Two'), reason: 'the first green node, not the last one');
        expect(row.sub, isNot(contains('Remote')));
      });

      test('$type with a green node: the Cause is «<own node> — the site opens through another server»', () {
        final m = _card(type, withNodes(type, nodes), _Calls().ctx());
        expect(m.cause!.$1, contains('One'));
        expect(m.cause!.$2, 'the site opens through another server');
      });
    }

    test('unreachable with no green node: no Fallback, the unreachable cause', () {
      final red = [
        {'entry': 'src1', 'server': 'src1::n3', 'ok': false},
      ];
      final m = _card('unreachable', withNodes('unreachable', red), _Calls().ctx());
      expect(_keyRow(m, 'Create shop.example rule').sub, isNull);
      expect(m.cause, isNotNull);
      expect(m.cause!.$2, isNot('the site opens through another server'));
    });

    test('no own route (no entry, no server): N counts the items only', () {
      final data = {
        'host': _host,
        'nodes': [
          {'entry': 'src1', 'server': 'src1::n3', 'ok': false},
        ],
      };
      expect(_card('unreachable', data, _Calls().ctx()).title, 'shop.example did not open on 1 server');
    });

    test('unreachable, the checker says down everywhere: no route and no node rows, the title says «does not open»', () {
      final data = {..._unreachable(tried: _tried), 'check': _checker('down')};
      final m = _card('unreachable', data, _Calls().ctx());
      expect(m.title, contains('does not open'));
      expect(m.title, isNot(contains('server')));
      expect(_checks(m).where((r) => (r.sub ?? '').contains('└')), isEmpty);
      expect(_keys(m).where((r) => (r.sub ?? '').contains('└')), isEmpty);
      expect(_checks(m).where((r) => r.value.contains('Alpha')), isEmpty);
    });
  });

  group('busy and the checker while pending (app-site-wire)', () {
    test('a node row, the own route row and the checker row take busy from ctx.busy(key)', () {
      final c = _Calls()..busyKeys.addAll(['src1::n2', 'src1::n1', 'checker']);
      final m = _card('unreachable', {..._unreachable(tried: _tried), 'check': _checker('opens')}, c.ctx());
      expect(_check(m, 'Two').busy, isTrue);
      expect(_check(m, 'Three').busy, isFalse);
      expect(_route(m).busy, isTrue);
      expect(_check(m, 'check-host.net').busy, isTrue);
    });

    test('no busy key: no row is busy', () {
      final m = _card('unreachable', {..._unreachable(tried: _tried), 'check': _checker('opens')}, _Calls().ctx());
      expect(_checks(m).where((r) => r.busy), isEmpty);
    });

    for (final s in [('opens', true), ('failed', false)]) {
      test('checker pending with prev ${s.$1}: the previous outcome (ok ${s.$2}), busy', () {
        final data = _data(
          'unreachable',
          check: {'state': 'pending', 'at': _t0, 'manual': true, 'prev': _checker(s.$1)},
        );
        final row = _check(_card('unreachable', data, _Calls().ctx()), 'check-host.net');
        expect(row.ok, s.$2);
        expect(row.busy, isTrue);
      });
    }

    test('checker pending without prev: no outcome yet, ok null, sub «checking…», busy', () {
      final data = _data('unreachable', check: {'state': 'pending', 'at': _t0, 'manual': true});
      final row = _check(_card('unreachable', data, _Calls().ctx()), 'check-host.net');
      expect(row.ok, isNull);
      expect(row.sub, _en.checking);
      expect(row.busy, isTrue);
    });
  });

  group('earlierChecks with node checks (app-site-wire)', () {
    test('a node check reads «HH:MM · <node> · opened» or «HH:MM · <node> · did not open»', () {
      final e = _ev('blocked', {
        ..._blocked(via: false),
        'checks': [
          {'at': _t0, 'kind': 'node', 'server': 'src1::n2', 'ok': true},
          {'at': _t0 + 60000, 'kind': 'node', 'server': 'src1::n3', 'ok': false},
        ],
      });
      final lines = _words.earlierChecks(e);
      expect(lines, hasLength(2));
      expect(lines.where(RegExp(r'^\d{2}:\d{2} · Two · opened$').hasMatch), hasLength(1));
      expect(lines.where(RegExp(r'^\d{2}:\d{2} · Three · did not open$').hasMatch), hasLength(1));
    });
  });

  group('buttons', () {
    for (final type in ['unreachable', 'blocked']) {
      test('$type: Details first, then Ignore site; no Check again; the callbacks fire', () {
        final c = _Calls();
        final m = _card(type, _data(type), c.ctx());
        expect(m.actions.length, 2);
        expect(m.actions.first.details, isTrue);
        expect(m.actions.first.label, contains('Details'));
        expect(m.actions[1].details, isFalse);
        expect(m.actions[1].label, contains('Ignore site'));
        expect(m.actions.any((a) => a.label.contains('Check again')), isFalse);

        m.actions.first.onTap();
        m.actions[1].onMenu!(Rect.zero);
        expect(c.log, ['details', 'ignore']);
      });
    }
  });

  group('old events', () {
    for (final type in ['unreachable', 'blocked']) {
      test('$type with only the host: still a card, rows without data are skipped', () {
        final m = _card(type, {'host': _host}, _Calls().ctx());
        expect(m.title, contains(_host));
        expect(_checks(m), isEmpty); // no tried, no checker, no via
        expect(_checks(m).any((r) => (r.sub ?? '').contains('└')), isFalse); // no route row
      });
    }
  });

  test('not a site event: no card', () {
    final e = EventRecord.fromJson({
      'id': 2,
      'at': _t0,
      'cat': 'conn',
      'type': 'connected',
      'level': 'info',
      'own': true,
      'data': <String, dynamic>{},
    });
    expect(siteCard(e, _Calls().ctx()), isNull);
  });
}
