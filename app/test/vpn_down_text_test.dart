// «VPN не работает» in words (docs/logs.md «Тексты», «„VPN не работает“»): conn/vpnDown reads «VPN is down» and gives
// the reason by its causes (core, network, or both joined by « · »; the network alone is «Waiting for network»); the
// proxy suffix shows only when the system proxy was kept; conn/vpnUp is its own row, «VPN works again · …» by the
// causes. A crash merged into vpnDown by `joins` is one row titled by vpnDown. The texts of the old types
// (core/down, conn/offline, conn/online) stay.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

const _t0 = 1800000000000; // a fixed clock: the journal times are counted from here, in seconds

/// An event as the journal holds it; the fields Sentinel and the core set on it are passed when given.
EventRecord _ev(
  int id,
  String cat,
  String type, {
  String level = 'error',
  int s = 0,
  Map<String, dynamic> data = const {},
  int? cause,
  int? opens,
  List<int>? joins,
  String? verdict,
}) => EventRecord.fromJson({
  'id': id,
  'at': _t0 + s * 1000,
  'cat': cat,
  'type': type,
  'level': level,
  'own': false,
  'data': data,
  'cause': ?cause,
  'opens': ?opens,
  'joins': ?joins,
  'verdict': ?verdict,
});

/// A crash that did not come back in 30 s: the crash, its failed restarts (consequences), the vpnDown that joins the
/// crash, and the vpnUp that closes the vpnDown when [closed].
List<EventRecord> _crashChain({int restarts = 2, bool closed = true}) => [
  _ev(1, 'core', 'crashed', data: const {'code': 2}),
  for (var n = 1; n <= restarts; n++)
    _ev(1 + n, 'core', 'restartFailed', s: 5 * n, data: {'attempt': n, 'error': 'boom'}, cause: 1, verdict: 'consequence'),
  _ev(50, 'conn', 'vpnDown', s: 30, data: const {'causes': ['core'], 'proxy': 'kept'}, joins: const [1]),
  if (closed) _ev(51, 'conn', 'vpnUp', level: 'info', s: 120, data: const {'downMs': 120000, 'causes': ['core']}, opens: 50),
];

EventWords _words() => EventWords(lookupAppLocalizations(const Locale('en')), FakeCoreHost().catalog);

/// The whole text a folded row shows: its title and detail, and the reason line when the detail does not say it.
String _shown(EventWords w, EventGroup g) {
  final (title, sub, detail) = w.describeGroup(g);
  return [title, sub, detail, w.reasonLine(g) ?? ''].join('\n');
}

/// The title and detail of an event's own row, as one line.
String _own(EventWords w, EventRecord e) {
  final d = w.describe(e);
  return [d.title, d.sub, d.detail].where((s) => s.isNotEmpty).join(' · ');
}

/// The row of one vpnDown with the given [causes] (and [data] for the rest), on its own.
String _downText(EventWords w, List<String> causes, {Map<String, dynamic> data = const {}}) =>
    _shown(w, foldEvents([_ev(1, 'conn', 'vpnDown', data: {'causes': causes, ...data})]).single);

void main() {
  final words = _words();

  group('conn/vpnDown reads «VPN is down»', () {
    test('the title is VPN is down while the core is a cause; the network alone is «Waiting for network»', () {
      for (final causes in [
        ['core'],
        ['core', 'network'],
      ]) {
        expect(words.describe(_ev(1, 'conn', 'vpnDown', data: {'causes': causes})).title, 'VPN is down', reason: '$causes');
      }
      final waiting = words.describe(_ev(1, 'conn', 'vpnDown', level: 'warn', data: const {'causes': ['network']}));
      expect(waiting.title, 'Waiting for network');
      expect(waiting.sub, 'VPN is on, no internet connection');
    });

    test('cause core: sing-box stopped and has not restarted, and no internet text', () {
      final s = _downText(words, ['core']);
      expect(s, contains('sing-box stopped and has not restarted for 30 s'));
      expect(s, isNot(contains('No internet connection')));
    });

    test('cause network alone: the waiting row, no sing-box text', () {
      final s = _downText(words, ['network']);
      expect(s, contains('Waiting for network\nVPN is on, no internet connection'));
      expect(s, isNot(contains('sing-box')));
    });

    test('both causes: the core text, then the network text, joined by « · »', () {
      final s = _downText(words, ['core', 'network']);
      expect(s, matches(RegExp(r'sing-box stopped and has not restarted for 30 s[^\n]* · No internet connection')));
    });

    test('the attempts are the restarts merged into the row: two failed restarts read (2 restart attempts so far)', () {
      final rows = foldEvents(_crashChain(restarts: 2, closed: false));
      expect(
        _shown(words, rows.single),
        contains('sing-box stopped and has not restarted for 30 s (2 restart attempts so far)'),
      );
    });

    test('without merged restarts the core text has no number of attempts', () {
      final s = _downText(words, ['core']);
      expect(s, contains('sing-box stopped and has not restarted for 30 s'));
      expect(s, isNot(matches(RegExp(r'\d+ restart attempts'))));
    });

    test('proxy kept adds the suffix; removed or released do not', () {
      final kept = _downText(words, ['core'], data: {'proxy': 'kept'});
      expect(kept, contains('system proxy is still set, so programs that use it have no internet'));
      for (final proxy in ['removed', 'released']) {
        expect(_downText(words, ['core'], data: {'proxy': proxy}), isNot(contains('system proxy is still set')), reason: proxy);
      }
    });
  });

  group('conn/vpnUp closes it', () {
    test('the text is by what the outage had (causes); the duration is the closed pair line', () {
      String text(List<String> causes, {String? by}) =>
          _own(words, _ev(2, 'conn', 'vpnUp', level: 'info', data: {'downMs': 185000, 'causes': causes, 'by': ?by}, opens: 1)).trim();
      expect(text(['core']), 'VPN works again · sing-box is running');
      expect(text(['network']), 'VPN works again · internet is available');
      expect(text(['core', 'network']), 'VPN works again · sing-box is running, internet is available');
      expect(text(['core'], by: 'user'), 'VPN outage ended · VPN disconnected');
      expect(text(['core'], by: 'system'), 'VPN outage ended · VPN disconnected');
    });
  });

  group('a crash merged into vpnDown is one row', () {
    test('it is titled VPN is down; its closing vpnUp is its own row, the opener says Finished at …', () {
      final rows = foldEvents(_crashChain());
      expect(rows, hasLength(2), reason: 'the crash and its restarts are steps of the vpnDown row; vpnUp is a row of its own');
      final g = rows.first;
      expect(g.ev.key, 'conn/vpnDown');
      expect(g.closedById, 51);
      expect(rows.last.ev.key, 'conn/vpnUp');
      expect(rows.last.opensId, 50);
      final (title, _, _) = words.describeGroup(g);
      expect(title, 'VPN is down');
      expect(words.closedLine(g), matches(RegExp(r'^Finished at \d\d:\d\d · lasted .+')));
    });

    test('while nothing closes it, the row has no closed status and still reads VPN is down', () {
      final g = foldEvents(_crashChain(closed: false)).single;
      expect(words.describeGroup(g).$1, 'VPN is down');
      expect(words.closedLine(g), isNull);
    });
  });

  group('old types keep their texts for old journals', () {
    test('core/down, conn/offline and conn/online still read as words', () {
      for (final (cat, type) in [('core', 'down'), ('conn', 'offline'), ('conn', 'online')]) {
        final t = words.describe(_ev(1, cat, type, data: const {'proxy': 'kept', 'source': 'probes', 'downMs': 4000}));
        expect(t.title, isNotEmpty, reason: '$cat/$type');
        expect(t.title, isNot('$cat / $type'), reason: '$cat/$type');
      }
    });
  });

  test('typeLabel of vpnDown and vpnUp is a word, not the raw type', () {
    for (final type in ['vpnDown', 'vpnUp']) {
      final label = words.typeLabel('conn', type);
      expect(label, isNotEmpty, reason: type);
      expect(label, isNot(contains(type)), reason: type);
    }
  });
}
