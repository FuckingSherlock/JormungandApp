import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show IgnoredSites;

import '../core/logs_controller.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'report_actions.dart';
import 'rules_parts.dart' show ChevronRow;

/// Ignored sites (the filter sheets of Logs): a site that is dead by itself and that some program keeps opening
/// floods the journal, the toasts and the raw log; the host and its subdomains can be silenced.
/// Only what is shown changes, routing never looks at the list. The list lives in
/// `notifCfg.ignoredSites`, the [LogsController] edits it.

/// «Ignore site» on an event / toast / notification: adds [site] and confirms with a toast
/// «host ignored · Undo». [messenger] is the shell's, so the toast outlives the row that asked.
void ignoreSiteWithUndo(
  ScaffoldMessengerState messenger,
  AppLocalizations l10n,
  LogsController logs,
  String site,
) {
  final h = logs.ignoreSite(site);
  // already ignored (or not a host): nothing to undo
  final shown = h ?? IgnoredSites.clean(site);
  if (shown.isEmpty) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(l10n.ignored(shown)),
        // a SnackBar with an action stays until dismissed by default (persist): this one goes by itself
        persist: false,
        duration: const Duration(seconds: 6),
        action: h == null
            ? null
            : SnackBarAction(
                label: l10n.undo,
                // the default (inversePrimary) does not read on the toast's light background
                textColor: Theme.of(messenger.context).colorScheme.onInverseSurface,
                onPressed: () => logs.unignoreSite(h),
              ),
      ),
    );
}

/// The list with add / remove / clear: opened from the row in the filter sheets of both tabs
/// ([IgnoredSitesRow]); a setting of its own, not part of what the filter counts or Reset clears.
Future<void> showIgnoredSites(BuildContext context, LogsController logs) =>
    showAppSheet<void>(context, builder: (_) => _IgnoredSitesSheet(logs: logs));

/// «Ignored sites» as a row of a filter sheet: the first sites (or «None») under the label, a
/// chevron into the list. Lives beside the filter's own switches, apart from them (it is kept
/// with the settings, a Reset does not touch it).
class IgnoredSitesRow extends StatelessWidget {
  const IgnoredSitesRow({super.key, required this.logs});

  final LogsController logs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sites = logs.ignoredSites;
    return ChevronRow(
      key: const ValueKey('ignoredSitesRow'),
      label: l10n.ignoredSites,
      hint: sites.isEmpty ? l10n.none : '${sites.take(3).join(', ')}${sites.length > 3 ? ' …' : ''}',
      onTap: () => showIgnoredSites(context, logs),
    );
  }
}

class _IgnoredSitesSheet extends StatefulWidget {
  const _IgnoredSitesSheet({required this.logs});

  final LogsController logs;

  @override
  State<_IgnoredSitesSheet> createState() => _IgnoredSitesSheetState();
}

class _IgnoredSitesSheetState extends State<_IgnoredSitesSheet> {
  final _input = TextEditingController();
  String? _error;

  LogsController get _logs => widget.logs;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    final l10n = context.l10n;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final h = IgnoredSites.clean(text);
    if (h.isEmpty) {
      setState(() => _error = l10n.enterASiteLikeExampleCom);
    } else if (_logs.ignoredSites.contains(h)) {
      setState(() => _error = l10n.isAlreadyInTheList(h));
    } else {
      _logs.ignoreSite(h);
      _input.clear();
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    return ListenableBuilder(
      listenable: _logs,
      builder: (context, _) {
        final sites = _logs.ignoredSites;
        return SheetFrame(
          title: l10n.ignoredSites,
          footer: sites.isEmpty
              ? null
              : [
                  DangerTextButton(
                    label: l10n.clearAll,
                    onPressed: _logs.clearIgnored,
                  ),
                ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MenuNote(l10n.noEventsNotificationsOrFailedRequest),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: AppTextField(
                        key: const ValueKey('ignoredSiteInput'),
                        controller: _input,
                        hint: l10n.exampleCom,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SecondaryButton(label: l10n.add2, onPressed: _add),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 13, color: c.warn),
                  ),
                ),
              if (sites.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    l10n.noIgnoredSites,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: c.t3),
                  ),
                )
              else
                for (final h in sites)
                  Padding(
                    key: ValueKey('ignored:$h'),
                    padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            h,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, color: c.t1),
                          ),
                        ),
                        IconBtn(
                          tooltip: l10n.remove,
                          kind: IconBtnKind.ghost,
                          onTap: () => _logs.unignoreSite(h),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// Clear on the Events tab asks first (what a journal is worth is not undone).
Future<void> confirmClearEvents(BuildContext context, LogsController logs) {
  final l10n = context.l10n;
  return showAppSheet<void>(
    context,
    builder: (sheet) => SheetFrame(
      title: l10n.clearEvents2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MenuNote(l10n.theEventsListIsEmptiedThe),
          MenuRow(
            icon: const Icon(Icons.delete_outline),
            label: l10n.clearEvents,
            danger: true,
            onTap: () {
              Navigator.of(sheet).pop();
              logs.clearEvents();
            },
          ),
          MenuRow(
            icon: const Icon(Icons.close),
            label: l10n.cancel,
            onTap: () => Navigator.of(sheet).pop(),
          ),
        ],
      ),
    ),
  );
}

/// ⋮ of the Logs header (both tabs): Clear (of the tab on screen) and the report (download, send).
/// The filter (with the ignored sites in it) and the search have their own buttons.
Future<void> showLogsMenu(BuildContext context, LogsController logs) {
  final l10n = context.l10n;
  final events = logs.tab == 'events';
  return showAppSheet<void>(
    context,
    builder: (sheet) => SheetFrame(
      title: l10n.logs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MenuRow(
            key: const ValueKey('logsClear'),
            icon: const Icon(Icons.delete_outline),
            label: events ? l10n.clearEvents : l10n.clearRawLog,
            danger: true,
            onTap: () {
              Navigator.of(sheet).pop();
              if (events) {
                confirmClearEvents(context, logs);
              } else {
                logs.clearRaw();
              }
            },
          ),
          MenuRow(
            key: const ValueKey('logsDownload'),
            icon: const Icon(Icons.file_download_outlined),
            label: l10n.downloadLog,
            onTap: () {
              Navigator.of(sheet).pop();
              downloadLog(context, logs);
            },
          ),
          MenuRow(
            key: const ValueKey('logsSendReport'),
            icon: const Icon(Icons.outbox_outlined),
            label: l10n.sendReport,
            onTap: () {
              Navigator.of(sheet).pop();
              showSendReport(context, logs);
            },
          ),
        ],
      ),
    ),
  );
}
