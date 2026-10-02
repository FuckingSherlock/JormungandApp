import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'dock_paths.g.dart';

/// Colour of the power button / connection badge per phase: connected = active, busy = accent,
/// down = danger, off = grey (`.power-tab.on / .busy / .down` in css/50-dock.css).
Color phaseTone(AppColors c, ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.connected => c.active,
  ConnectionPhase.connecting || ConnectionPhase.disconnecting => c.accent,
  ConnectionPhase.down => c.danger,
  ConnectionPhase.disconnected => c.t2,
};

/// Bottom dock of Home: the power tab rising out of the top edge + the active profile row.
///
/// The tab is 200 x 52 and overhangs the dock by 50 px, so the dock is laid out 50 px taller than
/// its visible body (the transparent top part lets touches through to the page behind). Home's
/// scroll area keeps a 60 px bottom padding for it, like `#view-home > .scroll`.
class ConnectDock extends StatelessWidget {
  const ConnectDock({super.key});

  static const double tabOverhang = 50;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final host = CoreHostScope.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: tabOverhang),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: const DockProfile(),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(
            child: PowerTab(
              phase: host.phase,
              onPressed: () =>
                  host.isConnected ? host.disconnect() : host.connect(),
            ),
          ),
        ),
      ],
    );
  }
}

/// The trapezoid tab with the hexagon power button (shapes: dock_paths.g.dart, from geometry.mjs).
class PowerTab extends StatelessWidget {
  const PowerTab({super.key, required this.phase, required this.onPressed});

  final ConnectionPhase phase;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tone = phaseTone(c, phase);
    return Semantics(
      button: true,
      label: context.l10n.connectDisconnect,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: DockGeometry.width,
          height: DockGeometry.height,
          child: CustomPaint(
            painter: _DockShapePainter(colors: c, phase: phase),
            child: Align(
              alignment: Alignment.topCenter,
              // 14.5 px from the top in the mockup (.power-icon), 22 px icon
              child: Padding(
                padding: const EdgeInsets.only(
                  top: DockGeometry.iconCenterY - 11,
                ),
                child: Icon(Icons.power_settings_new, size: 22, color: tone),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockShapePainter extends CustomPainter {
  _DockShapePainter({required this.colors, required this.phase});

  final AppColors colors;
  final ConnectionPhase phase;

  static final Path _frameFill = DockGeometry.frameFill();
  static final Path _frameLine = DockGeometry.frameLine();
  static final List<Path> _bodies = [
    DockGeometry.powerHex(),
    DockGeometry.powerWedgeL(),
    DockGeometry.powerWedgeR(),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(_frameFill, Paint()..color = colors.surface);
    canvas.drawPath(
      _frameLine,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.border,
    );
    final off = phase == ConnectionPhase.disconnected;
    final tone = phaseTone(colors, phase);
    final fill = Paint()
      ..color = off
          ? colors.card
          : tone.tint(phase == ConnectionPhase.connecting ? .12 : .14);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = off ? colors.borderHi : tone;
    for (final p in _bodies) {
      canvas.drawPath(p, fill);
      canvas.drawPath(p, stroke);
    }
  }

  @override
  bool shouldRepaint(_DockShapePainter old) =>
      old.colors != colors || old.phase != phase;
}

/// Active profile line of the dock (mockup `.dock-profile`: Simple / Profiles label, name, mode
/// badge, node count). Stub.
class DockProfile extends StatelessWidget {
  const DockProfile({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // TODO(core-api): the active entry (Simple / Profile / Chain) and its mode from the core.
                Text(
                  context.l10n.simple.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .6,
                    color: c.t3,
                  ),
                ),
                Text(
                  '-',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: c.t1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
