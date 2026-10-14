// Events: every type of the catalog has its words (en + ru), the filter sheet counts the events of
// each type, and an opened event can hide its type or show it alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/widgets/form_parts.dart' show MiniToggle;
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

void main() {
  test('every type of the catalog has a label in en and ru, and its own sentence', () {
    final catalog = FakeCoreHost().catalog;
    for (final lang in ['en', 'ru']) {
      final w = EventWords(lookupAppLocalizations(Locale(lang)), catalog);
      for (final (cat, types) in eventCats) {
        expect(w.catLabel(cat), isNotEmpty);
        for (final t in types) {
          final label = w.typeLabel(cat, t);
          expect(label, isNotEmpty, reason: '$cat/$t $lang');
          expect(label, isNot('$cat / $t'), reason: '$cat/$t has no label in $lang');
        }
      }
    }
  });

  test('the new types read as sentences, and search finds a type by its label', () {
    final w = EventWords(lookupAppLocalizations(const Locale('en')), FakeCoreHost().catalog);
    EventRecord ev(String cat, String type, Map<String, dynamic> data) =>
        EventRecord(id: 1, at: 0, cat: cat, type: type, level: 'warn', own: false, log: null, data: data);
    final failing = w.describe(ev('conn', 'failing', {
      'app': 'org.telegram.messenger',
      'host': 'api.telegram.org',
      'port': 443,
      'outbound': 'proxy/vless[a]',
      'route': 'proxy',
      'kind': 'timeout',
      'count': 3,
      'windowMs': 60000,
    }));
    expect(failing.title, contains('api.telegram.org:443'));
    expect(failing.detail, contains('No answer in time'));
    expect(failing.detail, contains('3'));
    final dead = w.describe(ev('core', 'tunTcpDead', {'stack': 'system', 'apps': ['org.telegram.messenger']}));
    expect(dead.detail, contains('system'));
    expect(dead.detail, contains('org.telegram.messenger'));
    final back = w.describe(ev('core', 'tunTcpBack', {'stack': 'system', 'deadMs': 12000}));
    expect(back.detail, contains('12'));
    for (final t in ['updateAvailable', 'updateFailed', 'updateChannelEmpty', 'updateDownloaded', 'updateDeltaFailed', 'updateInstalled']) {
      expect(w.describe(ev('core', t, {'version': '1.2.3', 'to': '1.2.3', 'channel': 'beta'})).title, isNot('core / $t'));
    }
    final unstable = ev('auto', 'unstable', {'id': 'x'});
    expect(w.searchText(unstable).toLowerCase(), contains('unstable entry'));
    expect(w.searchText(unstable).toLowerCase(), contains('auto'));
  });

  test('sub/diverged says the servers differ and which copy is used; the lists are one item per line', () async {
    await initializeDateFormatting('en');
    final w = EventWords(lookupAppLocalizations(const Locale('en')), FakeCoreHost().catalog);
    EventGroup group(String used) {
      final e = EventRecord(id: 1, at: 0, cat: 'sub', type: 'diverged', level: 'warn', own: false, log: null, data: {
        'name': 'Prov',
        'directNodes': 12,
        'tunnelNodes': 15,
        'onlyDirect': const <String>[],
        'onlyTunnel': const ['a (1.1.1.1:443)', 'b (2.2.2.2:443)'],
        'onlyTunnelCount': 12,
        'directStatus': 200,
        'tunnelStatus': 200,
        'directMs': 1200,
        'tunnelMs': 300,
        'directPath': 'direct',
        'tunnelPath': 'proxy',
        'used': used,
      });
      return EventGroup(e);
    }

    final tunnel = group('tunnel').ev;
    expect(w.describe(tunnel).title, contains('different servers'));
    expect(w.describe(tunnel).detail, 'The VPN copy is used.');
    expect(w.describe(group('direct').ev).detail, 'The direct copy is used.');
    final f = Map.fromEntries(w.fields(group('tunnel')).map((x) => MapEntry(x.$1, x.$2)));
    expect(f['Only via VPN'], '12\na (1.1.1.1:443)\nb (2.2.2.2:443)\n… and 10 more');
    expect(f['Servers (direct)'], '12');
    expect(f['Copy used'], 'VPN copy');
    expect(f.keys, isNot(contains('OnlyTunnelCount')));
    expect(f['Only direct'], '0');
  });

  testWidgets('filter sheet: categories start folded, an unfolded one is remembered; no «Filtered» bar', (tester) async {
    final host = FakeCoreHost();
    host.addEvent('auto', 'unstable', level: 'warn', data: {'id': 'e0', 'strikes': 2, 'holdMs': 60000});
    host.addEvent('conn', 'lost', level: 'warn');
    host.addEvent('site', 'unreachable', level: 'warn', bg: true, data: {'host': 'a.example.org', 'tried': const []});
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();
    final words = EventWords(lookupAppLocalizations(const Locale('en')), host.catalog);
    Future<void> openSheet() async {
      await tester.tap(find.byIcon(Icons.filter_alt_outlined));
      await tester.pumpAndSettle();
    }

    await openSheet();
    expect(find.byKey(const ValueKey('evCount:auto/unstable')), findsNothing, reason: 'all folded on the first open');
    expect(find.byKey(const ValueKey('evCount:conn/lost')), findsNothing);
    await tester.tap(find.text(words.catLabel('auto')).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('evCount:auto/unstable')), findsOneWidget);
    expect(find.byKey(const ValueKey('evCount:conn/lost')), findsNothing);
    expect((host.catalog.unknown['logCfg'] as Map)['openCats'], ['auto']);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await openSheet();
    expect(find.byKey(const ValueKey('evCount:auto/unstable')), findsOneWidget, reason: 'still unfolded');
    expect(find.byKey(const ValueKey('evCount:conn/lost')), findsNothing, reason: 'the other one still folded');

    // with a filter on there is a badge, but no «Filtered: …» text on the page
    await tester.ensureVisible(find.byKey(const ValueKey('evFilterBg')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('evFilterBg')), matching: find.byType(MiniToggle)));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('logsFilterBadge')), findsOneWidget);
    expect(find.textContaining('Filtered'), findsNothing);
  });

  testWidgets('filter sheet: counts per type, empty ones dimmed; an event hides its type or shows it alone', (tester) async {
    final host = FakeCoreHost();
    for (var i = 0; i < 3; i++) {
      host.addEvent('auto', 'unstable', level: 'warn', data: {'id': 'e$i', 'strikes': 2, 'holdMs': 60000});
    }
    host.addEvent('conn', 'lost', level: 'warn');
    await pumpApp(tester, host);
    await tester.tap(find.byIcon(AppTab.logs.icon));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    String count(String key) => tester.widget<Text>(find.byKey(ValueKey('evCount:$key'))).data!;
    // categories start folded; unfold the two used here
    final words = EventWords(lookupAppLocalizations(const Locale('en')), host.catalog);
    expect(find.byKey(const ValueKey('evCount:auto/unstable')), findsNothing);
    for (final cat in ['auto', 'conn']) {
      await tester.tap(find.text(words.catLabel(cat)).last);
      await tester.pumpAndSettle();
    }
    expect(count('auto/unstable'), '3');
    expect(count('conn/lost'), '1');
    expect(count('conn/failing'), '0');
    expect(find.byKey(const ValueKey('evCount:core/crashed')), findsNothing, reason: 'another category stays folded');
    // the sheet has no search field any more
    expect(find.byType(TextField), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // an opened event: "Show only this type"
    await tester.tap(find.text('Connection lost').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('evHideType')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('evOnlyType')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('evOnlyType')));
    await tester.pumpAndSettle();
    expect(find.textContaining('is unstable'), findsNothing);
    expect(find.text('Connection lost'), findsWidgets);

    // "Hide this type" takes it away again (the row stays open)
    await tester.ensureVisible(find.byKey(const ValueKey('evHideType')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('evHideType')));
    await tester.pumpAndSettle();
    expect(find.text('Connection lost'), findsNothing);
  });
}
