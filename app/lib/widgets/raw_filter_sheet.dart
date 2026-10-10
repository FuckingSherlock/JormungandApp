import 'package:flutter/material.dart';

import '../core/logs_controller.dart';
import '../l10n/l10n.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'log_parts.dart';

/// The sheet of the filter button on the Raw tab: the level, the switch for the lines of successful
/// connections (hidden by default: thousands a minute, the core does not even send them), the
/// failed-connection lines of ignored sites, Reset. The search is in the header of the page.
Future<void> showRawFilter(BuildContext context, LogsController logs) {
  return showAppSheet<void>(
    context,
    builder: (sheet) => _RawFilterSheet(logs: logs),
  );
}

class _RawFilterSheet extends StatelessWidget {
  const _RawFilterSheet({required this.logs});

  final LogsController logs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SheetFrame(
      title: l10n.filterLog,
      child: ListenableBuilder(
        listenable: logs,
        builder: (context, _) {
          final conns = logs.cfg.showConns;
          final ign = logs.cfg.showIgnored;
          final ignored = logs.ignoredLineCount;
          // the badges count what the filter below lets through, as the list will show it
          final unread = [
            for (final x in logs.unreadLines)
              if ((conns || !x.isConn) && (ign || !logs.raw.isIgnored(x))) x,
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FormGroup(
                label: l10n.level,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    LevelChip(
                      key: const ValueKey('rawLevelAll'),
                      label: l10n.all,
                      active: logs.rawLevel == 'all',
                      unread: unread,
                      onTap: () => logs.setRawLevel('all'),
                    ),
                    LevelChip(
                      key: const ValueKey('rawLevelWarn'),
                      label: l10n.warningsErrors,
                      active: logs.rawLevel == 'warn',
                      unread: [for (final x in unread) if (x.lvl == 'warn' || x.lvl == 'error') x],
                      onTap: () => logs.setRawLevel('warn'),
                    ),
                  ],
                ),
              ),
              SetGroup(
                children: [
                  SetRow(
                    key: const ValueKey('rawConns'),
                    label: l10n.connections,
                    hint: l10n.successfulConnectionsOneLinePerConnectio,
                    onTap: () => logs.setShowConns(!conns),
                    trailing: MiniToggle(on: conns, onChanged: logs.setShowConns),
                  ),
                  // only while the list holds such lines (or the switch is on, to be able to turn it off)
                  if (ignored > 0 || ign)
                    SetRow(
                      key: const ValueKey('rawIgnored'),
                      label: l10n.fromIgnoredSites(ignored),
                      onTap: () => logs.setShowIgnored(!ign),
                      trailing: MiniToggle(on: ign, onChanged: logs.setShowIgnored),
                    ),
                ],
              ),
              if (logs.rawFilterCount > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SecondaryButton(
                      key: const ValueKey('rawFilterReset'),
                      label: l10n.reset,
                      onPressed: logs.resetRawFilter,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
