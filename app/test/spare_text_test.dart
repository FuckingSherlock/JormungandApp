// English texts of the spare-entry events and of the app-ended disconnect (docs/logs.md → «Тексты», «Задетые настройки»):
// `auto/unstable {spare: true}`, a `sub/updated` whose every affected entry is spare, `conn/disconnected {by: app}`,
// `conn/vpnUp {by: app}` (the same words as by the user).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

EventRecord _ev(int id, String cat, String type, {String level = 'info', int? opens, Map<String, dynamic> data = const {}}) =>
    EventRecord.fromJson({
      'id': id,
      'at': 1800000000000,
      'cat': cat,
      'type': type,
      'level': level,
      'own': false,
      'data': data,
      'opens': ?opens,
    });

String _line(EventWords w, EventRecord e) {
  final d = w.describe(e);
  return [d.title, d.sub, d.detail].map((s) => s.replaceFirst(RegExp(r'^\s*·\s*'), '').trim()).where((s) => s.isNotEmpty).join(' · ');
}

void main() {
  final w = EventWords(lookupAppLocalizations(const Locale('en')), FakeCoreHost().catalog);
  setUpAll(() => initializeDateFormatting('en'));

  group('auto/unstable', () {
    test('a spare entry says so in the title; the current route keeps the old wording', () {
      final spare = w.describe(_ev(1, 'auto', 'unstable', data: const {'id': 'e0', 'strikes': 3, 'holdMs': 60000, 'spare': true}));
      expect(spare.title, startsWith('Spare entry '));
      expect(spare.title, contains(' is unstable'));
      final plain = w.describe(_ev(2, 'auto', 'unstable', data: const {'id': 'e0', 'strikes': 3, 'holdMs': 60000}));
      expect(plain.title, isNot(startsWith('Spare entry')));
      expect(plain.title, contains('is unstable'));
    });
  });

  group('sub/updated whose every affected entry is spare', () {
    Map<String, dynamic> data(List<Map<String, dynamic>> affected) => {
          'source': 's1',
          'name': 'Foo',
          'added': 0,
          'removed': 2,
          'total': 8,
          'lost': ['a.example', 'b.example'],
          'lostCount': 2,
          'affected': affected,
        };

    test('title names the spare entries, the body says Auto skips them', () {
      final d = w.describe(_ev(1, 'sub', 'updated', data: data([
        {'kind': 'chain', 'id': 'c1', 'name': 'Chain One', 'to': 'main', 'spare': true},
        {'kind': 'profile', 'id': 'p', 'name': 'Prof', 'to': 'main', 'spare': true},
      ])));
      expect(d.title, startsWith('Subscription Foo removed '));
      expect(d.title, matches(RegExp(r'removed 2 servers? used by spare Chain One, Prof')));
      expect(d.detail, contains('Auto skips them until the provider returns the servers.'));
    });

    test('one entry that is not spare (or no flag at all) keeps the warn wording', () {
      for (final affected in [
        [
          {'kind': 'chain', 'id': 'c1', 'name': 'Chain One', 'to': 'main', 'spare': true},
          {'kind': 'rule', 'id': 'r1', 'name': 'Rule 1', 'to': 'block'},
        ],
        [
          {'kind': 'rule', 'id': 'r1', 'name': 'Rule 1', 'to': 'block'},
        ],
      ]) {
        final t = _line(w, _ev(1, 'sub', 'updated', level: 'warn', data: data(affected)));
        expect(t, contains('Subscription Foo removed servers in use:'));
        expect(t, isNot(contains('Auto skips them')));
      }
    });
  });

  group('the app was closed', () {
    test('conn/disconnected by app', () {
      expect(_line(w, _ev(1, 'conn', 'disconnected', data: const {'by': 'app', 'reason': 'ended', 'found': 1})),
          'VPN disconnected · the app was closed');
    });

    test('conn/vpnUp by app reads like by the user or the system', () {
      String up(String by) => _line(w, _ev(2, 'conn', 'vpnUp', opens: 1, data: {'downMs': 185000, 'causes': ['core'], 'by': by}));
      expect(up('app'), up('user'));
      expect(up('app'), startsWith('VPN outage ended · VPN disconnected'));
    });
  });
}
