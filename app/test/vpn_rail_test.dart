// VpnRail (docs/logs.md «Линия VPN»): the fixed-width line left of an Events row. Its upper half is coloured by
// `above`, its lower half by `below`: on = success, down = error, waiting = warning, off = grey (t3) and dashed. A
// change is a filled dot in the colour of `below`, a reconnect is a ring, no dot draws nothing. The rail is read
// as pixels of a RepaintBoundary, so the test does not depend on how the rail is built.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/theme/app_colors.g.dart';
import 'package:jormungand/widgets/vpn_rail.dart';
import 'package:jormungand_core/jormungand_core.dart';

/// Height the rail is laid out at: long enough for a dash pattern and a dot inside each half.
const double _h = 200;

/// Row ranges inside the rail: the halves without their ends, and the middle where a dot sits.
const int _upperY0 = 10, _upperY1 = 90;
const int _lowerY0 = 110, _lowerY1 = 190;

final AppColors _c = AppThemeId.original.colors;

/// The colour of a line state in theme [c]; null for off, which is grey (t3) and dashed.
Color? _colorOf(VpnLine l, AppColors c) => switch (l) {
  VpnLine.on => c.active,
  VpnLine.down => c.danger,
  VpnLine.waiting => c.warn,
  VpnLine.off => null,
};

int _ch(double v) => (v * 255).round();

int _key(Color c) => (_ch(c.r) << 16) | (_ch(c.g) << 8) | _ch(c.b);

/// The rail as RGBA pixels. Only pixels with alpha >= 128 count as drawn.
class _Img {
  _Img(this.width, this.height, this.px);

  final int width;
  final int height;
  final Uint8List px;

  int _keyAt(int x, int y) {
    final i = (y * width + x) * 4;
    return (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
  }

  bool _drawn(int x, int y) => px[(y * width + x) * 4 + 3] >= 128;

  bool _is(int x, int y, Color c) => _drawn(x, y) && _keyAt(x, y) == _key(c);

  /// Pixels of row [y] painted in colour [c].
  int countMatching(int y, Color c) {
    var n = 0;
    for (var x = 0; x < width; x++) {
      if (_is(x, y, c)) n++;
    }
    return n;
  }

  /// Pixels of row [y] painted in any colour.
  int drawnCount(int y) {
    var n = 0;
    for (var x = 0; x < width; x++) {
      if (_drawn(x, y)) n++;
    }
    return n;
  }

  /// How many separate runs of colour [c] row [y] has.
  int runs(int y, Color c) {
    var runs = 0;
    var inRun = false;
    for (var x = 0; x < width; x++) {
      final m = _is(x, y, c);
      if (m && !inRun) runs++;
      inRun = m;
    }
    return runs;
  }

  /// How many separate runs of drawn pixels, in any colour, row [y] has.
  int drawnRuns(int y) {
    var runs = 0;
    var inRun = false;
    for (var x = 0; x < width; x++) {
      final d = _drawn(x, y);
      if (d && !inRun) runs++;
      inRun = d;
    }
    return runs;
  }

  /// The most common colour key among drawn pixels of rows [y0, y1), or null if nothing is drawn.
  int? dominant(int y0, int y1) {
    final counts = <int, int>{};
    for (var y = y0; y < y1; y++) {
      for (var x = 0; x < width; x++) {
        if (_drawn(x, y)) counts.update(_keyAt(x, y), (n) => n + 1, ifAbsent: () => 1);
      }
    }
    if (counts.isEmpty) return null;
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}

/// Lays the rail out at [_h] inside a RepaintBoundary, in theme [colors], and reads its pixels.
Future<_Img> _capture(WidgetTester tester, VpnMark? mark, AppColors colors) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(colors),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: _h,
            child: RepaintBoundary(key: key, child: VpnRail(mark)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle(); // a theme switch animates the colours; read them once it has settled
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  return _Img(image.width, image.height, data.buffer.asUint8List());
}

/// One half of the line: a solid line in the state's colour on every row, or for off a t3 line with a gap.
void _expectHalf(_Img img, int y0, int y1, VpnLine line, AppColors c) {
  final color = _colorOf(line, c);
  if (color != null) {
    for (var y = y0; y < y1; y++) {
      expect(img.countMatching(y, color), greaterThan(0), reason: 'row $y is not ${line.name}');
    }
    return;
  }
  expect(img.dominant(y0, y1), _key(c.t3), reason: 'off is drawn in t3 (grey), not muted');
  final hasGap = [for (var y = y0; y < y1; y++) img.drawnCount(y)].any((n) => n == 0);
  expect(hasGap, isTrue, reason: 'off is dashed: a gap with nothing drawn');
}

void main() {
  // Each state shows in both halves across these pairs (above, below).
  const halves = <(VpnLine, VpnLine)>[
    (VpnLine.on, VpnLine.down),
    (VpnLine.waiting, VpnLine.on),
    (VpnLine.on, VpnLine.waiting),
    (VpnLine.off, VpnLine.down),
    (VpnLine.down, VpnLine.off),
  ];
  for (final (above, below) in halves) {
    testWidgets('halves: ${above.name} above, ${below.name} below, no dot', (tester) async {
      final img = await _capture(tester, VpnMark(above, below, VpnDot.none), _c);
      _expectHalf(img, _upperY0, _upperY1, above, _c);
      _expectHalf(img, _lowerY0, _lowerY1, below, _c);
    });
  }

  // Colours come from the theme, not a fixed hex: every theme draws its own on / down / waiting / off.
  const themePairs = <(VpnLine, VpnLine)>[(VpnLine.on, VpnLine.down), (VpnLine.waiting, VpnLine.off)];
  for (final id in AppThemeId.values) {
    testWidgets('line colours come from the theme: ${id.name}', (tester) async {
      for (final (above, below) in themePairs) {
        final img = await _capture(tester, VpnMark(above, below, VpnDot.none), id.colors);
        _expectHalf(img, _upperY0, _upperY1, above, id.colors);
        _expectHalf(img, _lowerY0, _lowerY1, below, id.colors);
      }
    });
  }

  testWidgets('line follows a theme switch in the same tree', (tester) async {
    for (final id in AppThemeId.values.reversed) {
      for (final (above, below) in themePairs) {
        final img = await _capture(tester, VpnMark(above, below, VpnDot.none), id.colors);
        _expectHalf(img, _upperY0, _upperY1, above, id.colors);
        _expectHalf(img, _lowerY0, _lowerY1, below, id.colors);
      }
    }
  });

  // A change dot is filled in the colour of `below` and adds nothing in the colour of `above`.
  const dotPairs = <(VpnLine, VpnLine)>[
    (VpnLine.on, VpnLine.down),
    (VpnLine.down, VpnLine.on),
    (VpnLine.on, VpnLine.waiting),
  ];
  for (final (above, below) in dotPairs) {
    testWidgets('change dot is filled in the colour of below: ${above.name} to ${below.name}', (tester) async {
      final ca = _colorOf(above, _c)!;
      final cb = _colorOf(below, _c)!;
      final base = await _capture(tester, VpnMark(above, below, VpnDot.none), _c);
      final dot = await _capture(tester, VpnMark(above, below, VpnDot.change), _c);
      final grown = [
        for (var y = 0; y < _h; y++)
          if (dot.countMatching(y, cb) > base.countMatching(y, cb)) y,
      ];
      expect(grown, isNotEmpty, reason: 'the dot adds pixels in the colour of below');
      final grownAbove = [
        for (var y = 0; y < _h; y++)
          if (dot.countMatching(y, ca) > base.countMatching(y, ca)) y,
      ];
      expect(grownAbove, isEmpty, reason: 'the dot is not in the colour of above');
    });
  }

  testWidgets('reconnect is a ring the line passes through; change is a filled dot', (tester) async {
    final ring = await _capture(tester, VpnMark(VpnLine.on, VpnLine.on, VpnDot.reconnect), _c);
    final dot = await _capture(tester, VpnMark(VpnLine.on, VpnLine.on, VpnDot.change), _c);
    bool hasHole(_Img img) => [for (var y = 0; y < _h; y++) img.drawnRuns(y)].any((r) => r > 1);
    expect(hasHole(ring), isTrue, reason: 'a ring leaves a gap inside it');
    expect(hasHole(dot), isFalse, reason: 'a filled dot leaves no gap');
  });

  testWidgets('no dot draws nothing: one line of the same width on every row', (tester) async {
    final img = await _capture(tester, VpnMark(VpnLine.on, VpnLine.on, VpnDot.none), _c);
    final counts = <int>{};
    for (var y = _upperY0; y < _lowerY1; y++) {
      expect(img.runs(y, _c.active), 1, reason: 'row $y');
      counts.add(img.countMatching(y, _c.active));
    }
    expect(counts, hasLength(1));
  });

  testWidgets('the rail has one fixed width for every mark, null included', (tester) async {
    final marks = <VpnMark?>[
      null,
      const VpnMark(VpnLine.on, VpnLine.on, VpnDot.none),
      const VpnMark(VpnLine.down, VpnLine.waiting, VpnDot.change),
      const VpnMark(VpnLine.off, VpnLine.on, VpnDot.reconnect),
      const VpnMark(VpnLine.waiting, VpnLine.off, VpnDot.none),
    ];
    final widths = <double>{};
    for (final m in marks) {
      await _capture(tester, m, _c);
      widths.add(tester.getSize(find.byType(VpnRail)).width);
    }
    expect(widths, hasLength(1));
    expect(widths.single, greaterThan(0));
  });
}
