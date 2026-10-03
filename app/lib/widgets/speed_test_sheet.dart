import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show CatalogNode;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'node_row.dart';

/// Nodes -> a server's more menu -> Speed test (mockup 38-speed.js). sing-box's own network
/// quality test through that server: idle latency first, then download and upload together,
/// the numbers growing as it measures (~20 s). Closing the sheet stops it.
Future<void> showSpeedTest(BuildContext context, CatalogNode n) {
  return showAppSheet<void>(context, builder: (_) => _SpeedSheet(node: n));
}

const _speedSeconds =
    20; // sing-box's default runtime; the progress line fills over it

String _fmtMbps(num? bps) {
  if (bps == null || bps <= 0) return '—';
  final m = bps / 1e6;
  return m >= 100 ? '${m.round()}' : m.toStringAsFixed(1);
}

/// 1 -> 1000 Mbps on a log scale.
double _speedFrac(num? bps) => bps == null || bps <= 0
    ? 0
    : math.min(1, math.log(1 + bps / 1e6) / math.ln10 / 3);

class _SpeedSheet extends StatefulWidget {
  const _SpeedSheet({required this.node});

  final CatalogNode node;

  @override
  State<_SpeedSheet> createState() => _SpeedSheetState();
}

class _SpeedSheetState extends State<_SpeedSheet> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic> _p = const {'phase': 0};
  bool _stopped = false;
  late DateTime _t0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // a first frame before the host is reachable through the scope
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  void _run() {
    _sub?.cancel();
    _t0 = DateTime.now();
    setState(() {
      _p = const {'phase': 0};
      _stopped = false;
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _p['final'] != true) setState(() {});
    });
    final host = CoreHostScope.read(context);
    _sub = host
        .speedTest(widget.node)
        .listen(
          (p) {
            if (mounted) setState(() => _p = p);
          },
          onError: (Object e) {
            if (mounted) {
              setState(() => _p = {..._p, 'final': true, 'error': '$e'});
            }
          },
          onDone: () {
            if (mounted && _p['final'] != true) {
              setState(
                () => _p = {
                  ..._p,
                  'final': true,
                  'error': context.l10n.theTestEndedWithoutAResult,
                },
              );
            }
          },
        );
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    setState(() {
      _stopped = true;
      _p = {..._p, 'final': true};
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  String _errText(String msg) {
    final l10n = context.l10n;
    if (RegExp(
      'timeout|timed out|deadline',
      caseSensitive: false,
    ).hasMatch(msg)) {
      return l10n.theServerDidNotAnswerIn;
    }
    if (RegExp('refused', caseSensitive: false).hasMatch(msg)) {
      return l10n.theServerRefusedTheConnection;
    }
    if (RegExp('no such host|lookup', caseSensitive: false).hasMatch(msg)) {
      return l10n.theServerAddressDoesNotResolve;
    }
    if (RegExp('reset|EOF|closed', caseSensitive: false).hasMatch(msg)) {
      return l10n.theServerDroppedTheConnection;
    }
    if (RegExp('cannot be tested', caseSensitive: false).hasMatch(msg)) {
      return msg;
    }
    return l10n.theTestCouldNotFinish;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final n = widget.node;
    final p = _p;
    final fin = p['final'] == true;
    final error = fin && !_stopped ? '${p['error'] ?? ''}' : '';
    final err = error.isNotEmpty;
    final done = fin && !err && !_stopped;
    final elapsed =
        (p['elapsed'] as num?) ?? DateTime.now().difference(_t0).inMilliseconds;
    final secs = (elapsed / 1000).round();
    final phase = (p['phase'] as num?) ?? 0;
    final down = p['down'] as num?;
    final up = p['up'] as num?;
    final latency = (p['latency'] as num?) ?? 0;
    final rpm = (p['downRpm'] as num?) ?? 0;
    final frac = fin
        ? (done ? 1.0 : math.min(1.0, secs / _speedSeconds))
        : math.min(.97, secs / _speedSeconds);
    final status = err
        ? l10n.testFailed
        : _stopped
        ? l10n.stopped
        : done
        ? l10n.done
        : phase == 0
        ? l10n.measuringLatency
        : l10n.measuringSpeed;
    final why = err ? _errText(error) : '';

    return SheetFrame(
      title: l10n.speedTest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(n.flag, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    n.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.t1,
                    ),
                  ),
                ),
                Text(
                  nodeProtoLabel(n),
                  style: monoText.copyWith(fontSize: 11, color: c.t3),
                ),
              ],
            ),
            // TODO(ui): the mockup draws two animated rings (download outer, upload inner);
            // the painter below is a plain version of the same gauge.
            SizedBox(
              height: 168,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GaugePainter(
                        down: _speedFrac(down),
                        up: _speedFrac(up),
                        track: c.border,
                        downColor: err ? c.muted : c.accent,
                        upColor: err ? c.muted : c.purple,
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _fmtMbps(down),
                        style: monoText.copyWith(
                          fontSize: 38,
                          fontWeight: FontWeight.w700,
                          color: c.t1,
                        ),
                      ),
                      Text(
                        'Mbps',
                        style: monoText.copyWith(fontSize: 12, color: c.t2),
                      ),
                      const SizedBox(height: 2),
                      _Dot(color: c.accent, label: l10n.download),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _Stat(
                  value: _fmtMbps(up),
                  unit: 'Mbps',
                  label: _Dot(color: c.purple, label: l10n.upload),
                ),
                _Stat(
                  value: latency > 0 ? '$latency' : '—',
                  unit: 'ms',
                  label: Text(l10n.latency),
                ),
                _Stat(
                  value: rpm > 0 ? '$rpm' : '—',
                  unit: 'RPM',
                  label: Text(l10n.responsiveness),
                  word: rpm > 0
                      ? (rpm >= 1000
                            ? (l10n.high, c.active)
                            : rpm >= 300
                            ? (l10n.medium, c.t2)
                            : (l10n.low, c.danger))
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: err ? c.danger : c.t2,
                    ),
                  ),
                ),
                if (secs > 0)
                  Text(
                    '$secs s',
                    style: monoText.copyWith(fontSize: 12, color: c.t3),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: frac.toDouble(),
                minHeight: 4,
                backgroundColor: c.border,
                color: err ? c.danger : c.accent,
              ),
            ),
            if (err) ...[
              const SizedBox(height: 10),
              Text(
                why,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.t1,
                ),
              ),
              if (why != error)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    error,
                    style: monoText.copyWith(fontSize: 11, color: c.t3),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.theServerMayBeDownRight,
                  style: TextStyle(fontSize: 12, color: c.t2),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Center(
              child: SecondaryButton(
                label: fin ? l10n.runAgain : l10n.stop,
                icon: fin ? Icons.refresh : Icons.close,
                onPressed: fin ? _run : _stop,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(fontSize: 12, color: context.colors.t2)),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.value,
    required this.unit,
    required this.label,
    this.word,
  });

  final String value;
  final String unit;
  final Widget label;
  final (String, Color)? word;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: monoText.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.t1,
                ),
              ),
              const SizedBox(width: 3),
              Text(unit, style: monoText.copyWith(fontSize: 10, color: c.t3)),
            ],
          ),
          const SizedBox(height: 2),
          DefaultTextStyle.merge(
            style: TextStyle(fontSize: 12, color: c.t2),
            textAlign: TextAlign.center,
            child: label,
          ),
          if (word != null)
            Text(
              word!.$1,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: word!.$2,
              ),
            ),
        ],
      ),
    );
  }
}

/// Two 240-degree arcs (outer download, inner upload), like `speedArc` of the mockup.
class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.down,
    required this.up,
    required this.track,
    required this.downColor,
    required this.upColor,
  });

  final double down;
  final double up;
  final Color track;
  final Color downColor;
  final Color upColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 110 / 168);
    void ring(double r, double frac, Color color) {
      final rect = Rect.fromCircle(center: center, radius: r);
      const start = math.pi * 5 / 6; // 150 degrees, clockwise to 30 degrees
      const sweep = math.pi * 4 / 3;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, start, sweep, false, paint..color = track);
      if (frac > 0) {
        canvas.drawArc(rect, start, sweep * frac, false, paint..color = color);
      }
    }

    ring(96, down, downColor);
    ring(80, up, upColor);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.down != down ||
      old.up != up ||
      old.track != track ||
      old.downColor != downColor ||
      old.upColor != upColor;
}
