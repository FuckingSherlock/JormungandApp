import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/form_parts.dart';

Widget _app(Widget child) => MaterialApp(
    theme: appThemes[AppThemeId.original], home: Scaffold(body: child));

void main() {
  testWidgets('PingSpinner shares one ticker, rotates, stops when hidden or gone',
      (tester) async {
    expect(pingSpinnerTicking(), isFalse);
    var visible = true;
    late StateSetter set;
    await tester.pumpWidget(_app(StatefulBuilder(builder: (c, s) {
      set = s;
      return Column(children: [
        TickerMode(enabled: visible, child: const PingSpinner()),
        const PingSpinner(),
      ]);
    })));
    expect(pingSpinnerTicking(), isTrue);

    final box = find.descendant(of: find.byType(PingSpinner).last, matching: find.byType(CustomPaint));
    Future<String> snap() async {
      await tester.pump(const Duration(milliseconds: 100));
      final p = tester.renderObject<RenderCustomPaint>(box).painter!;
      return (p as dynamic).turns.value.toString();
    }

    final a = await snap();
    final b = await snap();
    expect(a, isNot(b));

    set(() => visible = false);
    await tester.pump();
    expect(pingSpinnerTicking(), isTrue); // the second one still counts

    await tester.pumpWidget(
        _app(const TickerMode(enabled: false, child: PingSpinner())));
    expect(pingSpinnerTicking(), isFalse);

    await tester.pumpWidget(_app(const PingSpinner()));
    expect(pingSpinnerTicking(), isTrue);
    await tester.pumpWidget(_app(const SizedBox()));
    expect(pingSpinnerTicking(), isFalse);
  });
}
