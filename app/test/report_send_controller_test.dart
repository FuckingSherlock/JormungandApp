// ReportSendController (core/report_send.dart): the send lives outside the sheet and always ends.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/report_send.dart';

import 'fake_core_host.dart';

void main() {
  late FakeCoreHost host;

  setUp(() => host = FakeCoreHost());

  test('a host that never answers: the send ends as a timeout, and the core is told to stop', () async {
    host.sendGate = Completer<void>(); // never completed by the host's own work
    final c = ReportSendController(host, deadline: const Duration(milliseconds: 100));
    addTearDown(c.dispose);
    c.setNote('x');
    final f = c.send();
    expect(c.phase, ReportPhase.sending);
    await f.timeout(const Duration(seconds: 3));
    expect(c.phase, ReportPhase.failed);
    expect(c.fail['error'], 'timeout');
    expect(host.calls, contains('cancelSendReport'));
    // free for a retry
    host.sendGate = null;
    await c.send();
    expect(c.phase, ReportPhase.sent);
    expect(c.id, 'r-1');
    expect(c.note, '', reason: 'a sent note is spent');
  });

  test('a host that throws is a failure, not an exception', () async {
    final c = ReportSendController(host);
    addTearDown(c.dispose);
    host.sendResult = {'ok': false, 'error': 'network', 'message': 'direct: x; via VPN: y'};
    await c.send();
    expect(c.phase, ReportPhase.failed);
    expect(c.fail['message'], contains('via VPN'));
    c.reset();
    expect(c.phase, ReportPhase.form);
    expect(c.fail, isEmpty);
  });

  test('cancel: back to the form with the note, the late answer of the stopped send is not heard', () async {
    host.sendGate = Completer<void>();
    final c = ReportSendController(host);
    addTearDown(c.dispose);
    c.setNote('keep');
    final f = c.send();
    c.cancel();
    expect(c.phase, ReportPhase.form);
    expect(c.note, 'keep');
    await f;
    expect(c.phase, ReportPhase.form);
    expect(host.calls, contains('cancelSendReport'));
  });
}
