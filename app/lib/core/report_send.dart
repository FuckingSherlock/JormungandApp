import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_host.dart';

enum ReportPhase { form, sending, sent, failed }

/// «Send report» (docs/logs.md → Отправка) as the app keeps it: the send does not belong to the sheet.
/// The sheet only shows this — closing it does not stop the send, reopening it shows the send under
/// way, or its result (the id / the failure), and the note the user typed. One per app, owned by the
/// [LogsController].
///
/// A send always ends: the host promises a result within a minute, and [deadline] is the sheet's own
/// last word if the host does not keep it (a hung channel, a lost future).
class ReportSendController extends ChangeNotifier {
  ReportSendController(this.host, {this.deadline = const Duration(seconds: 75)});

  final CoreHost host;
  final Duration deadline;

  ReportPhase phase = ReportPhase.form;

  /// The note being typed (kept while the sheet is closed, until the report is sent).
  String note = '';

  /// The report id once sent.
  String id = '';

  /// The host's answer when the send failed (`error`, `message`).
  Map<String, dynamic> fail = const {};

  // which send is the current one: a cancelled or timed-out send's late answer is not heard
  int _gen = 0;
  bool _disposed = false;

  bool get sending => phase == ReportPhase.sending;

  void setNote(String v) => note = v;

  /// Starts the send of [note]. Ignored while one goes.
  Future<void> send() async {
    if (sending) return;
    final gen = ++_gen;
    final text = note.trim();
    phase = ReportPhase.sending;
    fail = const {};
    _notify();
    Map<String, dynamic> r;
    try {
      r = await host.sendReport(note: text).timeout(
            deadline,
            onTimeout: () => {
              'ok': false,
              'error': 'timeout',
              'message': 'no answer from the core in ${deadline.inSeconds} s',
            },
          );
    } catch (e) {
      r = {'ok': false, 'error': 'failed', 'message': '$e'};
    }
    if (gen != _gen) return; // cancelled, and maybe sent again since
    if (r['error'] == 'timeout') unawaited(host.cancelSendReport());
    if (r['ok'] == true) {
      phase = ReportPhase.sent;
      id = '${r['id'] ?? ''}';
      note = '';
    } else if (r['error'] == 'cancelled') {
      phase = ReportPhase.form; // a cancel from elsewhere: the note stays
    } else {
      phase = ReportPhase.failed;
      fail = r;
    }
    _notify();
  }

  /// Stops the send under way: back to the form, the note kept.
  void cancel() {
    if (!sending) return;
    _gen++;
    phase = ReportPhase.form;
    _notify();
    unawaited(host.cancelSendReport());
  }

  /// The result has been seen (Done, or the sheet closed on it): a new, empty form.
  void reset() {
    if (sending) return;
    phase = ReportPhase.form;
    id = '';
    fail = const {};
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
