import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'settings_auto.dart';
import 'settings_dns.dart';

/// Home: the four NavCards, two per row - Auto mode and DNS open their sheets over Home, Rules
/// its screen (through [AppLinks.openRules]; the card is not shown when the shell has not wired
/// it), Speed Test only reports the last result (mockup `.row-nav`, markup/10-home.html).
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
    final speed = host.lastSpeedMbps;
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
      _NavCard(
        id: 'speed',
        icon: Icons.speed,
        color: c.purple,
        title: l10n.speedTest2,
        sub: speed == null
            ? l10n.noTestYet
            : l10n.lastMbps(speed.toStringAsFixed(0)),
      ),
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

class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    required this.sub,
    this.onTap,
  });

  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
            child: Icon(icon, size: 15, color: color),
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
                  maxLines: 1,
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
