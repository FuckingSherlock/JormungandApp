import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show VpnDot, VpnLine, VpnMark;

import '../theme/app_colors.g.dart';

/// The VPN line left of an Events row (docs/logs.md «Линия VPN»): the upper half is the state before the event, the
/// lower half the state after it. A dot where the state changed (its colour is the new state), a ring where the VPN
/// reconnected (the line goes through it). Fixed width; the height is the row's (the parent gives it tight constraints).
class VpnRail extends StatelessWidget {
  const VpnRail(this.mark, {super.key});

  static const double width = 14;

  /// Null: nothing is drawn.
  final VpnMark? mark;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: width,
      child: CustomPaint(
        painter: _RailPainter(
          mark,
          onColor: c.active,
          downColor: c.danger,
          waitingColor: c.warn,
          offColor: c.t3,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter(
    this.mark, {
    required this.onColor,
    required this.downColor,
    required this.waitingColor,
    required this.offColor,
  });

  final VpnMark? mark;
  final Color onColor, downColor, waitingColor, offColor;

  Color _tone(VpnLine s) => switch (s) {
    VpnLine.on => onColor,
    VpnLine.down => downColor,
    VpnLine.waiting => waitingColor,
    VpnLine.off => offColor,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final m = mark;
    if (m == null) return;
    final x = size.width / 2, mid = size.height / 2;
    _half(canvas, x, 0, mid, m.above);
    _half(canvas, x, mid, size.height, m.below);
    final centre = Offset(x, mid);
    switch (m.dot) {
      case VpnDot.none:
        break;
      case VpnDot.change:
        canvas.drawCircle(centre, 4, Paint()..color = _tone(m.below));
      case VpnDot.reconnect:
        canvas.drawCircle(
          centre,
          3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = _tone(m.below),
        );
    }
  }

  /// One half of the line: solid in the state's colour; "off" is a dashed grey (t3) line.
  void _half(Canvas canvas, double x, double top, double bottom, VpnLine s) {
    final p = Paint()
      ..color = _tone(s)
      ..strokeWidth = 2;
    if (s != VpnLine.off) {
      canvas.drawLine(Offset(x, top), Offset(x, bottom), p);
      return;
    }
    for (var y = top; y < bottom; y += 6) {
      canvas.drawLine(Offset(x, y), Offset(x, y + 3 > bottom ? bottom : y + 3), p);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      !_sameMark(old.mark, mark) ||
      old.onColor != onColor ||
      old.downColor != downColor ||
      old.waitingColor != waitingColor ||
      old.offColor != offColor;
}

bool _sameMark(VpnMark? a, VpnMark? b) =>
    identical(a, b) ||
    a != null && b != null && a.above == b.above && a.below == b.below && a.dot == b.dot;
