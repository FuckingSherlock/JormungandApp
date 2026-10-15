import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart' show showToast;
import 'settings_auto.dart';
import 'settings_dns.dart';

/// Home: the four NavCards, two per row - Auto mode and DNS open their sheets over Home, Rules
/// its screen (through [AppLinks.openRules]; the card is not shown when the shell has not wired
/// it), Speed Test tests the running connection and keeps the last result (mockup `.row-nav`,
/// markup/10-home.html; the test itself is Flutter's first, docs/connect-model.md).
class NavCards extends StatelessWidget {
  const NavCards({super.key, required this.host});

  final CoreHost host;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final links = AppLinksScope.of(context);
    final openRules = links.openRules;
    final cat = host.catalog;
    final active = cat.ruleOrder
        .where((id) => cat.rulesData[id]?.enabled ?? false)
        .length;
    final q = cat.quickCfg;
    final rulesSub =
        '${l10n.rulesPlural(active)}'
        '${q.regionOn ? ' · ${l10n.direct2(q.region)}' : ''}';
    final cards = <Widget>[
      _NavCard(
        id: 'auto',
        icon: Icons.psychology_outlined,
        color: c.active,
        title: l10n.autoMode,
        sub: autoCardSub(context, host),
        onTap: () => showAutoModeSheet(context),
      ),
      if (openRules != null)
        _NavCard(
          id: 'rules',
          icon: Icons.format_list_bulleted,
          color: c.warn,
          title: l10n.rules,
          sub: rulesSub,
          onTap: () => openRules(),
        ),
      _NavCard(
        id: 'dns',
        icon: Icons.dns_outlined,
        color: c.active,
        title: 'DNS',
        sub: dnsCardSub(context, host),
        onTap: () => showDnsSheet(context),
      ),
      _speedCard(context),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [for (final card in cards) SizedBox(width: w, child: card)],
        );
      },
    );
  }
}

extension on NavCards {
  /// Speed Test: a tap tests the running connection (the main flow); while it runs the ring on the
  /// icon fills over sing-box's ~20 s and a tap stops it; the last result stays on the card.
  Widget _speedCard(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final testing = host.speedTesting;
    final connected = host.phase == ConnectionPhase.connected;
    final last = host.lastSpeed;
    String mbps(double v) => v >= 100 ? '${v.round()}' : v.toStringAsFixed(1);
    var sub = l10n.noTestYet;
    var lines = 1;
    double? progress;
    if (testing) {
      final p = host.speedProgress;
      final phase = (p['phase'] as num?)?.toInt() ?? 0;
      final down = (p['down'] as num?) ?? 0, up = (p['up'] as num?) ?? 0;
      sub = phase == 0 || (down <= 0 && up <= 0)
          ? l10n.measuringLatency
          : l10n.speedTestMbps(mbps(down / 1e6), mbps(up / 1e6));
      final elapsed = (p['elapsed'] as num?)?.toDouble() ?? 0;
      progress = (elapsed / 20000).clamp(0.03, 0.97);
    } else if (host.speedError != null) {
      sub = l10n.testFailed;
    } else if (last != null) {
      final m = MaterialLocalizations.of(context);
      final day = DateTime.now().difference(last.at).inHours >= 20
          ? '${m.formatShortDate(last.at)} '
          : '';
      final time =
          '$day${m.formatTimeOfDay(TimeOfDay.fromDateTime(last.at), alwaysUse24HourFormat: true)}';
      sub =
          '↓ ${mbps(last.downMbps)} · ↑ ${mbps(last.upMbps)} Mbps\n'
          '${last.latencyMs > 0 ? '${last.latencyMs}ms ·' : ''}$time';
      lines = 2;
    }
    return _NavCard(
      id: 'speed',
      icon: Icons.speed,
      color: c.purple,
      title: l10n.speedTest2,
      sub: sub,
      subLines: lines,
      busy: testing,
      progress: progress,
      dim: !connected && !testing,
      onTap: () {
        if (!testing && !connected) {
          showToast(context, l10n.connectFirst);
          return;
        }
        host.toggleSpeedTest();
      },
    );
  }
}

class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    required this.sub,
    this.onTap,
    this.subLines = 1,
    this.dim = false,
    this.progress,
    this.busy = false,
  });

  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String sub;
  final VoidCallback? onTap;
  final int subLines;

  /// Drawn faded: the card cannot do its job now (still tappable, the tap explains).
  final bool dim;

  /// The card is working: a ring runs round its icon (0..1, null = unknown).
  final double? progress;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final glyph = busy
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              key: ValueKey('nav-$id-progress'),
              strokeWidth: 2,
              value: progress,
              color: color,
              backgroundColor: color.withValues(alpha: .2),
            ),
          )
        : Icon(icon, size: 15, color: color);
    return Opacity(
      opacity: dim ? .55 : 1,
      child: _card(c, glyph),
    );
  }

  Widget _card(AppColors c, Widget glyph) {
    return AppCard(
      key: ValueKey('nav-$id'),
      padding: const EdgeInsets.all(10),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Center(child: glyph),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 18 / 14,
                    fontWeight: FontWeight.w600,
                    color: c.t1,
                  ),
                ),
                Text(
                  sub,
                  maxLines: subLines,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 16 / 12, color: c.t2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
