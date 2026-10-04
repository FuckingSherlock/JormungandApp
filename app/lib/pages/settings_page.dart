import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../platform/platform_caps.dart';

import '../l10n/l10n.dart';
import '../state/app_settings.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_view.dart';
import '../widgets/settings_auto.dart';
import '../widgets/settings_conn.dart';
import '../widgets/settings_data.dart';
import '../widgets/settings_dns.dart';
import '../widgets/settings_look.dart';

/// Settings tab: a list of sections, each opening its own sheet (mockup markup/30-settings.html).
/// Auto mode, Appearance, General, Notifications, Connection, DNS, Data.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final host = CoreHostScope.of(context);
    final settings = AppSettingsScope.of(context);
    final rows = <_Entry>[
      _Entry(
        Icons.auto_mode,
        c.active,
        l10n.autoMode,
        l10n.failoverChecksSubscriptionUpdates,
        () => showAutoModeSheet(context),
        id: 'setauto',
      ),
      _Entry(
        Icons.contrast,
        c.accent,
        l10n.appearance,
        settings.theme.label,
        () => showAppearanceSheet(context),
        id: 'setlook',
      ),
      _Entry(
        Icons.settings_outlined,
        c.t2,
        l10n.general,
        generalSub(context, host),
        () => showGeneralSheet(context),
        id: 'setgeneral',
      ),
      _Entry(
        Icons.notifications_none,
        c.warn,
        l10n.notifications,
        notifSub(context, host),
        () => showNotifSheet(context),
        id: 'setnotif',
      ),
      _Entry(
        Icons.wifi,
        c.warn,
        l10n.connection,
        host.caps.systemProxy
            ? l10n.systemProxyKillSwitchTun
            : l10n.proxyPortTunStackTestUrl,
        () => showConnSheet(context),
        id: 'setconn',
      ),
      _Entry(
        Icons.layers_outlined,
        c.active,
        'DNS',
        dnsSettingsSub(context, host),
        () => showDnsSheet(context),
        id: 'setdns',
      ),
      _Entry(
        Icons.storage_outlined,
        c.purple,
        l10n.data,
        l10n.updatesBackupAbout,
        () => showDataSheet(context),
        id: 'setdata',
      ),
    ];
    return AppView(
      title: l10n.settings,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(c.radius),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
                  _MenuRow(entry: rows[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Entry {
  const _Entry(
    this.icon,
    this.color,
    this.label,
    this.sub,
    this.onTap, {
    required this.id,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String sub;
  final VoidCallback onTap;
  final String id;
}

/// `.settings-row` of the menu: a tinted icon square, the label with its sub line, a chevron.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.entry});

  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      key: ValueKey('settings-${entry.id}'),
      onTap: entry.onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: c.t1.tint(.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: entry.color.tint(.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(entry.icon, size: 18, color: entry.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: c.t1,
                    ),
                  ),
                  Text(
                    entry.sub,
                    style: TextStyle(fontSize: 12, color: c.t2),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.t3),
          ],
        ),
      ),
    );
  }
}
