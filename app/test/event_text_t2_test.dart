// English texts of events-t2 (docs/logs.md «Тексты», «Задетые настройки»; the English wording is the table of
// .claude_states/wording_audit.md with its top decisions, and where docs/logs.md differs, docs/logs.md wins):
// conn/disconnected by you / by the system / by an error, conn/vpnDown waiting or down, conn/vpnUp closing by causes
// or by you / the system, conn/reconnected, sub/updated (info and the warn variation), sub/back, node/lost, node/back,
// the type labels, the affected-setting labels and the new l10n keys. Texts are compared as one line: title and
// detail joined with « · ».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
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
  bool own = false,
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
  'own': own,
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

/// Title and detail joined as one line with « · » between them (a detail that starts with « · » does not double it).
String _joinParts(String title, String sub, String detail) => [title, sub, detail]
    .map((s) => s.replaceFirst(RegExp(r'^\s*·\s*'), '').trim())
    .where((s) => s.isNotEmpty)
    .join(' · ');

/// The whole text of one event's own row.
String _own(EventWords w, EventRecord e) {
  final d = w.describe(e);
  return _joinParts(d.title, d.sub, d.detail);
}

/// The whole text of a folded row: its title, detail and the reason line.
String _row(EventWords w, EventGroup g) {
  final (title, sub, detail) = w.describeGroup(g);
  return [_joinParts(title, sub, detail), w.reasonLine(g) ?? ''].where((s) => s.isNotEmpty).join(' · ');
}

/// [t] is [text] on its own, or [text] followed by a « · » part (a duration, when the text carries one).
void _expectPhrase(String t, String text, {String? reason}) =>
    expect(t == text || t.startsWith('$text · '), isTrue, reason: '${reason ?? ''} got "$t"');

void main() {
  final words = _words();

  setUpAll(() => initializeDateFormatting('en'));

  group('conn/disconnected: one event, who turned the VPN off is in the title', () {
    test('by you, and by the system or another app', () {
      expect(
        _own(words, _ev(1, 'conn', 'disconnected', level: 'info', own: true, data: const {'by': 'user'})),
        'VPN disconnected · by you',
      );
      expect(
        _own(words, _ev(1, 'conn', 'disconnected', data: const {'by': 'system', 'reason': 'revoked'})),
        'VPN disconnected · by the system or another app',
      );
    });

    test('by error: sing-box did not start after N attempts, with the plural', () {
      for (final (n, word) in [(1, 'attempt'), (3, 'attempts')]) {
        final t = _own(words, _ev(1, 'conn', 'disconnected', data: {'by': 'error', 'reason': 'down', 'attempts': n}));
        expect(t, 'VPN disconnected · error: sing-box did not start after $n $word', reason: '$n');
      }
    });

    test('by error: a server that went away names the server when its name is known', () {
      final gone = _own(words, _ev(1, 'conn', 'disconnected', data: const {'by': 'error', 'reason': 'pinLost'}));
      expect(gone, startsWith('VPN disconnected · error: server '));
      expect(gone, contains('is unavailable'));
      expect(gone, isNot(contains('  ')), reason: 'no name, no double space');
      final named = _own(
        words,
        _ev(1, 'conn', 'disconnected', data: const {'by': 'error', 'reason': 'pinLost', 'pick': 'a.example', 'why': 'deleted'}),
      );
      expect(named, contains('a.example'));
      expect(named, contains('is unavailable'));
    });

    test('by error: an unknown reason, and no reason at all', () {
      expect(
        _own(words, _ev(1, 'conn', 'disconnected', data: const {'by': 'error', 'reason': 'boom'})),
        'VPN disconnected · after an error: boom',
      );
      expect(
        _own(words, _ev(1, 'conn', 'disconnected', data: const {'by': 'error'})),
        'VPN disconnected · after an error',
      );
    });

    test('the expanded fields have no By row, whoever disconnected', () {
      for (final data in [
        {'by': 'user'},
        {'by': 'system', 'reason': 'revoked'},
        {'by': 'error', 'reason': 'down', 'attempts': 2},
      ]) {
        final f = words.fields(EventGroup(_ev(1, 'conn', 'disconnected', data: data)));
        expect(f.any((x) => x.$1.toLowerCase().contains(RegExp(r'\bby\b'))), isFalse, reason: '$data');
      }
    });
  });

  group('conn/vpnDown: waiting for network is not down', () {
    test('causes exactly network: Waiting for network · VPN is on, no internet connection', () {
      final t = _own(words, _ev(1, 'conn', 'vpnDown', level: 'warn', data: const {'causes': ['network']}));
      expect(t, 'Waiting for network · VPN is on, no internet connection');
      expect(t, isNot(contains('VPN is down')));
    });

    test('core alone: VPN is down, sing-box has not restarted for 30 s, no internet line', () {
      final core = _own(words, _ev(1, 'conn', 'vpnDown', data: const {'causes': ['core']}));
      expect(core, startsWith('VPN is down · sing-box stopped and has not restarted for 30 s'));
      expect(core, isNot(contains('Waiting for network')));
      expect(core, isNot(contains('internet')));
    });

    test('core and network: VPN is down; the core line first, the no-internet line after « · »', () {
      final both = _own(words, _ev(1, 'conn', 'vpnDown', data: const {'causes': ['core', 'network']}));
      expect(both, startsWith('VPN is down · sing-box stopped'));
      expect(both, matches(RegExp(r'30 s[^·]* · no internet connection', caseSensitive: false)));
    });

    test('the merged restarts count: (N restart attempts so far)', () {
      final g = foldEvents(_crashChain(restarts: 2, closed: false)).single;
      expect(_row(words, g), contains('sing-box stopped and has not restarted for 30 s (2 restart attempts so far)'));
    });

    test('proxy kept adds the system-proxy line; removed or released do not', () {
      expect(
        _own(words, _ev(1, 'conn', 'vpnDown', data: const {'causes': ['core'], 'proxy': 'kept'})),
        contains('system proxy is still set, so programs that use it have no internet'),
      );
      for (final proxy in ['removed', 'released']) {
        final t = _own(words, _ev(1, 'conn', 'vpnDown', data: {'causes': ['core'], 'proxy': proxy}));
        expect(t, isNot(contains('system proxy')), reason: proxy);
      }
    });
  });

  group('conn/vpnUp closes the outage: by you or the system, or by the causes that cleared', () {
    test('closed by you or the system: VPN outage ended · VPN disconnected, never works again', () {
      for (final by in ['user', 'system']) {
        final t = _own(
          words,
          _ev(2, 'conn', 'vpnUp', level: 'info', opens: 1, data: {'downMs': 185000, 'causes': ['core'], 'by': by}),
        );
        _expectPhrase(t, 'VPN outage ended · VPN disconnected', reason: by);
        expect(t, isNot(contains('works again')), reason: by);
      }
    });

    test('closed by causes: sing-box, internet, or both; no « outage ended » wording', () {
      for (final (causes, text) in [
        (['core'], 'VPN works again · sing-box is running'),
        (['network'], 'VPN works again · internet is available'),
        (['core', 'network'], 'VPN works again · sing-box is running, internet is available'),
      ]) {
        final t = _own(words, _ev(2, 'conn', 'vpnUp', level: 'info', opens: 1, data: {'downMs': 185000, 'causes': causes}));
        _expectPhrase(t, text, reason: '$causes');
        expect(t, isNot(contains('Outage ended')), reason: '$causes');
      }
    });
  });

  group('conn/reconnected reads Reconnected · <short reason>, the seconds at the end', () {
    test('lists, reresolve and user', () {
      for (final (reason, text) in [
        ('lists', 'Reconnected · rule lists'),
        ('reresolve', 'Reconnected · server addresses'),
        ('user', 'Reconnected · by you · VPN was off for'),
      ]) {
        final t = _own(words, _ev(1, 'conn', 'reconnected', level: 'info', data: {'reason': reason, 'tookMs': 3000}));
        expect(t, startsWith(text), reason: reason);
        expect(t, endsWith('3 s'), reason: reason);
      }
    });

    test('settings is the user\'s: Reconnected · by you, then what changed and the time', () {
      final t = _own(
        words,
        _ev(
          1,
          'conn',
          'reconnected',
          level: 'info',
          data: const {
            'reason': 'settings',
            'changed': {
              'mode': {'from': 'tun', 'to': 'proxy'},
            },
            'tookMs': 3000,
          },
        ),
      );
      expect(t, 'Reconnected · by you · mode: TUN → Proxy · 3 s');
    });
  });

  group('sub/updated: info says what changed; the warn variation names the servers in use that went away', () {
    test('info: Subscription <name> updated: +N −M', () {
      final t = _own(
        words,
        _ev(1, 'sub', 'updated', level: 'info', data: const {'source': 's1', 'name': 'Foo', 'added': 2, 'removed': 1, 'total': 10}),
      );
      expect(t, startsWith('Subscription Foo updated'));
      expect(t, matches(RegExp(r'\+2\s*[−-]\s*1')));
      expect(t, isNot(contains('in use')));
    });

    test('warn: Subscription <name> removed servers in use: <names>, with the If unavailable detail', () {
      final t = _own(
        words,
        _ev(1, 'sub', 'updated', level: 'warn', data: const {
          'source': 's1',
          'name': 'Foo',
          'added': 0,
          'removed': 2,
          'total': 8,
          'lost': ['a.example', 'b.example'],
          'lostCount': 2,
          'affected': [
            {'kind': 'rule', 'id': 'r1', 'name': 'Rule 1', 'to': 'block'},
          ],
        }),
      );
      expect(t, contains('Subscription Foo removed servers in use:'));
      expect(t, contains('a.example'));
      expect(t, contains('b.example'));
      expect(
        t,
        contains(
          'Their traffic uses If unavailable for now and goes back by itself if the provider returns the servers. '
          'Keep it as is, or choose a new target.',
        ),
      );
    });
  });

  test('sub/back: Subscription <name> returned servers in use, and the traffic goes through them again', () {
    final t = _own(
      words,
      _ev(2, 'sub', 'back', level: 'info', opens: 1, data: {
        'source': 's1',
        'name': 'Foo',
        'count': 2,
        'names': ['a.example', 'b.example'],
        'affected': [
          {'kind': 'connection', 'id': 'c', 'name': 'Connection', 'to': 'main'},
          {'kind': 'rule', 'id': 'r1', 'name': 'Rule 1', 'to': 'direct'},
          {'kind': 'rule', 'id': 'r2', 'name': 'Rule 2', 'to': 'direct'},
        ],
      }),
    );
    expect(t, contains('Subscription Foo returned servers in use:'));
    expect(t, contains('a.example'));
    expect(t, contains('b.example'));
    expect(t, contains('goes through them again'));
    expect(t, contains('the connection'));
    expect(t, contains('2 rules'));
  });

  group('node/lost and node/back: servers in use switched off, deleted, or switched on again', () {
    final affected = [
      {'kind': 'connection', 'id': 'c', 'name': 'Connection', 'to': 'block'},
    ];

    test('off: You switched off servers in use, If unavailable until you switch them on', () {
      final t = _own(
        words,
        _ev(1, 'node', 'lost', level: 'warn', own: true, data: {
          'action': 'off',
          'source': 's1',
          'name': 'Foo',
          'nodes': ['a.example'],
          'nodeCount': 1,
          'affected': affected,
        }),
      );
      expect(t, contains('You switched off servers in use: a.example'));
      expect(t, contains('Their traffic uses If unavailable until you switch them on.'));
    });

    test('deleted: You deleted servers in use, If unavailable', () {
      final t = _own(
        words,
        _ev(1, 'node', 'lost', level: 'warn', own: true, data: {
          'action': 'deleted',
          'source': 's1',
          'name': 'Foo',
          'nodes': ['a.example'],
          'nodeCount': 1,
          'affected': affected,
        }),
      );
      expect(t, contains('You deleted servers in use: a.example'));
      expect(t, contains('Their traffic uses If unavailable.'));
    });

    test('back: You switched on servers in use, and the traffic goes through them again', () {
      final t = _own(
        words,
        _ev(2, 'node', 'back', level: 'info', opens: 1, data: {
          'source': 's1',
          'name': 'Foo',
          'nodes': ['a.example'],
          'affected': affected,
        }),
      );
      expect(t, contains('You switched on servers in use: a.example'));
      expect(t, contains('goes through them again'));
    });
  });

  test('type labels of the changed events', () {
    for (final (cat, type, label) in [
      ('conn', 'vpnUp', 'VPN outage ended'),
      ('sub', 'updated', 'Subscription updated'),
      ('sub', 'failed', 'Subscription update failed'),
      ('sub', 'removed', 'Provider removed servers'),
      ('sub', 'back', 'Servers returned to the subscription'),
      ('node', 'lost', 'Servers in use switched off or deleted'),
      ('node', 'back', 'Servers in use switched on'),
      ('auto', 'fastest', 'Auto changed server (Fastest)'),
      ('core', 'restartFailed', 'sing-box restart failed'),
    ]) {
      expect(words.typeLabel(cat, type), label, reason: '$cat/$type');
    }
  });

  test('affectedKindLabel: one word per kind', () {
    for (final (kind, label) in [
      ('connection', 'Connection'),
      ('rule', 'Rule'),
      ('app', 'App'),
      ('chain', 'Chain'),
      ('profile', 'Profile'),
    ]) {
      expect(words.affectedKindLabel(kind), label, reason: kind);
    }
  });

  test('affectedToLabel: none reads not working; block, direct and main are three words, not the codes', () {
    expect(words.affectedToLabel({'to': 'none'}), 'not working');
    final labels = {for (final to in ['block', 'direct', 'main']) to: words.affectedToLabel({'to': to})};
    for (final MapEntry(key: to, value: label) in labels.entries) {
      expect(label, isNotEmpty, reason: to);
      expect(label, isNot(to), reason: to);
      expect(label, isNot('not working'), reason: to);
    }
    expect(labels.values.toSet(), hasLength(3), reason: '$labels');
  });

  test('the new l10n keys read as the plan says', () {
    final l = lookupAppLocalizations(const Locale('en'));
    expect(l.chooseForAll, 'Choose for all');
    expect(l.switchOn, 'Switch on');
    expect(l.openSubscription, 'Open subscription');
    expect(l.returnOnce, 'Return once');
    expect(l.donTExclude, "Don't exclude");
    expect(l.alwaysShown, 'Always shown');
    expect(l.backToStart('Foo'), 'Back to start: Foo');
    expect(l.vpnTurnedOffByTheSystem, 'VPN turned off by the system');
    expect(
      l.anotherVpnAppTookOverOr,
      'Another VPN app took over, or the VPN was switched off in the system settings. sing-box is stopped and not restarted',
    );
  });
}
