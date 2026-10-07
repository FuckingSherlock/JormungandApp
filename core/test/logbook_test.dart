// LogBook: two rings (connection noise cannot push warnings / errors out) and the problems kept
// on disk, loaded at start.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _conn = '[1 5ms] inbound/mixed[mixed-in]: inbound connection to example.com:443';

List<Map> _lines(LogBook b, [int? from]) => (b.since(from)['lines'] as List).cast<Map>();

void main() {
  group('log book rings', () {
    test('connection lines have a ring of their own: they never evict errors or other lines', () {
      final b = LogBook(cap: 10, noiseCap: 3);
      b.singBox('ERROR[0001] dns: broken');
      b.note('info', 'Connected');
      for (var i = 0; i < 100; i++) {
        b.singBox('INFO[0001] $_conn');
      }
      final l = _lines(b);
      expect(l.where((x) => x['lvl'] == 'error').length, 1, reason: 'the error survives 100 connection lines');
      expect(l.where((x) => x['msg'] == 'Connected').length, 1);
      expect(l.where((x) => (x['msg'] as String).contains('connection to')).length, 3, reason: 'only the last noiseCap');
      final ns = [for (final x in l) x['n'] as int];
      expect([...ns]..sort(), ns, reason: 'merged by number');
      expect(b.since(null)['next'], 102);
    });

    test('a failed connection (warn / error) is not noise; since merges both rings from a number', () {
      final b = LogBook(cap: 10, noiseCap: 10);
      b.singBox('INFO[0001] $_conn'); // 0
      b.singBox('WARN[0001] [1 5ms] outbound/vless[x]: outbound connection to a:1 failed'); // 1, main ring
      b.singBox('INFO[0001] $_conn'); // 2
      b.note('info', 'x'); // 3
      expect(_lines(b).map((x) => x['n']), [0, 1, 2, 3]);
      expect(_lines(b, 2).map((x) => x['n']), [2, 3]);
      expect(_lines(b, 4), isEmpty);
      b.clear();
      expect(_lines(b), isEmpty);
    });
  });

  group('ignored sites', () {
    test('host matching: the host and its subdomains only', () {
      final s = IgnoredSites(['Example.com', 'http://dead.org:8080/x', '*.wild.net', 'bad host']);
      expect(s.hosts, ['example.com', 'dead.org', 'wild.net']);
      expect(s.matches('example.com'), isTrue);
      expect(s.matches('API.Example.com:443'), isTrue);
      expect(s.matches('notexample.com'), isFalse);
      expect(s.matches('example.com.evil.io'), isFalse);
      expect(s.matchesText('dial tcp: lookup a.dead.org: no such host'), isTrue);
      expect(s.matchesText('outbound connection to wild.net:443 failed.'), isTrue);
      expect(s.matchesText('dial tcp 1.2.3.4:443: i/o timeout'), isFalse);
    });

    test('failed lines of an ignored site go to the noise ring: they do not push errors out, nor reach the disk', () async {
      final dir = Directory.systemTemp.createTempSync('logbook-ign');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'problems.jsonl'));
      final b = LogBook(cap: 3, noiseCap: 2, file: file, flushEvery: const Duration(milliseconds: 20));
      b.ignored = IgnoredSites(['dead.example.com']);
      b.singBox('ERROR[0001] real: broken'); // 0
      for (var i = 0; i < 20; i++) {
        b.singBox('WARN[0001] [$i 5ms] outbound/vless[x]: outbound connection to api.dead.example.com:443: i/o timeout');
      }
      b.note('warn', 'auto: dead.example.com:443 does not open through A');
      b.singBox('ERROR[0001] other.org: refused');
      final l = _lines(b);
      expect(l.where((x) => '${x['msg']}'.contains('real: broken')).length, 1, reason: 'the error survives the flood');
      expect(l.where((x) => '${x['msg']}'.contains('dead.example.com')).length, 2, reason: 'only the last noiseCap');
      expect(l.where((x) => '${x['msg']}'.contains('other.org')).length, 1);
      await b.flush();
      final disk = file.readAsStringSync();
      expect(disk, contains('real: broken'));
      expect(disk, isNot(contains('dead.example.com')));
    });
  });

  group('log book on disk', () {
    late Directory dir;
    late File file;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('logbook');
      file = File(p.join(dir.path, 'problems.jsonl'));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('warnings and errors are written and come back after a restart; the rest does not', () async {
      final b = LogBook(file: file, flushEvery: const Duration(milliseconds: 20));
      b.note('error', 'Connect failed: x');
      b.singBox('WARN[0001] dns: slow');
      b.note('info', 'just info');
      b.singBox('INFO[0001] $_conn');
      await b.flush();

      final c = LogBook(file: file)..load();
      final l = _lines(c);
      expect(l.map((x) => [x['lvl'], x['msg']]), [
        ['error', 'Connect failed: x'],
        ['warn', 'dns: slow'],
      ]);
      expect(l.map((x) => x['n']), [0, 1], reason: 'renumbered');
      c.note('error', 'after restart');
      expect(_lines(c).last['n'], 2);
    });

    test('a cut-off line is dropped; clear empties the file; the file stays under its limit', () async {
      file.writeAsStringSync('${jsonEncode({'t': 1, 'src': 'core', 'lvl': 'error', 'msg': 'old'})}\n{"t": 2, "lv');
      final b = LogBook(file: file, maxBytes: 2000)..load();
      expect(_lines(b).map((x) => x['msg']), ['old']);

      for (var i = 0; i < 100; i++) {
        b.note('error', 'problem number $i with some padding to make it longer');
        if (i % 10 == 9) await b.flush();
      }
      await b.flush();
      expect(file.lengthSync(), lessThan(3000), reason: 'rotated: rewritten from the newest problems');
      final again = LogBook(file: file)..load();
      expect(_lines(again).last['msg'], contains('problem number 99'));

      b.clear();
      await b.flush();
      expect(file.readAsStringSync(), isEmpty);
    });
  });
}
