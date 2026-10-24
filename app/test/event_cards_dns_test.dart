// Pure model tests of the DNS event cards (app/lib/core/event_cards_dns.dart; docs/logs.md «DNS-события: состав и
// карточки»): the card of dns/switched, dns/transport, dns/down, dns/up, and the DNS blocks of net/switched (data.dns).
// Fixtures use made-up provider names: every name in the output must come from the data, not from the code.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/event_cards_dns.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/widgets/event_card.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

final _en = lookupAppLocalizations(const Locale('en'));

/// The event time and the start of the silence 12 s before it (ms since epoch, as the journal keeps them).
const _at = 1700000000000;
const _since = _at - 12000;

EventRecord _ev(String cat, String type, Map<String, dynamic> data, {String level = 'warn'}) => EventRecord.fromJson({
  'id': 7,
  'at': _at,
  'cat': cat,
  'type': type,
  'level': level,
  'own': false,
  'data': data,
});

/// The context the card takes from the event rows: the lookups are tagged (N:…, S:…, Root #…) so a test sees which
/// one was used; the callbacks record their calls in [calls].
DnsCardCtx _ctx(List<String> calls, {int repeats = 1}) => DnsCardCtx(
  l: _en,
  repeats: repeats,
  nodeLabel: (k) => 'N:$k',
  sourceLabel: (s) => 'S:$s',
  causeTitle: (id) => 'Root #$id',
  onDetails: () => calls.add('details'),
  onDnsSettings: (side) => calls.add('dnsSettings:$side'),
  onOpenEvent: (id) => calls.add('event:$id'),
  onGoNode: (k) => calls.add('node:$k'),
);

/// One side of a switch: the server [from] (silent transports [silent], since [_since]) > the server [to] (answering
/// transport [kind], 40 ms).
Map<String, dynamic> _switch(
  String side, {
  String from = 'Zeta DNS',
  String to = 'Quad Relay',
  List<String> silent = const ['doh', 'dot'],
  String kind = 'udp',
}) => {
  'side': side,
  'from': {'provider': 'p-$from', 'name': from, 'silent': silent, 'since': _since},
  'to': {'provider': 'p-$to', 'name': to, 'kind': kind, 'ms': 40},
};

/// One side of a transport change of the same server: [from] transports > [to].
Map<String, dynamic> _transport(String side, {String name = 'Zeta DNS', List<String> from = const ['dot'], String to = 'doh'}) => {
  'side': side,
  'provider': 'p-$name',
  'name': name,
  'from': from,
  'to': to,
  'ms': 35,
};

Map<String, dynamic> _switched({
  required List<Map<String, dynamic>> sides,
  bool same = false,
  Map<String, dynamic>? route,
  Map<String, dynamic> cause = const {'kind': 'none'},
}) => {
  'reason': 'failover',
  'sides': sides,
  'same': same,
  'route': ?route,
  'cause': cause,
};

const _route = <String, dynamic>{'sub': 'sub1', 'proto': 'vless', 'node': 'sub1::n1'};

SwitchFrame _frame(EventCardModel m) => m.blocks.whereType<SwitchFrame>().single;

DataBox _box(EventCardModel m) => m.blocks.whereType<DataBox>().single;

String _causeText(EventCardModel m) => '${m.cause!.$1} ${m.cause!.$2}';

void main() {
  group('dns/switched', () {
    test('title, level from the event, and one row for the VPN side: from (silent, no answer for N s) > to (transport, ms)', () {
      final m = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('vpn')])), _ctx([]))!;
      expect(m.title, _en.dnsSwitched);
      expect(m.level, CardLevel.warn);

      final row = _frame(m).rows.single;
      expect(row.label, _en.vpn);
      expect(row.from.title, 'Zeta DNS');
      expect(row.from.sub, 'DoH, DoT · ${_en.noAnswerForS(12)}');
      expect(row.to.title, 'Quad Relay');
      expect(row.to.sub, startsWith('UDP · '));
      expect(row.to.sub, contains('40'));

      final info = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('vpn')]), level: 'info'), _ctx([]))!;
      expect(info.level, CardLevel.info, reason: 'the level follows the event (back, node, off: info)');
    });

    final sideCases = <(String, List<Map<String, dynamic>>, bool, List<String>)>[
      ('VPN only: the VPN label', [_switch('vpn')], false, [_en.vpn]),
      ('Direct only: the Direct label', [_switch('direct')], false, [_en.direct3]),
      (
        'both sides changed the same way: one row, the label VPN / Direct in two lines',
        [_switch('vpn'), _switch('direct')],
        true,
        ['${_en.vpn}\n${_en.direct3}'],
      ),
      (
        'both sides changed differently: a row per side, in one frame',
        [_switch('vpn'), _switch('direct', from: 'Local Blue', to: 'Dial Two')],
        false,
        [_en.vpn, _en.direct3],
      ),
    ];
    for (final (name, sides, same, labels) in sideCases) {
      test(name, () {
        final m = dnsCard(_ev('dns', 'switched', _switched(sides: sides, same: same)), _ctx([]))!;
        expect(m.blocks.whereType<SwitchFrame>(), hasLength(1));
        expect([for (final r in _frame(m).rows) r.label], labels);
      });
    }

    test('the provider names on the chips come from the data, per side', () {
      final m = dnsCard(
        _ev('dns', 'switched', _switched(sides: [_switch('vpn'), _switch('direct', from: 'Local Blue', to: 'Dial Two')])),
        _ctx([]),
      )!;
      expect([for (final r in _frame(m).rows) r.from.title], ['Zeta DNS', 'Local Blue']);
      expect([for (final r in _frame(m).rows) r.to.title], ['Quad Relay', 'Dial Two']);
    });

    test('the Route row shows with the VPN side: source · protocol, the node below; a tap goes to the node', () {
      final calls = <String>[];
      final m = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('vpn')], route: _route)), _ctx(calls))!;
      final row = _box(m).rows.whereType<KeyRow>().single;
      expect(row.value, 'S:sub1 · vless');
      expect(row.sub, contains('N:sub1::n1'));
      row.onGo!();
      expect(calls, ['node:sub1::n1']);
    });

    test('no Route row for a Direct-only event, even with a route in the data', () {
      final m = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('direct')], route: _route)), _ctx([]))!;
      expect(m.blocks.whereType<DataBox>().expand((b) => b.rows).whereType<KeyRow>(), isEmpty);
    });

    // «<A> itself — <B> answers through the same route»; transport: «<DoT> does not answer on this route — <DoH> of the
    // same server does»; node: «node <X> — <server> answers through another node»; no outer cause: the root event's
    // title; none: «Cause not established»
    final causeCases = <(String, Map<String, dynamic>, List<String>)>[
      (
        'itself',
        {'kind': 'itself', 'a': 'Zeta DNS', 'b': 'Quad Relay'},
        [_en.itself('Zeta DNS'), _en.answersThroughTheSameRoute('Quad Relay')],
      ),
      (
        'transport',
        {'kind': 'transport', 'a': 'dot', 'b': 'doh'},
        [_en.doesNotAnswerOnThisRoute('DoT'), _en.ofTheSameServerDoes('DoH')],
      ),
      (
        'node',
        {'kind': 'node', 'node': 'sub1::n1', 'server': 'Zeta DNS'},
        [_en.node('N:sub1::n1'), _en.answersThroughAnotherNode('Zeta DNS')],
      ),
      ('network change: the root event title', {'kind': 'net', 'id': 5}, ['Root #5']),
      ('reconnect: the root event title', {'kind': 'reconnect', 'id': 9}, ['Root #9']),
      ('none: not established', {'kind': 'none'}, [_en.causeNotEstablishedSeeTheChecks]),
    ];
    for (final (name, cause, parts) in causeCases) {
      test('Cause is always there; $name', () {
        final m = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('vpn')], cause: cause)), _ctx([]))!;
        expect(m.cause, isNotNull);
        for (final part in parts) {
          expect(_causeText(m), contains(part));
        }
      });
    }

    test('actions: Details ▾ first, DNS settings; Network event (opening the cause) only when the cause is a network change', () {
      final calls = <String>[];
      final plain = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('vpn')], route: _route)), _ctx(calls))!;
      expect([for (final a in plain.actions) a.label], [_en.details, _en.dnsSettings]);
      expect(plain.actions.first.details, isTrue);
      plain.actions.first.onTap();
      plain.actions.last.onTap();
      expect(calls, hasLength(2));
      expect(calls.first, 'details');
      expect(calls.last, startsWith('dnsSettings:'));

      calls.clear();
      final net = dnsCard(
        _ev('dns', 'switched', _switched(sides: [_switch('vpn')], cause: {'kind': 'net', 'id': 5})),
        _ctx(calls),
      )!;
      expect([for (final a in net.actions) a.label], [_en.details, _en.dnsSettings, _en.networkEvent]);
      net.actions.last.onTap();
      expect(calls.last, 'event:5');
    });

    test('repeats of the card come from the context (a repeat of the same event)', () {
      final m = dnsCard(_ev('dns', 'switched', _switched(sides: [_switch('vpn')])), _ctx([], repeats: 3))!;
      expect(m.repeats, 3);
    });
  });

  group('dns/transport', () {
    test('title by the provider name of the side; chips are transport labels (DoT › DoH); info; cause by the transports', () {
      final m = dnsCard(
        _ev(
          'dns',
          'transport',
          {
            'sides': [_transport('vpn')],
            'same': false,
            'cause': {'kind': 'transport', 'a': 'dot', 'b': 'doh'},
          },
          level: 'info',
        ),
        _ctx([]),
      )!;
      expect(m.title, _en.changedTransport('Zeta DNS'));
      expect(m.level, CardLevel.info);

      final row = _frame(m).rows.single;
      expect(row.label, _en.vpn);
      expect(row.from.title, 'DoT');
      expect(row.to.title, 'DoH');
      expect(_causeText(m), contains(_en.doesNotAnswerOnThisRoute('DoT')));
      expect(_causeText(m), contains(_en.ofTheSameServerDoes('DoH')));
    });
  });

  group('dns/down', () {
    final oneSide = {
      'side': 'vpn',
      'servers': [
        {'provider': 'p-a', 'name': 'Zeta DNS', 'kinds': ['doh', 'dot']},
        {'provider': 'p-b', 'name': 'Quad Relay', 'kinds': ['udp']},
      ],
      'selected': 'p-a',
    };

    test('title «DNS does not answer», error; a red row per server with the kinds; stays selected; cause none is not blamed on the server', () {
      final m = dnsCard(
        _ev('dns', 'down', {
          'sides': [oneSide],
          'noSpare': false,
          'cause': {'kind': 'none'},
        }, level: 'error'),
        _ctx([]),
      )!;
      expect(m.title, _en.dnsDoesNotAnswer);
      expect(m.level, CardLevel.error);

      final rows = _box(m).rows;
      expect(rows.first, isA<CardSection>().having((s) => s.title, 'title', _en.throughVpn));
      final checks = rows.whereType<CheckRow>().toList();
      expect([for (final c in checks) c.value], ['Zeta DNS · DoH, DoT', 'Quad Relay · UDP']);
      expect([for (final c in checks) c.ok], [false, false]);
      expect([for (final c in checks) c.sub], [_en.noAnswerStaysSelected, _en.noAnswerStaysSelected]);
      expect(_causeText(m), contains(_en.causeNotEstablishedSeeTheChecks));
    });

    test('a section per side (Through VPN, Direct); with no spare DNS on the side the sub says so', () {
      final m = dnsCard(
        _ev('dns', 'down', {
          'sides': [
            oneSide,
            {
              'side': 'direct',
              'servers': [
                {'provider': 'p-c', 'name': 'Local Blue', 'kinds': ['udp']},
              ],
              'selected': 'p-c',
            },
          ],
          'noSpare': true,
          'cause': {'kind': 'none'},
        }),
        _ctx([]),
      )!;
      final rows = _box(m).rows;
      expect([for (final s in rows.whereType<CardSection>()) s.title], [_en.throughVpn, _en.direct3]);
      expect(rows.whereType<CardSection>().map((s) => s.title), isNot(contains(_en.checkedThrough)), reason: 'no nodes in the data');
      final checks = rows.whereType<CheckRow>().toList();
      expect([for (final c in checks) c.value], ['Zeta DNS · DoH, DoT', 'Quad Relay · UDP', 'Local Blue · UDP']);
      expect([for (final c in checks) c.sub], everyElement(_en.noAnswerNoSpareDnsOn));
    });

    test('with nodes: Checked through, a row per node (no answer; answers — spare node), a tap goes to the node', () {
      final calls = <String>[];
      final m = dnsCard(
        _ev('dns', 'down', {
          'sides': [oneSide],
          'noSpare': true,
          'nodes': [
            {'key': 'sub1::n1', 'sub': 'sub1', 'proto': 'vless', 'ok': false},
            {'key': 'sub1::n2', 'sub': 'sub1', 'proto': 'hysteria2', 'ok': true},
          ],
          'cause': {'kind': 'node', 'node': 'sub1::n1', 'server': 'Zeta DNS'},
        }),
        _ctx(calls),
      )!;
      final rows = _box(m).rows;
      final at = rows.indexWhere((r) => r is CardSection && r.title == _en.checkedThrough);
      expect(at, greaterThan(-1));
      final nodeRows = rows.sublist(at + 1).whereType<CheckRow>().toList();
      expect(nodeRows, hasLength(2));
      expect(nodeRows[0].value, contains('N:sub1::n1'));
      expect(nodeRows[1].value, contains('N:sub1::n2'));
      expect([for (final r in nodeRows) r.ok], [false, true]);
      expect([for (final r in nodeRows) r.sub], [_en.noAnswer, _en.answersSpareNode]);
      nodeRows.first.onGo!();
      expect(calls, ['node:sub1::n1']);
      expect(_causeText(m), contains(_en.answersThroughAnotherNode('Zeta DNS')));
    });

    test('Network event is an action only with a network cause', () {
      final net = dnsCard(
        _ev('dns', 'down', {
          'sides': [oneSide],
          'noSpare': false,
          'cause': {'kind': 'net', 'id': 4},
        }),
        _ctx([]),
      )!;
      expect([for (final a in net.actions) a.label], [_en.details, _en.dnsSettings, _en.networkEvent]);

      final none = dnsCard(
        _ev('dns', 'down', {
          'sides': [oneSide],
          'noSpare': false,
          'cause': {'kind': 'none'},
        }),
        _ctx([]),
      )!;
      expect([for (final a in none.actions) a.label], isNot(contains(_en.networkEvent)));
    });
  });

  group('dns/up', () {
    test('title «DNS answers again — after <duration>» (the app duration formatter), ok; a green row per side', () {
      final m = dnsCard(
        _ev(
          'dns',
          'up',
          {
            'afterMs': 65000,
            'sides': [
              {'side': 'vpn', 'provider': 'p-a', 'name': 'Zeta DNS', 'kind': 'doh'},
              {'side': 'direct', 'provider': 'p-c', 'name': 'Local Blue', 'kind': 'udp'},
            ],
          },
          level: 'info',
        ),
        _ctx([]),
      )!;
      expect(m.title, _en.dnsAnswersAgainAfter(EventWords(_en, FakeCoreHost().catalog).duration(65000)));
      expect(m.level, CardLevel.ok);

      final checks = _box(m).rows.whereType<CheckRow>().toList();
      expect([for (final c in checks) c.ok], [true, true]);
      expect('${checks[0].value} ${checks[0].sub}', contains('Zeta DNS'));
      expect('${checks[1].value} ${checks[1].sub}', contains('Local Blue'));
    });
  });

  group('old events without sides keep the old view (null)', () {
    test('dnsCard returns null for the old shapes', () {
      final old = <(String, Map<String, dynamic>)>[
        (
          'switched',
          {
            'reason': 'failover',
            'side': 'vpn',
            'from': {'provider': 'p-a', 'name': 'Zeta DNS', 'silent': ['doh'], 'since': _since},
            'to': {'provider': 'p-b', 'name': 'Quad Relay', 'kind': 'udp', 'ms': 40},
            'fromProvider': 'p-a',
            'toProvider': 'p-b',
            'cause': {'kind': 'none'},
          },
        ),
        ('transport', {'provider': 'p-a', 'name': 'Zeta DNS', 'from': 'dot', 'to': 'doh', 'ms': 35, 'cause': {'kind': 'none'}}),
        (
          'down',
          {
            'side': 'vpn',
            'servers': [
              {'provider': 'p-a', 'name': 'Zeta DNS', 'kinds': ['doh']},
            ],
            'selected': 'p-a',
            'noSpare': false,
            'cause': {'kind': 'none'},
          },
        ),
        ('up', {'afterMs': 1000, 'side': 'vpn', 'provider': 'p-a', 'kind': 'doh'}),
      ];
      for (final (type, data) in old) {
        expect(dnsCard(_ev('dns', type, data), _ctx([])), isNull, reason: 'dns/$type without sides');
      }
    });

    test('net/switched without data.dns adds no DNS blocks', () {
      expect(netDnsBlocks(_ev('net', 'switched', {'reason': 'x'}), _ctx([])), isEmpty);
    });
  });

  group('net/switched data.dns (the DNS blocks inside the network event)', () {
    test('the switches as one frame under «DNS switched», then one frame per transport change named by its provider', () {
      final blocks = netDnsBlocks(
        _ev('net', 'switched', {
          'dns': {
            'switches': [_switch('vpn'), _switch('direct')],
            'same': false,
            'transports': [_transport('vpn')],
          },
        }),
        _ctx([]),
      );
      expect(blocks, hasLength(2));

      final switches = blocks[0] as SwitchFrame;
      expect(switches.heading, _en.dnsSwitched);
      expect([for (final r in switches.rows) r.label], [_en.vpn, _en.direct3]);

      final transport = blocks[1] as SwitchFrame;
      expect(transport.heading, _en.changedTransport('Zeta DNS'));
      expect(transport.rows.single.from.title, 'DoT');
      expect(transport.rows.single.to.title, 'DoH');
    });

    test('the same switch on both sides: one row in two lines', () {
      final blocks = netDnsBlocks(
        _ev('net', 'switched', {
          'dns': {
            'switches': [_switch('vpn'), _switch('direct')],
            'same': true,
            'transports': [],
          },
        }),
        _ctx([]),
      );
      expect(blocks, hasLength(1));
      final switches = blocks.single as SwitchFrame;
      expect([for (final r in switches.rows) r.label], ['${_en.vpn}\n${_en.direct3}']);
    });
  });
}
