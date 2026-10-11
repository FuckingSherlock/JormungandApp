// ReportSendController (core/report_send.dart): the send lives outside the sheet and always ends.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/report_send.dart';
import 'package:jormungand_core/jormungand_core.dart' show reportSendDeadline;

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

  test('the countdown is the controller\'s: from the start time, whole seconds up, never below 0, gone with the send', () async {
    var now = DateTime.utc(2026, 10, 11, 12);
    host.sendGate = Completer<void>();
    final c = ReportSendController(host, countdown: const Duration(seconds: 18), now: () => now);
    addTearDown(c.dispose);
    expect(c.secondsLeft, 0, reason: 'nothing is sent');
    expect(c.deadline, const Duration(seconds: 23), reason: 'the app\'s own last word is a little after the core\'s deadline');
    final f = c.send();
    expect(c.startedAt, now);
    expect(c.secondsLeft, 18);
    expect(c.fractionLeft, 1.0);
    now = now.add(const Duration(milliseconds: 4500));
    expect(c.secondsLeft, 14);
    expect(c.fractionLeft, closeTo(.75, .001));
    now = now.add(const Duration(seconds: 60));
    expect(c.secondsLeft, 0);
    expect(c.fractionLeft, 0.0);
    host.sendGate!.complete();
    await f;
    expect(c.startedAt, isNull);
    expect(c.secondsLeft, 0);
  });

  test('the default countdown is the core\'s overall deadline', () {
    final c = ReportSendController(host);
    addTearDown(c.dispose);
    expect(c.countdown, reportSendDeadline);
    expect(c.deadline, greaterThan(reportSendDeadline));
  });

  test('the way a sent report went is kept until the result is seen', () async {
    host.sendResult = {'ok': true, 'id': 'r-2', 'via': 'vpn'};
    final c = ReportSendController(host);
    addTearDown(c.dispose);
    await c.send();
    expect(c.via, 'vpn');
    c.reset();
    expect(c.via, '');
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
