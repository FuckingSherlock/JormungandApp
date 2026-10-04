import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/app.dart';
import 'package:jormungand/shell/home_shell.dart';
import 'package:jormungand/state/app_settings.dart';

import 'fake_core_host.dart';

void main() {
  testWidgets('shell opens on Home and switches tabs', (tester) async {
    await tester.pumpWidget(JormungandApp(coreHost: FakeCoreHost()));
    await tester.pumpAndSettle();

    expect(find.text('Jormungand'), findsOneWidget);
    expect(
      find.byType(NavigationDestination),
      findsNWidgets(AppTab.values.length),
    );

    await tester.tap(find.byIcon(AppTab.settings.icon));
    await tester.pumpAndSettle();
    // the Settings tab is a menu of sections; the Text size slider is in Appearance
    expect(find.byKey(const ValueKey('settings-setlook')), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-setlook')));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);
  });

  test('text scale is clamped to 90-120 % in 5 % steps', () {
    expect(AppSettings.clampTextScale(0.5), 0.9);
    expect(AppSettings.clampTextScale(2), 1.2);
    expect(AppSettings.clampTextScale(1.07), 1.05);
  });
}
