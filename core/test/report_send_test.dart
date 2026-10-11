// "Send report": the strict masking, the note, the gzip and the uploader seam (report_upload.dart,
// docs/logs.md → Отправка). The report itself is covered by report_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

const _secret = 'sekret-pass-123';
const _uuid = '11111111-2222-3333-4444-555555555555';

class _Runner implements BoxRunner {
  bool up = false;
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;

  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async => up = true;
  @override
  Future<void> stop() async => up = false;
}

class _Uploader implements ReportUploader {
  _Uploader({this.fail, this.hang = false});

  final Object? fail;

  /// Never answers and ignores the cancel token (an uploader that is stuck for real).
  final bool hang;
  List<int>? bytes;
  Map<String, dynamic>? meta;
  int calls = 0;
  int? proxyPort;

  @override
  Future<ReportReceipt> upload(List<int> gzipped, {required Map<String, dynamic> meta, int? proxyPort, ReportCancel? cancel}) async {
    calls++;
    this.proxyPort = proxyPort;
    if (hang) return Completer<ReportReceipt>().future;
    if (fail != null) throw fail!;
    bytes = gzipped;
    this.meta = meta;
    return const ReportReceipt(id: 'r-123');
  }
}

Map<String, dynamic> _decode(List<int> gz) => jsonDecode(utf8.decode(gzip.decode(gz))) as Map<String, dynamic>;

void main() {
  group('Redactor strict', () {
    test('e-mail addresses and the account name of home paths go, domains and packages stay', () {
      const s = 'mail me at john.doe@example.com from C:\\Users\\JohnDoe\\AppData\\x, /home/jdoe/.cache, pkg org.example.app via de1.example.org';
      final plain = Redactor().text(s);
      expect(plain, s, reason: 'the local export keeps them');
      final r = Redactor(strict: true);
      final out = r.text(s);
      expect(out, isNot(contains('john.doe')));
      expect(out, isNot(contains('JohnDoe')));
      expect(out, isNot(contains('jdoe')));
      expect(out, contains('<email#1>'));
      expect(out, contains('C:\\Users\\<path#1>\\AppData'));
      expect(out, contains('/home/<path#2>/.cache'));
      expect(out, contains('org.example.app'));
      expect(out, contains('de1.example.org'));
      expect(r.counts, {'email': 1, 'path': 2});
      expect(Redactor(strict: true).text(out), out, reason: 'idempotent');
    });

    test('a link userinfo is not taken for an e-mail', () {
      final out = Redactor(strict: true).text('vless://$_uuid@de1.example.org:443?type=tcp#x');
      expect(out, contains('@de1.example.org:443'));
      expect(out, isNot(contains('<email')));
    });
  });

  group('packReport', () {
    test('gzip round-trips; the note is cut to 500, masked, counted', () {
      final r = Redactor(strict: true);
      final base = {
        'format': 1,
        'createdAt': '2026-01-01T00:00:00.000Z',
        'app': {'version': '1.2.3', 'versionCode': 9, 'commit': 'abc1234', 'platform': 'android'},
        'redactions': {'total': 0, 'byKind': <String, int>{}},
      };
      final note = 'it fails; my mail a.b@c.org, token=$_secret ${'x' * 600}';
      final packed = packReport(base, note: '  $note  ', redactor: r);
      final back = _decode(packed.gzipped);
      expect(back, packed.report);
      final n = back['note'] as String;
      expect(n, isNot(contains(_secret)));
      expect(n, isNot(contains('a.b@c.org')));
      expect(n.length, lessThan(560));
      expect((back['redactions'] as Map)['total'], 2);
      expect(packed.meta, containsPair('version', '1.2.3'));
      expect(packed.meta, containsPair('commit', 'abc1234'));
      expect(packed.meta['noteLength'], reportNoteMax);
      expect(packed.meta['gzipBytes'], packed.gzipped.length);
      expect(base.containsKey('note'), isFalse, reason: 'the input is not changed');
    });

    test('no note: no field', () {
      final packed = packReport({'format': 1, 'app': {}});
      expect(packed.report.containsKey('note'), isFalse);
      expect(packed.meta['noteLength'], 0);
    });
  });

  group('CoreService.sendReport', () {
    late Directory tmp;

    setUp(() async => tmp = await Directory.systemTemp.createTemp('jorm-send'));
    tearDown(() async => tmp.delete(recursive: true));

    Future<CoreService> open(ReportUploader? up, {Duration? deadline}) async {
      final svc = CoreService(
        reportDeadline: deadline ?? reportSendDeadline,
        singBox: 'none',
        dataDir: p.join(tmp.path, 'data'),
        runner: _Runner(),
        sysProxy: NoSystemProxy(),
        exitCheck: (_) async => {'ip': '127.0.0.1', 'country': 'ZZ'},
        knownSingBoxVersion: '1.12.0',
        reportUploader: up,
      );
      await svc.init();
      return svc;
    }

    test('the uploader gets the gzipped report with the note, masked; the receipt comes back', () async {
      final up = _Uploader();
      final svc = await open(up);
      addTearDown(svc.dispose);
      svc.logBook.note('warn', 'could not load $vlessReality for owner@example.com in C:\\Users\\Ann\\x');
      svc.logBook.note('info', 'resolved de1.example.org password=$_secret');
      svc.eventBook.add('sub', 'failed', 'warn', data: {'source': 's1', 'error': 'uuid $_uuid'});

      final res = await svc.sendReport(
        note: 'Telegram does not load since 14:00, sub https://panel.example.org/sub/AbCdEf123456',
        appInfo: {'version': '0.9.0', 'versionCode': 42, 'commit': 'abc1234', 'platform': 'android'},
      );
      expect(res['ok'], isTrue);
      expect(res['id'], 'r-123');
      expect(up.calls, 1);
      final rep = _decode(up.bytes!);
      expect(rep['format'], 1);
      expect((rep['app'] as Map)['version'], '0.9.0');
      expect(rep['note'], contains('Telegram does not load since 14:00'));
      expect(rep['note'], isNot(contains('AbCdEf123456')));
      expect(rep['note'], contains('panel.example.org'));
      final text = jsonEncode(rep);
      for (final bad in [_secret, _uuid, 'owner@example.com', 'Ann', 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw']) {
        expect(text, isNot(contains(bad)), reason: bad);
      }
      expect(text, contains('de1.example.org'));
      expect((rep['redactions'] as Map)['byKind'], containsPair('email', greaterThanOrEqualTo(1)));
      expect(up.meta, containsPair('version', '0.9.0'));
      expect(up.meta!['bytes'], utf8.encode(jsonEncode(rep)).length);
    });

    test('the local export of the same data keeps e-mail and path (strict is the sent form only)', () async {
      final svc = await open(_Uploader());
      addTearDown(svc.dispose);
      svc.logBook.note('info', 'owner@example.com');
      final r = await svc.report();
      expect(jsonEncode(r), contains('owner@example.com'));
    });

    test('no uploader plugged in: not-configured, nothing thrown', () async {
      final svc = await open(null);
      addTearDown(svc.dispose);
      expect(await svc.sendReport(note: 'x'), {'ok': false, 'error': 'not-configured'});
    });

    test('a failed delivery is a result, with its code', () async {
      var svc = await open(_Uploader(fail: const ReportUploadException('network', 'timeout')));
      expect(await svc.sendReport(), {'ok': false, 'error': 'network', 'message': 'timeout'});
      await svc.dispose();
      svc = await open(_Uploader(fail: StateError('boom')));
      addTearDown(svc.dispose);
      final r = await svc.sendReport();
      expect([r['ok'], r['error']], [false, 'failed']);
    });

    test('no direct path and the VPN off arrives as the `no-route` result, with its reason', () async {
      final svc = await open(_Uploader(fail: const ReportUploadException('no-route', 'no direct path (x) and the VPN is not connected')));
      addTearDown(svc.dispose);
      final r = await svc.sendReport();
      expect([r['ok'], r['error']], [false, 'no-route']);
      expect(r['message'], contains('VPN'));
      expect(svc.logBook.since(null)['lines'].toString(), contains('Report not sent (no-route)'));
    });

    test('the default overall deadline is the probe + the upload + a small margin for building', () {
      expect(reportSendDeadline, reportProbeTimeout + reportUploadTimeout + reportBuildMargin);
      expect(reportSendDeadline, const Duration(seconds: 18));
    });

    test('an uploader that never answers: the send still ends, as a timeout that says where it stuck', () async {
      final up = _Uploader(hang: true);
      final svc = await open(up, deadline: const Duration(milliseconds: 300));
      addTearDown(svc.dispose);
      final sw = Stopwatch()..start();
      final r = await svc.sendReport(note: 'x');
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect([r['ok'], r['error']], [false, 'timeout']);
      expect(r['message'], contains('uploading'));
      expect(svc.logBook.since(null)['lines'].toString(), contains('Report not sent (timeout)'));
      // the core is free for the next send
      expect((await svc.sendReport()).containsKey('ok'), isTrue);
    });

    test('Cancel ends a send under way as `cancelled`, even when the uploader ignores the token', () async {
      final up = _Uploader(hang: true);
      final svc = await open(up);
      addTearDown(svc.dispose);
      final f = svc.sendReport(note: 'x');
      while (up.calls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await svc.cancelReport(), {'ok': true, 'cancelled': true});
      final r = await f.timeout(const Duration(seconds: 5));
      expect(r, {'ok': false, 'error': 'cancelled'});
      expect(await svc.cancelReport(), {'ok': true, 'cancelled': false}, reason: 'nothing under way now');
    });

    test('a second call while one goes joins it: one upload', () async {
      final up = _Uploader();
      final svc = await open(up);
      addTearDown(svc.dispose);
      final a = svc.sendReport(note: 'a');
      final b = svc.sendReport(note: 'b');
      expect(identical(a, b), isTrue);
      expect((await a)['ok'], isTrue);
      expect(up.calls, 1);
    });
  });
}
