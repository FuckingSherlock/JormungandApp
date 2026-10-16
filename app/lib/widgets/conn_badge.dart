import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/gen/app_localizations_en.dart';
import '../theme/app_colors.g.dart';
import 'connect_dock.dart' show phaseTone;

/// Pill in Home's header: dot + state (`.conn-badge`). Tap = connect / disconnect.
class ConnBadge extends StatelessWidget {
  const ConnBadge({super.key, required this.phase, required this.onTap});

  final ConnectionPhase phase;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // the badge is a status word, the same in every language (user decision 2026-10-17)
    final l10n = AppLocalizationsEn();
    final tone = phaseTone(c, phase);
    // the grey "off" state is shown in the muted red of the mockup (.conn-badge.off)
    final color = phase == ConnectionPhase.disconnected ? c.muted : tone;
    final label = switch (phase) {
      ConnectionPhase.connected => l10n.connected,
      ConnectionPhase.connecting ||
      ConnectionPhase.disconnecting => l10n.connecting,
      ConnectionPhase.down => l10n.vpnIsDown,
      ConnectionPhase.disconnected => l10n.tapToConnect,
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.tint(.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.tint(.25)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(width: 6),
              DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const SizedBox(width: 6, height: 6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
