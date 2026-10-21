// Quick start on the last server, in the app's event rows (docs/core.md «Быстрый старт на последнем сервере», docs/logs.md
// `conn/connected` → `quick`): when the check after the start switched a group, the event's own row of conn/connected
// (and of conn/reconnected by the user, which takes the same field) gets the line «Started on X — failed the check,
// switched to Y» (noAnswer) or «Started on X — a higher server is back, switched to Y» (higherBack, Priority). A check
// that kept the server («same») or whose result was dropped because Auto had already moved the group («dropped») adds
// no line, and an event without `quick` has none. The same event id updated in place (the field is written into it
// after the check) shows the line from then on. Texts are compared as one line: title, sub and detail joined with « · ».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

const _t0 = 1800000000000; // a fixed clock: the journal times are counted from here, in seconds

/// An event as the journal holds it.
EventRecord _ev(
  int id,
  String cat,
  String type, {
  String level = 'info',
  bool own = true,
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

/// The data of a connection on the subscription «Alpha» (servers «One» = sub1::n1 and «Two» = sub1::n2), with the
/// quick-start field [quick] when given.
Map<String, dynamic> _connected({Map<String, dynamic>? quick}) => {
  'entry': 'sub1',
  'server': 'sub1::n1',
  'mode': 'tun',
  'route': 'rules',
  'quick': ?quick,
};

/// The quick-start field with one group: [result] is `switched` (to sub1::n2, because of [why]), `same` or `dropped`.
Map<String, dynamic> _quick(String result, {String why = 'noAnswer'}) => {
  'groups': [
    {
      'group': 'Proxy',
      'started': 'sub1::n1',
      'result': result,
      if (result == 'switched') 'to': 'sub1::n2',
      if (result == 'switched') 'why': why,
    },
  ],
  'tookMs': 1400,
};

EventWords _words() {
  final host = FakeCoreHost();
  host.catalog.addSource(
    Source(
      id: 'sub1',
      kind: 'sub',
      name: 'Alpha',
      url: 'https://sub.example/list',
      nodes: [
        CatalogNode(id: 'n1', name: 'One', protocol: 'vless', address: 'one.example.com'),
        CatalogNode(id: 'n2', name: 'Two', protocol: 'hysteria2', address: 'two.example.com'),
      ],
    ),
  );
  return EventWords(lookupAppLocalizations(const Locale('en')), host.catalog);
}

/// The whole text of one event's own row: title, sub and detail joined as one line with « · ».
String _line(EventWords w, EventRecord e) {
  final d = w.describe(e);
  return [d.title, d.sub, d.detail]
      .map((s) => s.replaceFirst(RegExp(r'^\s*·\s*'), '').trim())
      .where((s) => s.isNotEmpty)
      .join(' · ');
}

/// The switch sentence of a quick start: «phrase, switched to Two» (the first letter may be capitalised at the start
/// of a row; the name of the started server, «Started on One — …», is checked where the spec gives it).
RegExp _switchLine(String phrase) => RegExp('$phrase, switched to Two\\b', caseSensitive: false);

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  final words = _words();

  group('a switched group adds its line to conn/connected', () {
    test('noAnswer: «Started on One — failed the check, switched to Two»', () {
      final e = _ev(1, 'conn', 'connected', data: _connected(quick: _quick('switched')));
      expect(_line(words, e), matches(RegExp('Started on One\\b[^—]*— failed the check, switched to Two\\b')));
    });

    test('higherBack (Priority): «a higher server is back, switched to Two»', () {
      final e = _ev(1, 'conn', 'connected', data: _connected(quick: _quick('switched', why: 'higherBack')));
      expect(_line(words, e), matches(_switchLine('a higher server is back')));
    });

    test('conn/reconnected by the user takes the same line', () {
      final e = _ev(
        2,
        'conn',
        'reconnected',
        data: {..._connected(quick: _quick('switched')), 'reason': 'user', 'tookMs': 900},
      );
      expect(_line(words, e), matches(_switchLine('failed the check')));
    });

    test('the same event id updated in place shows the line only once the field is written into it', () {
      final before = _ev(3, 'conn', 'connected', data: _connected());
      final after = _ev(3, 'conn', 'connected', data: _connected(quick: _quick('switched')));
      expect(_line(words, before), isNot(contains('Started on')));
      expect(_line(words, after), matches(_switchLine('failed the check')));
    });
  });

  group('no line when the check changed nothing', () {
    for (final result in const ['same', 'dropped']) {
      test('result $result adds no line', () {
        final e = _ev(4, 'conn', 'connected', data: _connected(quick: _quick(result)));
        final text = _line(words, e);
        expect(text, isNot(contains('Started on')));
        expect(text, isNot(contains('switched to')));
      });
    }

    test('an event without the quick-start field has no line', () {
      final e = _ev(5, 'conn', 'connected', data: _connected());
      expect(_line(words, e), isNot(contains('Started on')));
    });
  });
}
