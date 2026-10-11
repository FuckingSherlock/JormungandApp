import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jormungand_core/jormungand_core.dart' show reportSendDeadline;

import 'core_host.dart';

enum ReportPhase { form, sending, sent, failed }

/// «Send report» (docs/logs.md → Отправка) as the app keeps it: the send does not belong to the sheet.
/// The sheet only shows this — closing it does not stop the send, reopening it shows the send under
/// way, or its result (the id / the failure), and the note the user typed. One per app, owned by the
/// [LogsController].
///
/// A send always ends: the host promises a result within [countdown] (`reportSendDeadline`), and
/// [deadline] is the app's own last word, a little later, if the host does not keep it (a hung
/// channel, a lost future). While a send goes, [secondsLeft] / [fractionLeft] count the [countdown]
/// down from [startedAt]: the sheet shows them, and a reopened sheet shows the same time.
class ReportSendController extends ChangeNotifier {
  ReportSendController(this.host, {Duration? deadline, this.countdown = reportSendDeadline, DateTime Function()? now})
      : deadline = deadline ?? countdown + const Duration(seconds: 5),
        _now = now ?? DateTime.now;

  final CoreHost host;
  final Duration deadline;

  /// How long the host may take; what the countdown counts down.
  final Duration countdown;
  final DateTime Function() _now;

  ReportPhase phase = ReportPhase.form;

  /// The note being typed (kept while the sheet is closed, until the report is sent).
  String note = '';

  /// The report id once sent.
  String id = '';

  /// The way the sent report went (`direct` / `vpn`), empty if the host does not say.
  String via = '';

  /// When the send under way began (null otherwise).
  DateTime? startedAt;

  /// Whole seconds of [countdown] left (rounded up, never below 0); 0 when nothing is sent.
  int get secondsLeft {
    final s = startedAt;
    if (!sending || s == null) return 0;
    final left = countdown - _now().difference(s);
    return left <= Duration.zero ? 0 : (left.inMilliseconds + 999) ~/ 1000;
  }

  /// The part of [countdown] left, 1 → 0.
  double get fractionLeft {
    final s = startedAt;
    if (!sending || s == null || countdown <= Duration.zero) return 0;
    return (1 - _now().difference(s).inMilliseconds / countdown.inMilliseconds).clamp(0.0, 1.0);
  }

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
    via = '';
    startedAt = _now();
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
    startedAt = null;
    if (r['error'] == 'timeout') unawaited(host.cancelSendReport());
    if (r['ok'] == true) {
      phase = ReportPhase.sent;
      id = '${r['id'] ?? ''}';
      via = '${r['via'] ?? ''}';
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
    startedAt = null;
    _notify();
    unawaited(host.cancelSendReport());
  }

  /// The result has been seen (Done, or the sheet closed on it): a new, empty form.
  void reset() {
    if (sending) return;
    phase = ReportPhase.form;
    id = '';
    via = '';
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
