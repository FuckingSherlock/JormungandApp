import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/settings_dns.dart' show SideChip;

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(AppColors.original),
  home: Scaffold(body: Center(child: child)),
);

Color _border(WidgetTester t) {
  final box = t.widget<Container>(
    find.descendant(of: find.byType(SideChip), matching: find.byType(Container)),
  );
  return ((box.decoration! as BoxDecoration).border! as Border).top.color;
}

void main() {
  testWidgets('answering chip pulses through a timer, not a ticker', (t) async {
    await t.pumpWidget(_host(const SideChip(label: 'VPN', on: true, answering: true)));
    final a = _border(t);
    await t.pump(const Duration(milliseconds: 50));
    final b = _border(t);
    expect(b, isNot(a));
    await t.pump(const Duration(milliseconds: 1000));
    expect(_border(t), isNot(b));
    // a repaint boundary isolates the pulse from the sheet
    expect(
      find.descendant(of: find.byType(SideChip), matching: find.byType(RepaintBoundary)),
      findsWidgets,
    );
    // dispose cancels the timer (a pending timer would fail the test)
    await t.pumpWidget(_host(const SizedBox()));
  });

  testWidgets('non-answering chip schedules no timer', (t) async {
    await t.pumpWidget(_host(const SideChip(label: 'VPN', on: true)));
    final a = _border(t);
    await t.pump(const Duration(milliseconds: 500));
    expect(_border(t), a);
  });

  testWidgets('covered chip (TickerMode off) stops, resumes when visible', (t) async {
    Widget build(bool enabled) => _host(
      TickerMode(
        enabled: enabled,
        child: const SideChip(label: 'VPN', on: true, answering: true),
      ),
    );
    await t.pumpWidget(build(false));
    final a = _border(t);
    await t.pump(const Duration(milliseconds: 500));
    expect(_border(t), a);
    await t.pumpWidget(build(true));
    await t.pump(const Duration(milliseconds: 300));
    expect(_border(t), isNot(a));
    await t.pumpWidget(_host(const SizedBox()));
  });
}
