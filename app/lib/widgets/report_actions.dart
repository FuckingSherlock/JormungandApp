import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, LengthLimitingTextInputFormatter;
import 'package:jormungand_core/jormungand_core.dart' show reportNoteMax, reportToText;

import '../core/logs_controller.dart';
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

enum _Phase { form, sending, sent, failed }

class _SendReportSheet extends StatefulWidget {
  const _SendReportSheet({required this.logs});

  final LogsController logs;

  @override
  State<_SendReportSheet> createState() => _SendReportSheetState();
}

class _SendReportSheetState extends State<_SendReportSheet> {
  final _note = TextEditingController();
  _Phase _phase = _Phase.form;
  String _id = '';
  Map<String, dynamic> _fail = const {};

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _phase = _Phase.sending);
    Map<String, dynamic> r;
    try {
      r = await widget.logs.host.sendReport(note: _note.text.trim());
    } catch (e) {
      r = {'ok': false, 'error': 'failed', 'message': '$e'};
    }
    if (!mounted) return;
    setState(() {
      if (r['ok'] == true) {
        _phase = _Phase.sent;
        _id = '${r['id'] ?? ''}';
      } else {
        _phase = _Phase.failed;
        _fail = r;
      }
    });
  }

  Future<void> _copyId() async {
    await Clipboard.setData(ClipboardData(text: _id));
    if (mounted) showToast(context, context.l10n.copied);
  }

  bool get _notConfigured => _fail['error'] == 'not-configured';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final sent = _phase == _Phase.sent;
    final busy = _phase == _Phase.sending;
    return SheetFrame(
      title: l10n.sendReport,
      footer: [
        if (sent)
          PrimaryButton(label: l10n.done, onPressed: () => Navigator.of(context).maybePop())
        else if (busy)
          PrimaryButton(label: l10n.sending)
        else if (_phase == _Phase.failed && _notConfigured) ...[
          PrimaryButton(
            label: l10n.downloadLog,
            onPressed: () => downloadLog(context, widget.logs),
          ),
          DangerTextButton(label: l10n.close, onPressed: () => Navigator.of(context).maybePop()),
        ] else ...[
          PrimaryButton(label: _phase == _Phase.failed ? l10n.retry : l10n.sendReport, onPressed: _send),
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
                          l10n.sentReportId(_id),
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.35, color: c.t1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  HintText(l10n.quoteThisIdWhenYouWrite),
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
                if (_phase == _Phase.failed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                    child: WarnNote(_errorText(l10n, _fail)),
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
                            onChanged: (_) => setState(() {}),
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

/// What the user reads for a result of `CoreHost.sendReport` that is not `ok`.
String _errorText(AppLocalizations l10n, Map<String, dynamic> r) {
  final msg = '${r['message'] ?? ''}'.trim();
  return switch ('${r['error']}') {
    'not-configured' => l10n.sendingIsNotSetUpIn,
    'network' => l10n.noConnectionToTheReportServer,
    'rejected' => l10n.theServerDidNotAcceptThe(msg.isEmpty ? '—' : msg),
    'server' => l10n.theReportServerFailedTryAgain,
    final e => l10n.couldNotSendTheReport(msg.isEmpty ? e : msg),
  };
}
