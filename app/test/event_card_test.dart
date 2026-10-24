// Generic event card (app/lib/widgets/event_card.dart, docs/connect-model.md:944-958): the card knows nothing about
// event types, it draws a model. Checked here: the switch frame (one row, two-line label, two rows, heading), the data
// box (key rows with a tap and a go control, sections, check rows ok and bad with retry and go), the cause line, the
// Details ▾ action always first, the header (icon, time, ×N, neutral transition, level label), the level stripe
// (warn, error and info differ; colours come from the app theme), the frame background = data-box row background,
// the red / green check-row gradients from one table (the same under two app themes), and a 320 px width at 120 %
// text without overflow. Controls are found by the keys the card gives them.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/l10n/gen/app_localizations.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/event_card.dart';

const _retryKey = ValueKey('eventCard.retry');
const _goKey = ValueKey('eventCard.go');
const _rowKey = ValueKey('eventCard.row');

Future<void> _pump(WidgetTester t, EventCardModel model, {ThemeData? theme, double textScale = 1}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
        child: w!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(child: EventCard(model: model)),
      ),
    ),
  );
  // MaterialApp animates a theme change (AnimatedTheme); let it finish before reading colours.
  await t.pump(const Duration(seconds: 1));
}

EventCardModel _model({
  CardLevel level = CardLevel.warn,
  String title = 'DNS switched',
  IconData? icon,
  String? time,
  int repeats = 1,
  (String, String)? transition,
  List<CardBlock> blocks = const [],
  (String, String)? cause,
  List<CardAction> actions = const [],
}) => EventCardModel(
  level: level,
  icon: icon,
  time: time,
  repeats: repeats,
  title: title,
  transition: transition,
  blocks: blocks,
  cause: cause,
  actions: actions,
);

/// The gradient of a Container / DecoratedBox, if the widget paints one.
LinearGradient? _gradientOf(Widget w) {
  final Decoration? d = switch (w) {
    Container(:final decoration) => decoration,
    DecoratedBox(:final decoration) => decoration,
    _ => null,
  };
  return d is BoxDecoration ? d.gradient as LinearGradient? : null;
}

/// Colours of every gradient painted above the text [text] (the check row's own background).
List<Color> _gradientColours(WidgetTester t, String text) {
  final boxes = find.ancestor(of: find.text(text), matching: find.byWidgetPredicate((w) => _gradientOf(w) != null));
  return [for (final e in boxes.evaluate()) ..._gradientOf(e.widget)!.colors];
}

bool _isRed(Color c) => c.r > c.g && c.r > c.b;
bool _isGreen(Color c) => c.g > c.r && c.g > c.b;

/// The colour a widget paints as its own box (Container / DecoratedBox / ColoredBox / Material), if any.
Color? _boxColour(Widget w) {
  final Decoration? d = switch (w) {
    Container(:final decoration) => decoration,
    DecoratedBox(:final decoration) => decoration,
    _ => null,
  };
  if (d is BoxDecoration && d.color != null) return d.color;
  return switch (w) {
    Container(:final color) => color,
    ColoredBox(:final color) => color,
    Material(:final color) => color,
    _ => null,
  };
}

/// The box colour of the nearest painted ancestor of the widget found by [f].
Color? _nearestColour(WidgetTester t, Finder f) {
  Color? found;
  t.element(f).visitAncestorElements((e) {
    found = _boxColour(e.widget);
    return found == null;
  });
  return found;
}

/// Every colour the card paints: box colours, gradient stops, border sides.
Set<Color> _paintedColours(WidgetTester t) {
  final out = <Color>{};
  final all = find.descendant(of: find.byType(EventCard), matching: find.byWidgetPredicate((_) => true));
  for (final e in all.evaluate()) {
    final w = e.widget;
    final c = _boxColour(w);
    if (c != null) out.add(c);
    final d = _gradientOf(w);
    if (d != null) out.addAll(d.colors);
    final box = switch (w) {
      Container(:final decoration) => decoration,
      DecoratedBox(:final decoration) => decoration,
      _ => null,
    };
    if (box is BoxDecoration && box.border is Border) {
      final b = box.border as Border;
      out.addAll([b.top.color, b.right.color, b.bottom.color, b.left.color]);
    }
  }
  return out;
}

String _levelLabel(CardLevel l) => switch (l) {
  CardLevel.warn => 'WARN',
  CardLevel.error => 'ERROR',
  CardLevel.info => 'INFO',
  CardLevel.ok => 'OK',
};

void main() {
  testWidgets('switch frame with one row shows the label and both chips', (t) async {
    await _pump(
      t,
      _model(
        blocks: [
          SwitchFrame(
            rows: [
              SwitchRow(label: 'DNS', from: ChipText(title: 'Alpha', sub: 'DoH'), to: ChipText(title: 'Beta')),
            ],
          ),
        ],
      ),
    );
    expect(find.text('DNS'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('DoH'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(_gradientColours(t, 'Alpha').any(_isRed), isTrue, reason: 'from chip is red');
    expect(_gradientColours(t, 'Beta').any(_isGreen), isTrue, reason: 'to chip is green');
    expect(t.takeException(), isNull);
  });

  testWidgets('switch frame background is the same colour as the data box row background', (t) async {
    await _pump(
      t,
      _model(
        blocks: [
          SwitchFrame(
            rows: [SwitchRow(label: 'DNS', from: ChipText(title: 'Alpha'), to: ChipText(title: 'Beta'))],
          ),
          DataBox(rows: [KeyRow(name: 'Node', value: 'node-one')]),
        ],
      ),
    );
    final frame = _nearestColour(t, find.text('DNS'));
    final row = _nearestColour(t, find.text('node-one'));
    expect(frame, isNotNull);
    expect(frame, equals(row));
  });

  testWidgets('switch frame row with a two-line label renders both lines', (t) async {
    await _pump(
      t,
      _model(
        blocks: [
          SwitchFrame(
            rows: [
              SwitchRow(
                label: 'Answers\nthrough VPN',
                from: ChipText(title: 'Alpha'),
                to: ChipText(title: 'Beta'),
              ),
            ],
          ),
        ],
      ),
    );
    expect(find.text('Answers\nthrough VPN'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('switch frame with a heading and two rows shows both rows and the heading', (t) async {
    await _pump(
      t,
      _model(
        blocks: [
          SwitchFrame(
            heading: 'Changed with network',
            rows: [
              SwitchRow(label: 'VPN', from: ChipText(title: 'Alpha', sub: 'DoH'), to: ChipText(title: 'Gamma', sub: 'DoT')),
              SwitchRow(label: 'Direct', from: ChipText(title: 'Delta'), to: ChipText(title: 'system')),
            ],
          ),
        ],
      ),
    );
    expect(find.text('Changed with network'), findsOneWidget);
    expect(find.text('VPN'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    expect(find.text('Delta'), findsOneWidget);
    expect(find.text('system'), findsOneWidget);
  });

  testWidgets('data box key row shows name, icon, value and sub; a row tap runs onTap, the go control runs onGo', (t) async {
    var tapped = 0;
    var went = 0;
    await _pump(
      t,
      _model(
        blocks: [
          DataBox(
            rows: [
              KeyRow(
                name: 'Server',
                icon: Icons.dns,
                value: 'alpha-server',
                sub: 'DoH · 12 ms',
                onTap: () => tapped++,
                onGo: () => went++,
              ),
            ],
          ),
        ],
      ),
    );
    expect(find.text('Server'), findsOneWidget);
    expect(find.byIcon(Icons.dns), findsOneWidget);
    expect(find.text('alpha-server'), findsOneWidget);
    expect(find.text('DoH · 12 ms'), findsOneWidget);

    await t.tap(find.byKey(_rowKey));
    expect(tapped, 1);
    await t.tap(find.byKey(_goKey));
    expect(went, 1);
  });

  testWidgets('data box section shows its title as a subheading', (t) async {
    await _pump(
      t,
      _model(
        blocks: [
          DataBox(
            rows: [
              CardSection(title: 'Checked through'),
              KeyRow(name: 'Node', value: 'node-one'),
            ],
          ),
        ],
      ),
    );
    expect(find.text('Checked through'), findsOneWidget);
    expect(find.text('node-one'), findsOneWidget);
  });

  testWidgets('bad check row shows value and sub; retry and go each fire their own callback', (t) async {
    var retry = 0;
    var went = 0;
    await _pump(
      t,
      _model(
        blocks: [
          DataBox(
            rows: [
              CheckRow(
                ok: false,
                value: 'no answer',
                sub: 'stays selected',
                onRetry: () => retry++,
                onGo: () => went++,
              ),
            ],
          ),
        ],
      ),
    );
    expect(find.text('no answer'), findsOneWidget);
    expect(find.text('stays selected'), findsOneWidget);

    await t.tap(find.byKey(_retryKey));
    expect(retry, 1);
    expect(went, 0);
    await t.tap(find.byKey(_goKey));
    expect(went, 1);
    expect(retry, 1);
  });

  testWidgets('ok check row shows its value; its retry and go controls run their callbacks', (t) async {
    var retry = 0;
    var went = 0;
    await _pump(
      t,
      _model(
        blocks: [
          DataBox(
            rows: [CheckRow(ok: true, value: 'answers', onRetry: () => retry++, onGo: () => went++)],
          ),
        ],
      ),
    );
    expect(find.text('answers'), findsOneWidget);
    await t.tap(find.byKey(_retryKey));
    expect(retry, 1);
    await t.tap(find.byKey(_goKey));
    expect(went, 1);
  });

  testWidgets('check rows: red gradient for bad, green for ok, the same gradients under two app themes', (t) async {
    EventCardModel rows() => _model(
      blocks: [
        DataBox(
          rows: [
            CheckRow(ok: false, value: 'bad row'),
            CheckRow(ok: true, value: 'good row'),
          ],
        ),
      ],
    );

    // Two real app themes (the app has no light theme: every AppColors set is dark).
    await _pump(t, rows(), theme: buildAppTheme(AppColors.original));
    final origBad = _gradientColours(t, 'bad row');
    final origGood = _gradientColours(t, 'good row');
    await _pump(t, rows(), theme: buildAppTheme(AppColors.karing));
    final karingBad = _gradientColours(t, 'bad row');
    final karingGood = _gradientColours(t, 'good row');

    expect(origBad.any(_isRed), isTrue);
    expect(origGood.any(_isGreen), isTrue);
    expect(karingBad, equals(origBad));
    expect(karingGood, equals(origGood));
  });

  testWidgets('cause line reads «Cause: <bold> — rest» with the bold part in bold', (t) async {
    await _pump(t, _model(cause: ('Alpha itself', 'Beta answers through the same route')));

    final cause = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('Cause:'));
    expect(cause, findsOneWidget);
    final root = (t.widget(cause) as RichText).text;
    expect(root.toPlainText(), 'Cause: Alpha itself — Beta answers through the same route');

    final spans = <TextSpan>[];
    void walk(InlineSpan s) {
      if (s is! TextSpan) return;
      if (s.text == 'Alpha itself') spans.add(s);
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c);
      }
    }

    walk(root);
    expect(spans, isNotEmpty);
    expect(spans.any((s) => (s.style?.fontWeight?.value ?? 0) >= FontWeight.w600.value), isTrue);
  });

  testWidgets('Details ▾ is the first action even when it is given last', (t) async {
    var details = 0;
    await _pump(
      t,
      _model(
        actions: [
          CardAction(label: 'Ignore site', onTap: () {}),
          CardAction(label: 'Details ▾', details: true, onTap: () => details++),
        ],
      ),
    );
    // Reading order: the Details button is left of (or above) the other action.
    final d = t.getCenter(find.text('Details ▾'));
    final o = t.getCenter(find.text('Ignore site'));
    final detailsFirst = (d.dy - o.dy).abs() < 1 ? d.dx < o.dx : d.dy < o.dy;
    expect(detailsFirst, isTrue);

    await t.tap(find.text('Details ▾'));
    expect(details, 1);
  });

  testWidgets('header shows the icon, the time, ×N, and a transition as two neutral chips', (t) async {
    await _pump(
      t,
      _model(
        icon: Icons.dns,
        time: '12:00:05',
        repeats: 3,
        transition: ('Direct', 'VPN'),
      ),
    );
    expect(find.byIcon(Icons.dns), findsOneWidget);
    expect(find.text('12:00:05'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('VPN'), findsOneWidget);
    expect(find.text('DNS switched'), findsOneWidget);
    expect(_gradientColours(t, 'Direct').any((c) => _isRed(c) || _isGreen(c)), isFalse, reason: 'neutral chip');
    expect(_gradientColours(t, 'VPN').any((c) => _isRed(c) || _isGreen(c)), isFalse, reason: 'neutral chip');
  });

  for (final level in CardLevel.values) {
    testWidgets('level ${level.name} shows its label and title without error', (t) async {
      await _pump(t, _model(level: level, title: 'Level ${level.name} title'));
      expect(find.text(_levelLabel(level)), findsOneWidget);
      expect(find.text('Level ${level.name} title'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('warn, error and info paint different stripe colours; the card colours come from the app theme', (t) async {
    final painted = <CardLevel, Set<Color>>{};
    for (final level in [CardLevel.warn, CardLevel.error, CardLevel.info]) {
      await _pump(t, _model(level: level), theme: buildAppTheme(AppColors.original));
      painted[level] = _paintedColours(t);
    }
    expect(painted[CardLevel.warn], isNot(equals(painted[CardLevel.error])));
    expect(painted[CardLevel.warn], isNot(equals(painted[CardLevel.info])));
    expect(painted[CardLevel.error], isNot(equals(painted[CardLevel.info])));

    await _pump(t, _model(level: CardLevel.warn), theme: buildAppTheme(AppColors.karing));
    expect(_paintedColours(t), isNot(equals(painted[CardLevel.warn])));
  });

  testWidgets('a card with every block kind fits 320 px at 120 % text without overflow', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 800);
    addTearDown(t.view.reset);

    await _pump(
      t,
      _model(
        icon: Icons.dns,
        time: '23:59:59',
        repeats: 12,
        title: 'A rather long event title that has to wrap on a narrow phone screen',
        transition: ('Direct network', 'VPN network with a long name'),
        blocks: [
          SwitchFrame(
            heading: 'Changed with the network',
            rows: [
              SwitchRow(
                label: 'DNS server answers\nthrough the other side',
                from: ChipText(title: 'A long server name', sub: 'DoH'),
                to: ChipText(title: 'Beta', sub: 'DoT'),
              ),
            ],
          ),
          DataBox(
            rows: [
              CardSection(title: 'Checked through'),
              KeyRow(
                name: 'Node',
                value: 'a very long node name that has to wrap over several lines of text',
                sub: 'some subtitle words that go on',
                onTap: () {},
                onGo: () {},
              ),
              CheckRow(
                ok: false,
                value: 'no answer · no spare DNS on this side',
                sub: 'stays selected',
                onRetry: () {},
                onGo: () {},
              ),
              CheckRow(ok: true, value: 'answers', onGo: () {}),
            ],
          ),
        ],
        cause: ('Alpha itself', 'Beta answers through the same route, which is long enough to wrap'),
        actions: [
          CardAction(label: 'Details ▾', details: true, onTap: () {}),
          CardAction(label: 'DNS settings', onTap: () {}),
          CardAction(label: 'Ignore site ▾', onTap: () {}),
        ],
      ),
      textScale: 1.2,
    );

    expect(t.takeException(), isNull);
    expect(t.getSize(find.byType(EventCard)).width, lessThanOrEqualTo(320));
  });
}
