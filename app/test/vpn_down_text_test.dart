// «VPN не работает» in words (docs/logs.md «Тексты», «„VPN не работает“»): conn/vpnDown reads «VPN is down» and gives
// the reason by its causes (core, network, or both joined by « · »); the proxy suffix shows only when the system proxy
// was kept; conn/vpnUp closes with «VPN works again · down N». A crash merged into vpnDown by `joins` makes one row,
// titled and closed by vpnDown / vpnUp. The texts of the old types (core/down, conn/offline, conn/online) stay.
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
  final (title, detail) = w.describeGroup(g);
  return [title, detail, w.reasonLine(g) ?? ''].join('\n');
}

/// The title and detail of an event's own row, as one line.
String _own(EventWords w, EventRecord e) {
  final d = w.describe(e);
  return '${d.title} ${d.detail}';
}

/// The row of one vpnDown with the given [causes] (and [data] for the rest), on its own.
String _downText(EventWords w, List<String> causes, {Map<String, dynamic> data = const {}}) =>
    _shown(w, foldEvents([_ev(1, 'conn', 'vpnDown', data: {'causes': causes, ...data})]).single);

void main() {
  final words = _words();

  group('conn/vpnDown reads «VPN is down»', () {
    test('the title is VPN is down, whatever the causes', () {
      for (final causes in [
        ['core'],
        ['network'],
        ['core', 'network'],
      ]) {
        expect(words.describe(_ev(1, 'conn', 'vpnDown', data: {'causes': causes})).title, 'VPN is down', reason: '$causes');
      }
    });

    test('cause core: sing-box stopped and does not start, and no internet text', () {
      final s = _downText(words, ['core']);
      expect(s, contains('sing-box stopped and does not start'));
      expect(s, isNot(contains('No internet connection')));
    });

    test('cause network: no internet connection, and no sing-box text', () {
      final s = _downText(words, ['network']);
      expect(s, contains('No internet connection'));
      expect(s, isNot(contains('sing-box')));
    });

    test('both causes: the core text, then the network text, joined by « · »', () {
      final s = _downText(words, ['core', 'network']);
      expect(s, matches(RegExp(r'sing-box stopped and does not start[^\n]* · No internet connection')));
    });

    test('the attempts are the restarts merged into the row: two failed restarts read (2 attempts)', () {
      final rows = foldEvents(_crashChain(restarts: 2, closed: false));
      expect(_shown(words, rows.single), contains('sing-box stopped and does not start (2 attempts)'));
    });

    test('without merged restarts the core text has no number of attempts', () {
      final s = _downText(words, ['core']);
      expect(s, contains('sing-box stopped and does not start'));
      expect(s, isNot(matches(RegExp(r'\d+ attempts'))));
    });

    test('proxy kept adds the suffix; removed or released do not', () {
      final kept = _downText(words, ['core'], data: {'proxy': 'kept'});
      expect(kept, contains('system proxy left on, programs have no internet'));
      for (final proxy in ['removed', 'released']) {
        expect(_downText(words, ['core'], data: {'proxy': proxy}), isNot(contains('system proxy left on')), reason: proxy);
      }
    });
  });

  group('conn/vpnUp closes it', () {
    test('the text is VPN works again · down N, N from downMs', () {
      final text = _own(words, _ev(2, 'conn', 'vpnUp', level: 'info', data: const {'downMs': 185000, 'causes': ['core']}, opens: 1));
      expect(text, contains('VPN works again · down '));
      expect(text, contains(words.duration(185000)));
    });
  });

  group('a crash merged into vpnDown is one row', () {
    test('it is titled VPN is down and closed by vpnUp: the status is Finished at …', () {
      final rows = foldEvents(_crashChain());
      expect(rows, hasLength(1), reason: 'the crash and its restarts are steps of the vpnDown row');
      final g = rows.single;
      final (title, _) = words.describeGroup(g);
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
