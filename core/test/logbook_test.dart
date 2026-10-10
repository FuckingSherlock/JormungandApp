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

  group('the tag of a server in the brackets', () {
    test('holds colons (route<i>-entry/<sid>::<nid>): such a connection line is flood too', () {
      for (final tag in ['route0-entry/src1::n3', 'route2/src1::n10', 'chain:c1>entry/src2::n1', 'proxy', 'mixed-in']) {
        for (final kind in ['outbound connection to a:443', 'outbound packet connection to a:53', 'inbound connection from 10.0.0.2:5000']) {
          final dir = kind.startsWith('inbound') ? 'inbound/tun' : 'outbound/vless';
          expect(isNoiseLine('[7 12ms] $dir[$tag]: $kind'), isTrue, reason: '$tag / $kind');
        }
      }
      final b = LogBook(cap: 10, noiseCap: 2);
      b.note('info', 'Connected');
      for (var i = 0; i < 30; i++) {
        b.singBox('INFO[0001] [$i 4ms] outbound/vless[route0-entry/src1::n3]: outbound connection to x.example:443');
      }
      expect(_lines(b).where((x) => (x['msg'] as String).contains('route0-entry')), hasLength(2), reason: 'the noise ring, not the main one');
      expect(b.since(null, conns: false)['hidden'], 2, reason: 'left out at the source with Connections off');
      expect(isNoiseLine('[1 5ms] outbound/vless[route0-entry/src1::n3]: outbound connection to x:1: dial tcp: i/o timeout'), isTrue,
          reason: 'by text; a warn / error is never noise, the caller checks the level');
    });

    test('the other spellings of a connection / DNS answer in sing-box 1.14 are flood, decisions stay visible', () {
      const flood = [
        '[7 1ms] outbound/vless[route0/src1::n3]: outbound multiplex connection to a:443',
        '[7 1ms] outbound/vless[route0/src1::n3]: outbound multiplex packet connection to a:443',
        '[7 1ms] outbound/hysteria2[route1/src2::n1]: outbound packet connection to a:443',
        '[7 1ms] outbound/vless[x]: outbound UoT connect packet connection to a:53',
        '[7 1ms] inbound/tun[tun-in]: inbound DNS packet from 10.0.0.2:5353',
        '[7 1ms] inbound/tun[tun-in]: inbound redirect DNS connection from 10.0.0.2:5353',
        '[7 1ms] inbound/http[http-in]: [alice] inbound connection to a:443',
        '[7 1ms] router: found user id: 10234',
        '[7 1ms] router: found neighbor: aa:bb:cc:dd:ee:ff',
        '[7 1ms] dns: exchanged A example.com. 300 IN A 1.2.3.4',
        '[7 1ms] dns: cached AAAA example.com. 300 IN AAAA ::1',
        '[7 1ms] dns: lookup succeed for example.com: 1.2.3.4',
      ];
      for (final l in flood) {
        expect(isNoiseLine(l), isTrue, reason: l);
      }
      const keep = [
        '[7 1ms] router: match[3] => route(proxy)',
        '[7 1ms] dns: rejected A ads.example.com. 3 IN A',
        '[7 1ms] outbound/block[block]: blocked connection to ads.example.com:443',
        'connection: open outbound connection: dial tcp 1.2.3.4:443: i/o timeout',
        '[7 1ms] outbound/vless[x]: failed to dial',
      ];
      for (final l in keep) {
        expect(isNoiseLine(l), isFalse, reason: l);
      }
    });
  });

  group('the program behind a connection (found package name)', () {
    const found = '[2 0ms] router: found package name: org.telegram.messenger';
    const foundPath = r'[3 0ms] router: found process path: C:\Program Files\App\app.exe';

    test('is flood like the connection lines: the noise ring, never pushing the rest out', () {
      final b = LogBook(cap: 10, noiseCap: 4);
      b.note('info', 'Connected');
      b.singBox('ERROR[0001] dns: broken');
      for (var i = 0; i < 50; i++) {
        b.singBox('INFO[0001] $found');
        b.singBox('INFO[0001] $foundPath');
      }
      final l = _lines(b);
      expect(l.where((x) => x['msg'] == 'Connected'), hasLength(1));
      expect(l.where((x) => x['lvl'] == 'error'), hasLength(1));
      expect(l.where((x) => (x['msg'] as String).contains('found p')), hasLength(4), reason: 'only the last noiseCap');
      expect(isNoiseLine(found), isTrue);
      expect(isNoiseLine(foundPath), isTrue);
      expect(isNoiseLine('[1 5ms] router: match[3] => route(proxy)'), isFalse);
    });

    test('a core line that mentions it, and a warning, are not noise', () {
      final b = LogBook(cap: 3, noiseCap: 3);
      b.note('info', found);
      b.singBox('WARN[0001] $found');
      for (var i = 0; i < 10; i++) {
        b.singBox('INFO[0001] $found');
      }
      final l = _lines(b);
      expect(l.where((x) => x['src'] == 'core'), hasLength(1));
      expect(l.where((x) => x['lvl'] == 'warn'), hasLength(1));
    });

    test('since(conns: false) leaves the flood out on the core side and says how much', () {
      final b = LogBook(cap: 10, noiseCap: 10);
      b.singBox('INFO[0001] $_conn'); // 0
      b.singBox('INFO[0001] $found'); // 1
      b.singBox('INFO[0001] [4 0ms] router: match => route(proxy)'); // 2
      b.singBox('WARN[0001] [1 5ms] outbound/vless[x]: outbound connection to a:1 failed'); // 3, main ring
      b.singBox('INFO[0001] $foundPath'); // 4
      b.note('info', 'x'); // 5

      final all = b.since(null);
      expect(all.containsKey('hidden'), isFalse);
      expect((all['lines'] as List).map((x) => (x as Map)['n']), [0, 1, 2, 3, 4, 5]);

      final quiet = b.since(null, conns: false);
      expect((quiet['lines'] as List).map((x) => (x as Map)['n']), [2, 3, 5]);
      expect(quiet['hidden'], 3);
      expect(quiet['next'], 6, reason: 'numbering stays whole: the next poll asks from 6 either way');

      // a poll from a number: only what is newer is counted
      expect(b.since(4, conns: false)['hidden'], 1);
      // the same request with conns on brings the left-out lines
      expect((b.since(1)['lines'] as List).length, 5);
    });

    test('a warning in the noise ring (an ignored site) is not hidden by conns: false', () {
      final b = LogBook(cap: 10, noiseCap: 10)..ignored = IgnoredSites(['quiet.example']);
      b.singBox('WARN[0001] [9 0ms] outbound/vless[x]: outbound connection to quiet.example:443 failed');
      b.singBox('INFO[0001] $_conn');
      final r = b.since(null, conns: false);
      expect((r['lines'] as List), hasLength(1), reason: 'the failed line stays, the success goes');
      expect(r['hidden'], 1);
    });

    test('the stream stays whole', () async {
      final b = LogBook(cap: 10, noiseCap: 10);
      final got = <String>[];
      final sub = b.stream.listen((l) => got.add(l['msg'] as String));
      b.singBox('INFO[0001] $found');
      b.singBox('INFO[0001] $_conn');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(got, [found, _conn]);
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
