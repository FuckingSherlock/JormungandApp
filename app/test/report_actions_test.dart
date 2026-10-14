// «Download log» and «Send report» (widgets/report_actions.dart): the report goes through the
// host, the file through BackupIo, the sheet says what leaves the phone and what came of it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand_core/jormungand_core.dart' show reportSendDeadline;
import 'package:jormungand/core/logs_controller.dart';
import 'package:jormungand/core/report_send.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand/platform/files_channel.dart';
import 'package:jormungand/widgets/report_actions.dart';

import 'fake_backup_io.dart';
import 'fake_core_host.dart';
import 'home_test.dart' show pumpApp;

void main() {
  late FakeBackupIo io;
  late FakeCoreHost host;
  late LogsController logs;
  final clipboard = <String>[];
  late DateTime fakeNow;

  setUp(() {
    io = FakeBackupIo(folder: null); // no remembered folder: the system "Save as" (save_flow_test.dart has the rest)
    BackupIo.current = io;
    clipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add('${(call.arguments as Map)['text']}');
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // the app is up (theme, l10n, navigator); the actions are called with a context under it
  Future<BuildContext> start(WidgetTester tester, {double textScale = 1.0}) async {
    host = FakeCoreHost();
    if (textScale != 1.0) host.gen.uiScale = textScale;
    host.reportMap = {
      'format': 1,
      'createdAt': '2026-01-02T03:04:05.000Z',
      'app': {'version': '0.1.0'},
      'events': [
        {'id': 1, 'at': 1760000000000, 'cat': 'conn', 'type': 'connected', 'level': 'info', 'data': {}},
      ],
      'raw': [
        {'n': 1, 't': 1760000000000, 'src': 'core', 'lvl': 'info', 'msg': 'hello raw line'},
      ],
    };
    fakeNow = DateTime.utc(2026, 10, 11, 12);
    logs = LogsController(host, reportSend: ReportSendController(host, now: () => fakeNow));
    await pumpApp(tester, host);
    return tester.element(find.byType(Scaffold).first);
  }

  // the send's clock is the controller's `now`: time passes in the widget tree and on this clock together
  Future<void> pass(WidgetTester tester, Duration d) async {
    fakeNow = fakeNow.add(d);
    await tester.pump(d);
  }

  void done() => logs.dispose();

  testWidgets('Download log saves the whole report as text under a dated name and says so', (tester) async {
    final ctx = await start(tester);
    unawaited(downloadLog(ctx, logs));
    await tester.pumpAndSettle();
    expect(io.name, matches(RegExp(r'^jormungand-log-\d{4}-\d{2}-\d{2}\.txt$')));
    expect(io.text, contains('Jormungand report (format 1)'));
    expect(io.text, contains('connected'));
    expect(io.text, contains('hello raw line'));
    expect(host.calls, contains('report'));
    expect(find.text('Logs saved: Documents/${io.name}'), findsOneWidget);
    done();
  });

  testWidgets('Download log: a failed save is a toast, not an exception', (tester) async {
    final ctx = await start(tester);
    io.fail = StateError('disk full');
    unawaited(downloadLog(ctx, logs));
    await tester.pumpAndSettle();
    expect(find.textContaining('Export failed'), findsOneWidget);
    expect(find.textContaining('disk full'), findsOneWidget);
    done();
  });

  testWidgets('Send report: says what is sent, sends the note, shows the id and copies it', (tester) async {
    final ctx = await start(tester);
    host.sendGate = Completer<void>();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();

    expect(find.text('Send report'), findsWidgets);
    expect(find.text('WHAT IS SENT'), findsOneWidget);
    expect(find.textContaining('package names'), findsOneWidget);
    expect(find.textContaining('Domains and IP addresses stay'), findsOneWidget);
    expect(find.text('0/500'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'it fails since noon');
    await tester.pump();
    expect(find.text('19/500'), findsOneWidget);

    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();
    expect(host.sentNotes, ['it fails since noon']);
    expect(find.textContaining('Sending…'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget, reason: 'a send that goes can be stopped');

    host.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-1'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboard, ['r-1']);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-1'), findsNothing);
    done();
  });

  testWidgets('Send report: Cancel while sending stops it and gives the form back with the note', (tester) async {
    final ctx = await start(tester);
    host.sendGate = Completer<void>();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'keep me');
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();
    expect(find.textContaining('Sending…'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(host.calls, contains('cancelSendReport'));
    expect(find.textContaining('Sending…'), findsNothing);
    expect(find.text('WHAT IS SENT'), findsOneWidget);
    expect(find.text('keep me'), findsOneWidget);
    expect(find.textContaining('Could not send'), findsNothing, reason: 'a cancel is not an error');
    expect(logs.reportSend.phase, ReportPhase.form);

    // and it can be sent again: the old send's late answer does not touch the new one
    host.sendGate = null;
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-1'), findsOneWidget);
    expect(host.sentNotes, ['keep me', 'keep me']);
    done();
  });

  testWidgets('Send report: closing the sheet does not stop the send; reopening shows it, then its result', (tester) async {
    final ctx = await start(tester);
    host.sendGate = Completer<void>();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'still going');
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();

    Navigator.of(ctx).pop(); // the sheet goes away mid-send
    await tester.pumpAndSettle();
    expect(find.textContaining('Sending…'), findsNothing);
    expect(host.calls, isNot(contains('cancelSendReport')));
    expect(logs.reportSend.sending, isTrue);

    unawaited(showSendReport(ctx, logs));
    // not pumpAndSettle: the progress bar never settles and fake time would run out the deadline
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Sending…'), findsOneWidget, reason: 'the send under way, not a fresh form');
    expect(find.text('WHAT IS SENT'), findsOneWidget);
    expect(host.sentNotes, ['still going'], reason: 'reopening does not send again');

    host.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-1'), findsOneWidget);

    // closed on the result: the next opening is a new, empty form
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-1'), findsNothing);
    expect(find.text('0/500'), findsOneWidget);
    done();
  });

  testWidgets('Send report: a countdown of the overall deadline runs on the button and the bar, and ends with the send', (tester) async {
    final ctx = await start(tester);
    final total = reportSendDeadline.inSeconds;
    host.sendGate = Completer<void>();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();
    expect(find.text('Sending… $total s'), findsOneWidget);
    double bar() => tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value!;
    expect(bar(), 1.0);

    await pass(tester, const Duration(seconds: 3));
    expect(find.text('Sending… ${total - 3} s'), findsOneWidget);
    expect(bar(), closeTo((total - 3) / total, .01));
    await pass(tester, const Duration(milliseconds: 1500));
    expect(find.text('Sending… ${total - 4} s'), findsOneWidget, reason: 'rounded up: 13.5 s left reads 14');

    await pass(tester, Duration(seconds: total)); // past the deadline: never below 0
    expect(find.text('Sending… 0 s'), findsOneWidget);
    expect(bar(), 0.0);

    host.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Sending…'), findsNothing);
    expect(find.text('Sent. Report id: r-1'), findsOneWidget);
    done();
  });

  testWidgets('Send report: the countdown goes on while the sheet is closed and a reopened sheet shows the time left', (tester) async {
    final ctx = await start(tester);
    final total = reportSendDeadline.inSeconds;
    host.sendGate = Completer<void>();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();
    await pass(tester, const Duration(seconds: 4));
    expect(find.text('Sending… ${total - 4} s'), findsOneWidget);

    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    await pass(tester, const Duration(seconds: 5)); // time passes with no sheet
    expect(logs.reportSend.secondsLeft, total - 9);

    unawaited(showSendReport(ctx, logs));
    await pass(tester, const Duration(milliseconds: 100)); // 9.1 s gone: 8.9 left reads 9
    expect(find.text('Sending… ${total - 9} s'), findsOneWidget, reason: 'not a fresh countdown from the start');

    await pass(tester, const Duration(seconds: 2));
    expect(find.text('Sending… ${total - 11} s'), findsOneWidget, reason: 'and it keeps going');
    host.sendGate!.complete();
    await tester.pumpAndSettle();
    done();
  });

  testWidgets('Send report: no direct path and the VPN off is said plainly, with Retry', (tester) async {
    final ctx = await start(tester);
    host.sendResult = {'ok': false, 'error': 'no-route', 'message': 'no direct path to the receiver (x) and the VPN is not connected'};
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('No direct path to the report server, and the VPN is off'), findsOneWidget);
    expect(find.textContaining('no direct path to the receiver (x)'), findsNothing, reason: 'no-route has its own plain text');
    expect(find.text('Retry'), findsOneWidget);
    done();
  });

  testWidgets('Send report: the normal paths (VPN first, or direct with the VPN off) have no caption', (tester) async {
    final ctx = await start(tester);
    for (final via in ['vpn', 'direct']) {
      host.sendResult = {'ok': true, 'id': 'r-5', 'bytes': 10, 'via': via};
      unawaited(showSendReport(ctx, logs));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
      await tester.pumpAndSettle();
      expect(find.text('Sent. Report id: r-5'), findsOneWidget, reason: via);
      expect(find.textContaining('Sent directly'), findsNothing, reason: via);
      expect(find.textContaining('Sent through'), findsNothing, reason: via);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    }
    done();
  });

  testWidgets('Send report: direct after a failed tunnel try says so, with the raw reason', (tester) async {
    final ctx = await start(tester);
    const why = 'via VPN: the receiver did not answer in 10 s (via VPN)';
    host.sendResult = {'ok': true, 'id': 'r-6', 'bytes': 10, 'via': 'direct', 'firstError': why};
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-6'), findsOneWidget);
    expect(find.text('Sent directly: the VPN path did not work.'), findsOneWidget);
    expect(find.text(why), findsOneWidget);
    done();
  });

  testWidgets('Send report: a result that arrives while the sheet is closed is there on reopening', (tester) async {
    final ctx = await start(tester);
    host.sendGate = Completer<void>();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();

    host.sendGate!.complete();
    await tester.pumpAndSettle();
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    expect(find.text('Sent. Report id: r-1'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(logs.reportSend.phase, ReportPhase.form);
    done();
  });

  testWidgets('Send report: a failure that arrives while closed is shown on reopening, with the note', (tester) async {
    final ctx = await start(tester);
    host.sendGate = Completer<void>();
    host.sendResult = {'ok': false, 'error': 'timeout', 'message': 'stuck while uploading'};
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my note');
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pump();
    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    host.sendGate!.complete();
    await tester.pumpAndSettle();

    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    expect(find.textContaining('did not answer in time'), findsOneWidget);
    expect(find.text('my note'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    done();
  });

  testWidgets('Send report: a failure keeps the note and offers Retry', (tester) async {
    final ctx = await start(tester);
    const why = 'via VPN: the receiver did not answer in 10 s (via VPN); direct: no path (no echo in 3 s)';
    host.sendResult = {'ok': false, 'error': 'network', 'message': why};
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'note one');
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('No connection to the report server'), findsOneWidget);
    expect(find.text(why), findsOneWidget, reason: 'the raw reason is shown small under the error');
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('note one'), findsOneWidget);

    host.sendResult = {'ok': true, 'id': 'r-9', 'bytes': 10};
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(host.sentNotes, ['note one', 'note one']);
    expect(find.text('Sent. Report id: r-9'), findsOneWidget);
    done();
  });

  testWidgets('Send report: not configured is said honestly and points at Download log', (tester) async {
    final ctx = await start(tester);
    host.sendResult = {'ok': false, 'error': 'not-configured'};
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Sending is not set up in this build yet'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Download log'), findsOneWidget);

    await tester.tap(find.text('Download log'));
    await tester.pumpAndSettle();
    expect(io.name, startsWith('jormungand-log-'));
    done();
  });

  testWidgets('Send report: the sheet fits 320 dp at 120 % text', (tester) async {
    final ctx = await start(tester, textScale: 1.2);
    unawaited(showSendReport(ctx, logs));
    await tester.pumpAndSettle();
    expect(find.text('WHAT IS SENT'), findsOneWidget);
    expect(tester.takeException(), isNull);
    host.sendResult = {'ok': false, 'error': 'rejected', 'message': 'too large'};
    await tester.tap(find.widgetWithText(InkWell, 'Send report').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('did not accept the report: too large'), findsOneWidget);
    expect(tester.takeException(), isNull);
    done();
  });
}
