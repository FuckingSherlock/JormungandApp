import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/pages/rules_page.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/form_parts.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

/// A proxy rule through a chain that does not exist: a lost target.
FakeCoreHost _host({String fallback = 'block'}) {
  final host = FakeCoreHost();
  host.catalog.rulesData['r1'] = UserRule(
    id: 'r1',
    name: 'Streaming',
    enabled: true,
    action: 'proxy',
    target: 'chain:gone',
    fallback: fallback,
  );
  host.catalog.ruleOrder = ['r1'];
  return host;
}

Color _tagColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text).first).style!.color!;

void main() {
  testWidgets('a rule whose target is deleted: the error tag in the list and at the Via row, in the danger colour', (
    tester,
  ) async {
    final host = _host();
    await pumpApp(tester, host);
    showRulesPage(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();

    const tag = 'TARGET DELETED → BLOCK';
    expect(find.text(tag), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ConnTag && w.tone == TagTone.error), findsOneWidget);
    final danger = tester.element(find.text(tag)).colors.danger;
    expect(_tagColor(tester, tag), danger);

    await tester.tap(find.text('Streaming'));
    await tester.pumpAndSettle();
    expect(find.text(tag), findsNWidgets(2)); // the list row and the form's Via row
    expect(find.text('UNAVAILABLE'), findsNothing); // not the plain warning tag
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rule with a usable target has no error tag', (tester) async {
    final host = _host();
    host.catalog.rulesData['r1']!.target = '';
    await pumpApp(tester, host);
    showRulesPage(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate((w) => w is ConnTag && w.tone == TagTone.error), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
