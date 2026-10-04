import 'dart:async';

import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../core/format.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';

/// The row of the dock (mockup `.dock-profile`): what is connected, or would be.
///
/// Top line: the kind (chain / profile / sub / file / set, or Simple / Profiles when there is no entry;
/// never translated, like the mockup's `data-notr`) and the entry's name. Under it: AUTO / MANUAL,
/// the protocol and server traffic leaves through (a chain: entry -> exit; a profile: its
/// subscription first), and on the right the latency in a frame.
class DockProfile extends StatelessWidget {
  const DockProfile({super.key, required this.summary, this.onTap});

  final DockSummary summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final s = summary;
    final name = s.hasEntry
        ? s.name
        : switch (s.none) {
            DockNone.nothingInAuto => l10n.nothingInAuto,
            DockNone.empty =>
              s.simpleMode ? l10n.noServersYet : l10n.noProfilesYet,
            null => '—',
          };
    return InkWell(
      onTap: onTap,
      highlightColor: c.t1.tint(.02),
      splashFactory: NoSplash.splashFactory,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        s.kind.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: .8,
                          color: c.t3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: c.t1,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _ModeBadge(auto: s.auto),
                      const SizedBox(width: 6),
                      Expanded(child: _Route(summary: s)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _LatencyBox(ms: s.latencyMs),
          ],
        ),
      ),
    );
  }
}

/// AUTO (active colour) / MANUAL (warn), `.proto-badge` with an inline tint.
class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.auto});

  final bool auto;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = auto ? c.active : c.warn;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.tint(.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          auto ? 'AUTO' : context.l10n.manual2,
          style: monoText.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// `.dock-route`: `PROTO  flag name`, a chain `PROTO  entry -> exit`, a profile
/// `PROTO  Source > name`; one line, clipped on the right.
class _Route extends StatelessWidget {
  const _Route({required this.summary});

  final DockSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final s = summary;
    const style = TextStyle(fontSize: 13);
    if (!s.hasEntry) {
      final text = s.none == DockNone.nothingInAuto
          ? l10n.turnOnUseInAutoIn
          : s.none == DockNone.empty
          ? (s.simpleMode ? l10n.addInNodes : l10n.createOneInNodes)
          : '';
      return _clip(Text(text, style: style.copyWith(color: c.t3)));
    }
    Widget node(DockNode? n) => n == null
        ? Text(
            l10n.noWorkingNode,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: c.t3),
          )
        : Text(
            '${n.flag} ${n.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: c.t2),
          );
    final exit = s.node;
    return ClipRect(
      child: Row(
        children: [
          if (exit != null) ...[
            Text(
              exit.protocol.toUpperCase(),
              style: monoText.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: c.t2,
              ),
            ),
            const SizedBox(width: 5),
          ],
          if (s.isChain) ...[
            Flexible(child: node(s.entryNode)),
            const SizedBox(width: 5),
            Text('→', style: style.copyWith(color: c.t3)),
            const SizedBox(width: 5),
            Flexible(child: node(exit)),
          ] else ...[
            if (s.sourceName != null) ...[
              Flexible(
                flex: 2,
                child: Text(
                  s.sourceName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.copyWith(color: c.t3),
                ),
              ),
              const SizedBox(width: 5),
              Text('›', style: style.copyWith(color: c.t3)),
              const SizedBox(width: 5),
            ],
            Flexible(flex: 3, child: node(exit)),
          ],
        ],
      ),
    );
  }

  Widget _clip(Widget child) =>
      Align(alignment: Alignment.centerLeft, child: child);
}

/// `.profiles-meta`: the latency in a thin accent frame (tap = ping the top servers, later).
// TODO(core-api): ping the top servers on a tap (`pingDockTop`) and run the light round the frame.
class _LatencyBox extends StatelessWidget {
  const _LatencyBox({required this.ms});

  final int? ms;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: monoSlot(context, 4, 15) + 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: c.accent.tint(.3), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(7, 2, 7, 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                ms == null ? '—' : '$ms',
                maxLines: 1,
                style: monoText.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.t1,
                ),
              ),
              Text('ms', style: monoText.copyWith(fontSize: 12, color: c.t2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// "VPN is down · 3 min · retrying" above the dock row; the minutes are refreshed every 15 s
/// (`setInterval(renderVpnAlert, 15000)`).
class DockDownLine extends StatefulWidget {
  const DockDownLine({super.key, required this.since});

  /// Epoch ms.
  final int since;

  @override
  State<DockDownLine> createState() => _DockDownLineState();
}

class _DockDownLineState extends State<DockDownLine> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ms = DateTime.now().millisecondsSinceEpoch - widget.since;
    final d = splitDuration(Duration(milliseconds: ms < 0 ? 0 : ms));
    final text = switch (d.unit) {
      DurationUnit.seconds => l10n.s(d.a),
      DurationUnit.minutes => l10n.min(d.a),
      DurationUnit.hoursMinutes => l10n.hMin(d.a, d.b),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Text(
        l10n.vpnIsDownRetrying(text),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.colors.danger,
        ),
      ),
    );
  }
}
