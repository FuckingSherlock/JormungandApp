// Check-row recheck animation (app/lib/widgets/event_card.dart, CheckRow.busy).
// A busy row: the verdict gradient fades out (~250 ms, linear), the row pulses yellow (CardTones.checking, opacity
// .35 ↔ 1, one cycle ~1.2 s, repeating), the retry icon turns (RotationTransition, ~1 s per turn), a tap does nothing.
// When busy turns off, the gradient of the new verdict fades in (~250 ms). A row built busy starts in the pulse.
// ok == null: no verdict gradient. A card that is not busy settles (pumpAndSettle); a busy one is pumped by duration.
// The opacity is read from the Opacity / FadeTransition widgets between a gradient and the card, the gradient from
// the DecoratedBox / Container that paints it; tones are matched by CardTones.gradient(...).colors.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/widgets/event_card.dart';

const _retryKey = ValueKey('eventCard.retry');
const _busyKey = ValueKey('eventCard.busy');

Future<void> _pump(WidgetTester t, List<CardBlock> blocks) => t.pumpWidget(
  MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SingleChildScrollView(
        child: EventCard(
          model: EventCardModel(
            level: CardLevel.warn,
            icon: null,
            time: null,
            repeats: 1,
            title: 'Check',
            copy: null,
            transition: null,
            blocks: blocks,
            cause: null,
            actions: const [],
          ),
        ),
      ),
    ),
  ),
);

List<CardBlock> _card({required bool? ok, bool busy = false, String value = 'check row', VoidCallback? onRetry}) => [
  DataBox(
    rows: [CheckRow(ok: ok, value: value, busy: busy, onRetry: onRetry, onGo: () {})],
  ),
];

/// The gradient of a Container / DecoratedBox, if the widget paints one.
LinearGradient? _gradientOf(Widget w) {
  final Decoration? d = switch (w) {
    Container(:final decoration) => decoration,
    DecoratedBox(:final decoration) => decoration,
    _ => null,
  };
  return d is BoxDecoration ? d.gradient as LinearGradient? : null;
}

/// The name of the tone whose CardTones gradient has these colours, or null.
String? _toneOf(List<Color> colours) {
  for (final (name, c) in [('good', CardTones.good), ('bad', CardTones.bad), ('checking', CardTones.checking)]) {
    if (listEquals(colours, CardTones.gradient(c).colors)) return name;
  }
  return null;
}

/// Every verdict / checking gradient painted in the card, with the opacity it is drawn with (the product of the
/// Opacity and FadeTransition widgets between it and the card).
List<(String tone, double opacity)> _verdictGradients(WidgetTester t) {
  final out = <(String tone, double opacity)>[];
  final all = find.descendant(of: find.byType(EventCard), matching: find.byWidgetPredicate((w) => _gradientOf(w) != null));
  for (final e in all.evaluate()) {
    final tone = _toneOf(_gradientOf(e.widget)!.colors);
    if (tone == null) continue;
    var opacity = 1.0;
    e.visitAncestorElements((a) {
      final w = a.widget;
      if (w is EventCard) return false;
      if (w is Opacity) opacity *= w.opacity;
      if (w is FadeTransition) opacity *= w.opacity.value;
      return true;
    });
    out.add((tone, opacity));
  }
  return out;
}

/// The opacity at which the [tone] gradient is shown now: the largest of its paints, 0 when it is not painted.
double _shown(WidgetTester t, String tone) {
  var best = 0.0;
  for (final (name, opacity) in _verdictGradients(t)) {
    if (name == tone && opacity > best) best = opacity;
  }
  return best;
}

/// The turn (0..1 of a full rotation) of the card's RotationTransition (the busy retry icon's).
double _turns(WidgetTester t) {
  final rotations = find.descendant(of: find.byType(EventCard), matching: find.byType(RotationTransition));
  expect(rotations, findsOneWidget, reason: 'the busy icon turns through a RotationTransition');
  return t.widget<RotationTransition>(rotations).turns.value;
}

void main() {
  testWidgets('a busy check row shows the rotating busy icon; a tap on the row or its retry does not call onRetry', (t) async {
    var retry = 0;
    await _pump(t, _card(ok: false, busy: true, value: 'busy row', onRetry: () => retry++));
    await t.pump(const Duration(seconds: 1));

    expect(find.byKey(_busyKey), findsOneWidget);
    await t.tap(find.text('busy row'));
    await t.tap(find.byKey(_retryKey));
    await t.pump(const Duration(seconds: 1));
    expect(retry, 0);
    expect(t.takeException(), isNull);
  });

  for (final ok in <bool?>[true, false, null]) {
    testWidgets('an idle check row (ok: $ok) has no busy icon, its retry runs onRetry, and the card settles', (t) async {
      var retry = 0;
      await _pump(t, _card(ok: ok, onRetry: () => retry++));
      await t.pumpAndSettle();

      expect(find.byKey(_busyKey), findsNothing);
      await t.tap(find.byKey(_retryKey));
      await t.pumpAndSettle();
      expect(retry, 1);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('a check row with no verdict yet (ok null) paints no good or bad gradient', (t) async {
    await _pump(t, _card(ok: null, value: 'first check'));
    await t.pumpAndSettle();

    expect(find.text('first check'), findsOneWidget);
    expect(_verdictGradients(t).where((g) => g.$1 == 'good' || g.$1 == 'bad'), isEmpty);
  });

  for (final ok in <bool?>[null, false]) {
    testWidgets('a busy check row (ok: $ok) pulses yellow: opacity between .35 and 1, one cycle every 1.2 s', (t) async {
      await _pump(t, _card(ok: ok, busy: true, value: 'pulse row'));
      final samples = <double>[];
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(milliseconds: 50));
        samples.add(_shown(t, 'checking'));
      }

      expect(samples.reduce(math.min), closeTo(0.35, 0.05));
      expect(samples.reduce(math.max), closeTo(1, 0.05));
      for (var i = 0; i + 24 < samples.length; i++) {
        expect(samples[i + 24], closeTo(samples[i], 0.05), reason: 'sample $i: 1.2 s later the pulse is the same');
      }
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('a row built busy starts straight in the pulse: the bad verdict is not shown', (t) async {
    await _pump(t, _card(ok: false, busy: true, value: 'started row'));
    expect(_shown(t, 'bad'), 0);
    expect(_shown(t, 'checking'), greaterThan(0.3));

    await t.pump(const Duration(milliseconds: 100));
    expect(_shown(t, 'bad'), 0);
    expect(_shown(t, 'checking'), greaterThan(0.3));
  });

  testWidgets('turning busy on fades the bad verdict out over ~250 ms, then the yellow pulse shows', (t) async {
    await _pump(t, _card(ok: false, value: 'fading row'));
    await t.pumpAndSettle();
    expect(_shown(t, 'bad'), closeTo(1, 0.01));

    await _pump(t, _card(ok: false, busy: true, value: 'fading row'));
    await t.pump(const Duration(milliseconds: 125));
    expect(_shown(t, 'bad'), inInclusiveRange(0.1, 0.9), reason: 'halfway through the fade-out');

    await t.pump(const Duration(milliseconds: 400));
    expect(_shown(t, 'bad'), 0);
    expect(_shown(t, 'checking'), greaterThan(0.3));
  });

  testWidgets('busy turning off with a new verdict: the new gradient fades in over ~250 ms; the old one and the pulse go', (t) async {
    await _pump(t, _card(ok: false, busy: true, value: 'verdict row'));
    await t.pump(const Duration(seconds: 1));

    await _pump(t, _card(ok: true, busy: false, value: 'verdict row'));
    await t.pump(const Duration(milliseconds: 100));
    expect(_shown(t, 'good'), inInclusiveRange(0.1, 0.9), reason: 'the new verdict is mid fade-in');

    await t.pump(const Duration(milliseconds: 200));
    expect(_shown(t, 'good'), closeTo(1, 0.01));
    expect(_shown(t, 'bad'), 0);
    expect(_shown(t, 'checking'), 0);

    await t.pumpAndSettle();
    expect(find.byKey(_busyKey), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('the busy icon turns about one turn per second, at a steady rate', (t) async {
    await _pump(t, _card(ok: false, busy: true));
    await t.pump();
    final start = _turns(t);

    await t.pump(const Duration(milliseconds: 250));
    final quarter = (_turns(t) - start) % 1;
    expect(quarter, closeTo(0.25, 0.05));

    await t.pump(const Duration(milliseconds: 250));
    final half = (_turns(t) - start) % 1;
    expect(half, closeTo(0.5, 0.05));
  });

  testWidgets('a busy row removed from the card leaves no animation running', (t) async {
    await _pump(t, _card(ok: false, busy: true, value: 'going row'));
    await t.pump(const Duration(milliseconds: 500));

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
    expect(t.takeException(), isNull);
  });
}
