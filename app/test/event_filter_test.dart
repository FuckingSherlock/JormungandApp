// Events: every type of the catalog has its words (en + ru), the filter sheet counts the events of
// each type, and an opened event can hide its type or show it alone.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/event_text.dart';
import 'package:jormungand/l10n/l10n.dart';
import 'package:jormungand/shell/home_shell.dart';
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
    // categories with events start unfolded
    expect(count('auto/unstable'), '3');
    expect(count('conn/lost'), '1');
    expect(count('conn/failing'), '0');
    expect(find.byKey(const ValueKey('evCount:core/crashed')), findsNothing, reason: 'an empty category stays folded');
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
