import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';

/// Home's `.segments-card`: Mode (TUN | Proxy), Route (Global | Rules) and, on desktop, the
/// system proxy (its name over On | Off). Two options each, so a tap anywhere flips the control.
class SegmentsCard extends StatelessWidget {
  const SegmentsCard({super.key, required this.host});

  final CoreHost host;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: SegmentControl(
              // 'TUN' and 'Proxy' are names of the modes, the mockup does not translate them
              first: 'TUN',
              second: 'Proxy',
              firstActive: host.tun,
              pill: host.tun ? c.active : c.accent,
              // Android is always the VPN (TUN): nothing to switch
              onTap: host.isAndroid ? null : () => host.setTun(!host.tun),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SegmentControl(
              first: l10n.global,
              second: l10n.rules,
              firstActive: host.global,
              pill: c.accent,
              onTap: () => host.setGlobal(!host.global),
            ),
          ),
          if (!host.isAndroid) ...[
            const SizedBox(width: 10),
            Expanded(
              child: SegmentControl(
                title: 'Sys proxy',
                first: l10n.onText,
                second: l10n.off,
                firstActive: host.sysProxy,
                pill: c.accent,
                onTap: () => host.setSysProxy(!host.sysProxy),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// `.segment-control`: two options with a pill under the active one that slides over
/// (`.28s`). Without [title] they are stacked (the pill moves up and down); with it the name
/// takes the top half and the options sit side by side below (`.seg-split`).
class SegmentControl extends StatelessWidget {
  const SegmentControl({
    super.key,
    required this.first,
    required this.second,
    required this.firstActive,
    required this.pill,
    this.title,
    this.onTap,
  });

  final String first;
  final String second;
  final bool firstActive;
  final Color pill;
  final String? title;
  final VoidCallback? onTap;

  static const Duration slide = Duration(milliseconds: 280);
  static const Curve curve = Cubic(.65, 0, .35, 1);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final split = title != null;
    final onPill = Theme.of(context).colorScheme.onPrimary;
    Widget label(String text, bool active) => Center(
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 200),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: active ? onPill : c.t2,
        ),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    final Widget options;
    if (split) {
      options = Column(
        children: [
          Expanded(
            child: Center(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.t2,
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                AnimatedAlign(
                  duration: slide,
                  curve: curve,
                  alignment: firstActive
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: FractionallySizedBox(
                    widthFactor: .5,
                    heightFactor: 1,
                    child: _Pill(color: pill),
                  ),
                ),
                Row(
                  children: [
                    Expanded(child: label(first, firstActive)),
                    Expanded(child: label(second, !firstActive)),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      options = Stack(
        children: [
          AnimatedAlign(
            duration: slide,
            curve: curve,
            alignment: firstActive
                ? Alignment.topCenter
                : Alignment.bottomCenter,
            child: FractionallySizedBox(
              widthFactor: 1,
              heightFactor: .5,
              child: _Pill(color: pill),
            ),
          ),
          Column(
            children: [
              Expanded(child: label(first, firstActive)),
              Expanded(child: label(second, !firstActive)),
            ],
          ),
        ],
      );
    }
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? .6 : 1,
          child: Container(
            height: 76,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: c.t1.tint(.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: options,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}
