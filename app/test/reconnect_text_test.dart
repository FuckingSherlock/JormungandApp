// conn/reconnected wording (docs/logs.md «Тексты», row conn/reconnected). A reconnect for settings is the user's: its sub
// names what changed, then the user's own taps of the same operation (a pin, a system proxy switch), then the time. A
// stack of reconnect rows reads as its newest member.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

const _t0 = 1800000000000; // a fixed clock, in ms

final _en = lookupAppLocalizations(const Locale('en'));

const Map<String, dynamic> _changedMode = {
  'mode': {'from': 'tun', 'to': 'proxy'},
};

/// An event as the journal holds it (`at` is in ms, counted from [_t0] in seconds).
EventRecord _ev(
  int id,
  String cat,
  String type, {
  String level = 'info',
  bool own = false,
  int s = 0,
  Map<String, dynamic> data = const {},
}) => EventRecord.fromJson({
  'id': id,
  'at': _t0 + s * 1000,
  'cat': cat,
  'type': type,
  'level': level,
  'own': own,
  'data': data,
});

/// An event of a reconnect operation: the journal item carries `op {id, kind}`, as the core writes it.
EventRecord _op(
  int id,
  String opId,
  String cat,
  String type, {
  required int s,
  String level = 'info',
  bool own = false,
  Map<String, dynamic> data = const {},
}) => EventRecord.fromJson({
  'id': id,
  'at': _t0 + s * 1000,
  'cat': cat,
  'type': type,
  'level': level,
  'own': own,
  'data': data,
  'op': {'id': opId, 'kind': 'reconnect'},
});

/// One reconnect: the user's [taps] (cat, type, data), one per second from [s] seconds, then conn/reconnected with
/// [outcome] a second after the last tap. The first tap is the head of the row.
List<EventRecord> _reconnect(
  int n, {
  required int s,
  List<(String, String, Map<String, dynamic>)> taps = const [],
  Map<String, dynamic> outcome = const {'reason': 'settings', 'tookMs': 0},
}) {
  final op = 'op$n';
  return [
    for (var i = 0; i < taps.length; i++)
      _op(10 * n + 1 + i, op, taps[i].$1, taps[i].$2, s: s + i, own: true, data: taps[i].$3),
    _op(10 * n + 9, op, 'conn', 'reconnected', s: s + taps.length, data: outcome),
  ];
}

/// The rows as the app has them: folded, then sorted by time.
List<EventGroup> _rows(List<EventRecord> all) => [...foldEvents(all)]..sort((a, b) => a.at.compareTo(b.at));

/// The text of one operation's row: title, sub and detail.
(String, String, String) _opRow(EventWords w, List<EventRecord> events) {
  final rows = _rows(events);
  expect(rows, hasLength(1));
  return w.describeGroup(rows.single);
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  late EventWords words;
  setUp(() {
    final host = FakeCoreHost();
    host.catalog.addSource(
      Source(
        id: 'src1',
        kind: 'sub',
        name: 'Alpha',
        url: 'https://sub.example/list',
        nodes: [
          CatalogNode(id: 'n1', name: 'One', protocol: 'vless', address: 'one.example.com'),
          CatalogNode(id: 'n2', name: 'Two', protocol: 'hysteria2', address: 'two.example.com'),
        ],
      ),
    );
    words = EventWords(_en, host.catalog);
  });

  group('describe: a reconnect for settings is the user\'s, then what changed and the time', () {
    test('data.changed names the change in the sub', () {
      final d = words.describe(
        _ev(1, 'conn', 'reconnected', data: const {'reason': 'settings', 'changed': _changedMode, 'tookMs': 2000}),
      );
      expect(d.title, 'Reconnected · by you');
      expect(d.sub, 'mode: TUN → Proxy · 2 s');
    });

    test('nothing known: the sub is settings and the time', () {
      for (final data in <Map<String, dynamic>>[
        {'reason': 'settings', 'tookMs': 0},
        {'reason': 'settings', 'changed': <String, dynamic>{}, 'tookMs': 0},
      ]) {
        final d = words.describe(_ev(1, 'conn', 'reconnected', data: data));
        expect(d.title, 'Reconnected · by you', reason: '$data');
        expect(d.sub, 'settings · 0 s', reason: '$data');
      }
    });

    test('the other reasons keep their wording: lists, reresolve, and user with the downtime', () {
      for (final (reason, sub) in [('lists', 'rule lists · 3 s'), ('reresolve', 'server addresses · 3 s')]) {
        final d = words.describe(_ev(1, 'conn', 'reconnected', data: {'reason': reason, 'tookMs': 3000}));
        expect(d.title, 'Reconnected', reason: reason);
        expect(d.sub, sub, reason: reason);
      }
      final u = words.describe(_ev(1, 'conn', 'reconnected', data: const {'reason': 'user', 'downMs': 3000, 'tookMs': 6000}));
      expect(u.title, 'Reconnected · by you');
      expect(u.sub, 'VPN was off for 3 s · 6 s');
    });
  });

  group('describeGroup: the user\'s taps of the same operation are added to the sub of a settings reconnect', () {
    test('a pin to a server adds server: <name>; an unpin adds server unpinned; the time stays last', () {
      final (title, pinned, _) = _opRow(words, _reconnect(1, s: 0, taps: [
        ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n1'}),
      ]));
      expect(title, 'Reconnected · by you');
      expect(pinned, contains('server: One'));
      expect(pinned, endsWith(' · 0 s'));

      final (_, unpinned, _) = _opRow(words, _reconnect(2, s: 0, taps: [
        ('user', 'pin', {'entry': 'Germany', 'server': null}),
      ]));
      expect(unpinned, contains('server unpinned'));
      expect(unpinned, endsWith(' · 0 s'));
    });

    test('a system proxy switch adds system proxy on or off', () {
      for (final (on, text) in [(true, 'system proxy on'), (false, 'system proxy off')]) {
        final (_, sub, _) = _opRow(words, _reconnect(3, s: 0, taps: [
          ('user', 'sysProxy', {'on': on}),
        ]));
        expect(sub, contains(text), reason: '$on');
        expect(sub, endsWith(' · 0 s'), reason: '$on');
      }
    });

    test('several taps of one kind: only the last one is in the sub', () {
      final (_, twice, _) = _opRow(words, _reconnect(4, s: 0, taps: [
        ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n1'}),
        ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n2'}),
      ]));
      expect(twice, contains('server: Two'));
      expect(twice, isNot(contains('One')));

      final (_, unpinAfter, _) = _opRow(words, _reconnect(5, s: 0, taps: [
        ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n1'}),
        ('user', 'pin', {'entry': 'Germany', 'server': null}),
      ]));
      expect(unpinAfter, contains('server unpinned'));
      expect(unpinAfter, isNot(contains('One')));
    });

    test('order: what changed, then the pin, then the system proxy, then the time', () {
      final (_, sub, _) = _opRow(words, _reconnect(6, s: 0, taps: [
        ('user', 'sysProxy', {'on': true}),
        ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n1'}),
      ], outcome: const {'reason': 'settings', 'changed': _changedMode, 'tookMs': 0}));
      final changed = sub.indexOf('mode: TUN → Proxy');
      final pin = sub.indexOf('server: One');
      final sys = sub.indexOf('system proxy on');
      expect(changed, greaterThanOrEqualTo(0), reason: sub);
      expect(pin, greaterThan(changed), reason: sub);
      expect(sys, greaterThan(pin), reason: sub);
      expect(sub, endsWith(' · 0 s'));
    });

    test('a mode or route tap adds nothing: data.changed already names it', () {
      const outcome = {'reason': 'settings', 'changed': _changedMode, 'tookMs': 0};
      final (_, plain, _) = _opRow(words, _reconnect(7, s: 0, taps: [
        ('user', 'mode', {'value': 'proxy'}),
      ], outcome: outcome));
      final (_, withTaps, _) = _opRow(words, _reconnect(8, s: 0, taps: [
        ('user', 'mode', {'value': 'proxy'}),
        ('user', 'route', {'value': 'direct'}),
      ], outcome: outcome));
      expect(plain, 'mode: TUN → Proxy · 0 s');
      expect(withTaps, plain);
    });

    test('a reconnect for another reason adds none of the taps', () {
      final (_, sub, _) = _opRow(words, _reconnect(9, s: 0, taps: [
        ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n1'}),
      ], outcome: const {'reason': 'lists', 'tookMs': 0}));
      expect(sub, 'rule lists · 0 s');
    });
  });

  group('a stack of reconnect rows is worded by its newest member', () {
    test('describeGroup of the stack is describeGroup of its newest member', () {
      final rows = _rows([
        ..._reconnect(1, s: 0, taps: [
          ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n1'}),
        ]),
        ..._reconnect(2, s: 120, taps: [
          ('user', 'mode', {'value': 'proxy'}),
        ]),
        ..._reconnect(3, s: 240, taps: [
          ('user', 'pin', {'entry': 'Germany', 'server': 'src1::n2'}),
        ]),
      ]);
      final out = stackReconnects(rows);
      expect(out, hasLength(1));
      final stack = out.single;
      expect(stack.stack, hasLength(3));

      final (title, sub, _) = words.describeGroup(stack);
      expect(title, 'Reconnected · by you');
      expect(sub, contains('server: Two'));
      expect(words.describeGroup(stack), words.describeGroup(stack.stack.last));
    });
  });
}
