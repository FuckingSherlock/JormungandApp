// Event texts, split apart (docs/logs.md «Заголовок и подробности — разные строки» and the «По событиям» table;
// docs/connect-model.md «Строка ноды в событии» and «Check again»; English wording as the app shows it). describe and
// describeGroup give the title and the sub line apart: the title is the text before the first « · », a « by … »
// attribution stays in the title. text(e) joins title, sub and detail. A server named by a sing-box tag shows the
// node's name, and serverLabel gives the name and the protocol. earlierChecks lists the Check again results, oldest
// first. A reopened site reads «<host> opens again through <route>» with «checked HH:MM».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

const _t0 = 1800000000000; // a fixed clock, in ms

/// An event as the journal holds it (`at` is in ms, counted from [_t0] in seconds).
EventRecord _ev(
  int id,
  String cat,
  String type, {
  String level = 'warn',
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

final _en = lookupAppLocalizations(const Locale('en'));

/// A host whose catalog holds one subscription «src1» with two servers: n1 «One» (vless) and n2 «Two» (hysteria2).
FakeCoreHost _host() {
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
  return host;
}

/// HH:MM of an epoch-ms time in local time, the way the event texts show a clock.
String _hhmm(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  late FakeCoreHost host;
  late EventWords words;
  setUp(() {
    host = _host();
    words = EventWords(_en, host.catalog);
  });

  group('title and sub are built apart', () {
    test('auto/unstable: the entry is the title, the failures and the hold are the sub', () {
      final d = words.describe(_ev(1, 'auto', 'unstable', data: const {'id': 'white', 'strikes': 3, 'holdMs': 240000}));
      expect(d.title, 'white is unstable');
      expect(d.sub, '3 failures, excluded for 4 min');
    });

    test('a spare entry says so in the title, the sub has the same shape', () {
      final d = words.describe(
        _ev(1, 'auto', 'unstable', level: 'info', data: const {'id': 'white', 'strikes': 3, 'holdMs': 240000, 'spare': true}),
      );
      expect(d.title, 'Spare entry white is unstable');
      expect(d.sub, '3 failures, excluded for 4 min');
    });

    test('the text before the first « · » is the title; the rest keeps its inner « · » in the sub', () {
      final net = words.describe(_ev(1, 'conn', 'vpnDown', data: const {'causes': ['network']}));
      expect(net.title, 'Waiting for network');
      expect(net.sub, 'VPN is on, no internet connection');
      final re = words.describe(_ev(2, 'conn', 'reconnected', level: 'info', data: const {'reason': 'lists', 'tookMs': 3000}));
      expect(re.title, 'Reconnected');
      expect(re.sub, 'rule lists · 3 s');
    });

    test('a « by … » attribution stays in the title and the sub is empty', () {
      for (final (own, data, title) in [
        (true, const {'by': 'user'}, 'VPN disconnected · by you'),
        (false, const {'by': 'system', 'reason': 'revoked'}, 'VPN disconnected · by the system or another app'),
      ]) {
        final d = words.describe(_ev(1, 'conn', 'disconnected', level: 'info', own: own, data: data));
        expect(d.title, title, reason: '$data');
        expect(d.sub, '', reason: '$data');
      }
    });

    test('Reconnected · by you: the attribution is in the title, the downtime and the time in the sub', () {
      final d = words.describe(_ev(1, 'conn', 'reconnected', level: 'info', data: const {'reason': 'user', 'tookMs': 1000}));
      expect(d.title, 'Reconnected · by you');
      expect(d.sub, startsWith('VPN was off for '));
      expect(d.sub, endsWith(' · 1 s'));
    });

    test('an error reason is the sub; the title is the disconnect itself', () {
      final d = words.describe(_ev(1, 'conn', 'disconnected', data: const {'by': 'error', 'reason': 'down', 'attempts': 3}));
      expect(d.title, 'VPN disconnected');
      expect(d.sub, 'error: sing-box did not start after 3 attempts');
    });

    test('describeGroup gives the title, the sub and the detail apart', () {
      final (title, sub, detail) = words.describeGroup(
        EventGroup(_ev(1, 'auto', 'unstable', data: const {'id': 'white', 'strikes': 3, 'holdMs': 240000})),
      );
      expect(title, 'white is unstable');
      expect(sub, '3 failures, excluded for 4 min');
      expect(detail, '');
    });
  });

  group('text(e) joins the non-empty parts as title · sub — detail', () {
    test('a title alone, and a title with a sub, have no dangling separator', () {
      expect(
        words.text(_ev(1, 'conn', 'disconnected', level: 'info', own: true, data: const {'by': 'user'})),
        'VPN disconnected · by you',
      );
      expect(
        words.text(_ev(1, 'auto', 'unstable', data: const {'id': 'white', 'strikes': 3, 'holdMs': 240000})),
        'white is unstable · 3 failures, excluded for 4 min',
      );
    });

    test('a detail comes after « — »', () {
      final t = words.text(_ev(1, 'conn', 'connectFailed', data: const {'reason': 'no route'}));
      expect(t, endsWith(' — no route'));
      expect(t, isNot(contains(' · ')));
    });
  });

  group('a server named by a sing-box tag shows the node name, never the tag', () {
    test('server() takes the node key out of each tag form, and a bare key; nameOf too', () {
      for (final tag in ['route0/src1::n1', 'route0-entry/src1::n1', 'chain:c1/src1::n1', 'src1::n1']) {
        expect(words.server(tag), 'One', reason: tag);
      }
      expect(words.nameOf('route0/src1::n2'), 'Two');
    });

    test('a deleted node keeps the raw text', () {
      const tag = 'route0/src1::gone';
      expect(words.server(tag), tag);
    });

    test('a site event whose data.server is a tag reads the node name in its texts', () {
      final e = _ev(
        1,
        'site',
        'blocked',
        data: const {'host': 'shop.example', 'entry': 'Germany', 'server': 'route0/src1::n1'},
      );
      final d = words.describe(e);
      final texts = [
        words.text(e),
        d.title,
        d.sub,
        for (final (k, v) in words.fields(EventGroup(e))) ...[k, v],
      ];
      expect(texts.where((s) => s.contains('route0/')), isEmpty, reason: '$texts');
      expect(texts.where((s) => s.contains('One')), isNotEmpty, reason: '$texts');
    });
  });

  group('serverLabel: the node name as server() gives it, and the protocol the app shows for the node', () {
    test('a catalog node: its name and its protocol label', () {
      final node = host.catalog.nodeOfKey('src1::n2')!;
      final l = words.serverLabel('route0/src1::n2');
      expect(l.name, 'Two');
      // The app's badge helper (protoLabel) decides the wording; its casing is the badge's CSS, so compare ignoring case.
      expect(l.protocol.toLowerCase(), protoLabel(node.protocol, node.outbound).toLowerCase());
      expect(l.protocol.toLowerCase(), 'hysteria2');
    });

    test('a deleted node: no protocol, and the name server() gives', () {
      const tag = 'route0/src1::gone';
      final l = words.serverLabel(tag);
      expect(l.protocol, '');
      expect(l.name, words.server(tag));
    });
  });

  group('earlierChecks: one line per Check again result, oldest first', () {
    final t1 = _t0 + 60000, t2 = _t0 + 300000, t3 = _t0 + 600000;

    test('blocked: did not open through the route (server), opened through the via (server); unreachable: no server', () {
      final e = _ev(
        1,
        'site',
        'blocked',
        data: {
          'host': 'shop.example',
          'entry': 'Germany',
          'server': 'route0/src1::n1',
          'checks': [
            {'at': t1, 'kind': 'blocked', 'server': 'route0/src1::n1', 'via': 'Sweden', 'viaServer': 'route0/src1::n2'},
            {'at': t2, 'kind': 'blocked', 'server': 'route0/src1::n1', 'via': 'Sweden'},
            {'at': t3, 'kind': 'unreachable', 'server': 'route0/src1::n2'},
          ],
        },
      );
      expect(words.earlierChecks(e), [
        '${_hhmm(t1)} · did not open through Germany (One), opened through Sweden (Two)',
        '${_hhmm(t2)} · did not open through Germany (One), opened through Sweden',
        '${_hhmm(t3)} · did not open through any server',
      ]);
    });

    test('no checks yet: no lines', () {
      expect(words.earlierChecks(_ev(1, 'site', 'blocked', data: const {'host': 'shop.example'})), isEmpty);
    });

    test('the block is labelled Earlier checks', () {
      expect(_en.earlierChecks, 'Earlier checks');
    });
  });

  group('a reopened site closes as a pair: « opens again through » · checked HH:MM', () {
    test('title: the host and the route; sub: the time of the check that found it open', () {
      final at = _t0 + 600000;
      final e = _ev(
        1,
        'site',
        'blocked',
        data: {
          'host': 'shop.example',
          'entry': 'Germany',
          'server': 'route0/src1::n1',
          'checks': [
            {'at': _t0 + 60000, 'kind': 'blocked', 'server': 'route0/src1::n1'},
          ],
          'reopened': {'at': at, 'entry': 'Germany', 'server': 'route0/src1::n1'},
        },
      );
      final d = words.describe(e);
      expect(d.title, startsWith('shop.example opens again through '));
      expect(d.title, contains('Germany'));
      expect(d.sub, 'checked ${_hhmm(at)}');
    });
  });
}
