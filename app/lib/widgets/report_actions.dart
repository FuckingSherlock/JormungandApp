import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, LengthLimitingTextInputFormatter;
import 'package:jormungand_core/jormungand_core.dart' show reportNoteMax, reportToText;

import '../core/logs_controller.dart';
import '../core/report_send.dart';
import '../l10n/l10n.dart';
import '../platform/files_channel.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';

/// ⋮ → «Download log»: the core's report (`docs/logs.md` → Отчёт) as text into a file the user picks.
/// Everything the core keeps, not what the tab shows: the state, every event with its data and the
/// whole raw log of both rings. Credentials are masked, domains and server names stay.
Future<void> downloadLog(BuildContext context, LogsController logs) async {
  final l10n = context.l10n;
  try {
    final report = await logs.host.report();
    final at = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await BackupIo.current.save('jormungand-log-$at.txt', reportToText(report));
    if (saved != null && context.mounted) showToast(context, l10n.logsSaved(saved));
  } catch (e) {
    if (context.mounted) showToast(context, l10n.exportFailed('$e'));
  }
}

/// ⋮ → «Send report»: the sheet that says what leaves the phone, takes an optional note and
/// sends the report to the developers (`CoreHost.sendReport`).
Future<void> showSendReport(BuildContext context, LogsController logs) =>
    showAppSheet<void>(context, builder: (_) => _SendReportSheet(logs: logs));

/// The sheet only shows the app's [ReportSendController]: the send runs, and its result stays,
/// whether the sheet is open or not.
class _SendReportSheet extends StatefulWidget {
  const _SendReportSheet({required this.logs});

  final LogsController logs;

  @override
  State<_SendReportSheet> createState() => _SendReportSheetState();
}

class _SendReportSheetState extends State<_SendReportSheet> {
  late final TextEditingController _note = TextEditingController(text: _send.note);
  bool _sawSent = false;
  Timer? _tick;

  ReportSendController get _send => widget.logs.reportSend;

  @override
  void initState() {
    super.initState();
    _send.addListener(_changed);
    _syncTick();
  }

  void _changed() {
    if (!mounted) return;
    if (_send.phase == ReportPhase.sent) _sawSent = true;
    _syncTick();
    setState(() {});
  }

  // The countdown is the controller's (from its start time), so a reopened sheet shows the same
  // time; this only repaints it while a send goes.
  void _syncTick() {
    if (_send.sending) {
      _tick ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _send.removeListener(_changed);
    // the id was shown to the user and the sheet is gone: the next opening is a new, empty form
    if (_sawSent && _send.phase == ReportPhase.sent) _send.reset();
    _note.dispose();
    super.dispose();
  }

  Future<void> _copyId() async {
    await Clipboard.setData(ClipboardData(text: _send.id));
    if (mounted) showToast(context, context.l10n.copied);
  }

  bool get _notConfigured => _send.fail['error'] == 'not-configured';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final phase = _send.phase;
    final sent = phase == ReportPhase.sent;
    final busy = phase == ReportPhase.sending;
    final failed = phase == ReportPhase.failed;
    return SheetFrame(
      title: l10n.sendReport,
      footer: [
        if (sent)
          PrimaryButton(
            label: l10n.done,
            onPressed: () {
              _send.reset();
              Navigator.of(context).maybePop();
            },
          )
        else if (busy) ...[
          PrimaryButton(label: l10n.sendingS(_send.secondsLeft)),
          DangerTextButton(label: l10n.cancel, onPressed: _send.cancel),
        ] else if (failed && _notConfigured) ...[
          PrimaryButton(
            label: l10n.downloadLog,
            onPressed: () => downloadLog(context, widget.logs),
          ),
          DangerTextButton(label: l10n.close, onPressed: () => Navigator.of(context).maybePop()),
        ] else ...[
          PrimaryButton(label: failed ? l10n.retry : l10n.sendReport, onPressed: _send.send),
          DangerTextButton(label: l10n.cancel, onPressed: () => Navigator.of(context).maybePop()),
        ],
      ],
      child: sent
          ? FormGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(Icons.check_circle_outline, size: 20, color: c.accent),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SelectableText(
                          l10n.sentReportId(_send.id),
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.35, color: c.t1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  HintText(l10n.quoteThisIdWhenYouWrite),
                  if (_send.via == 'direct' && _send.firstError.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    HintText(l10n.sentDirectlyTheVpnPathDid),
                    HintText(_send.firstError), // the raw reason, not translated
                  ],
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SecondaryButton(label: l10n.copy, icon: Icons.copy, onPressed: _copyId),
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (failed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                    child: WarnNote(_errorText(l10n, _send.fail), detail: _errorDetail(_send.fail)),
                  ),
                FormGroup(
                  label: l10n.whatIsSent,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Para(l10n.appAndDeviceInformationTheEvents),
                      const SizedBox(height: 8),
                      _Para(l10n.passwordsUuidsTokensSubscriptionLinksAnd),
                    ],
                  ),
                ),
                FormGroup(
                  label: l10n.noteOptional,
                  child: IgnorePointer(
                    ignoring: busy,
                    child: Opacity(
                      opacity: busy ? .5 : 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppTextField(
                            controller: _note,
                            hint: l10n.whatDoesNotWorkAndSince,
                            lines: 4,
                            onChanged: (v) {
                              _send.setNote(v);
                              setState(() {});
                            },
                            inputFormatters: [LengthLimitingTextInputFormatter(reportNoteMax)],
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: HintText('${_note.text.length}/$reportNoteMax'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (busy)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
                    child: LinearProgressIndicator(
                      value: _send.fractionLeft,
                      minHeight: 3,
                      color: c.accent,
                      backgroundColor: c.border,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Para extends StatelessWidget {
  const _Para(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: context.colors.t2));
}

/// The raw technical reason (the core's `message`, English, not translated) shown small under the
/// error for the failures where the headline alone does not say what happened; null otherwise.
/// (`failed` already carries the message in its headline, `rejected` too.)
String? _errorDetail(Map<String, dynamic> r) {
  final msg = '${r['message'] ?? ''}'.trim();
  if (msg.isEmpty) return null;
  return switch ('${r['error']}') {
    'network' || 'timeout' || 'server' => msg,
    _ => null,
  };
}

/// What the user reads for a result of `CoreHost.sendReport` that is not `ok`.
String _errorText(AppLocalizations l10n, Map<String, dynamic> r) {
  final msg = '${r['message'] ?? ''}'.trim();
  return switch ('${r['error']}') {
    'not-configured' => l10n.sendingIsNotSetUpIn,
    'network' => l10n.noConnectionToTheReportServer,
    'no-route' => l10n.noDirectPathToTheReport,
    'timeout' => l10n.theReportServerDidNotAnswer,
    'rejected' => l10n.theServerDidNotAcceptThe(msg.isEmpty ? '—' : msg),
    'server' => l10n.theReportServerFailedTryAgain,
    final e => l10n.couldNotSendTheReport(msg.isEmpty ? e : msg),
  };
}
