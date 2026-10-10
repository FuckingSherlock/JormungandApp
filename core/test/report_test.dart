// The support report: its shape, masking, the TUN summary, the plain text, and the same through
// CoreService / jormd (/api/report, /api/log?conns=0). Docs: docs/logs.md → Отчёт.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

const _secret = 'sekret-pass-123';
const _uuid = '11111111-2222-3333-4444-555555555555';

Map<String, dynamic> _plan({String password = _secret, String chosen = 'src::a', bool global = false}) => {
      'mode': 'tun',
      'mixedPort': 2080,
      'tunStack': 'mixed',
      'ipv6': false,
      'mixedAuth': {'user': 'localuser', 'pass': 'localpass-777'},
      'global': global,
      'urlTest': {'interval': 180, 'tolerance': 50},
      'auto': {'enabled': true, 'checkers': ['https://www.gstatic.com/generate_204']},
      'routes': [
        {
          'id': 'R1',
          'kind': 'chain',
          'main': {
            'pick': 'priority',
            'chosen': chosen,
            'nodes': [
              {
                'key': 'src::a',
                'outbound': {'type': 'vless', 'server': 'de1.example', 'server_port': 443, 'uuid': _uuid, 'password': password},
              },
              {
                'key': 'src::b',
                'outbound': {'type': 'trojan', 'server': 'nl1.example', 'server_port': 443, 'password': password},
              },
            ],
          },
          'entry': {
            'pick': 'fastest',
            'chosen': null,
            'nodes': [
              {
                'key': 'src::e',
                'outbound': {'type': 'shadowsocks', 'server': 'ru1.example', 'server_port': 8388, 'password': password},
              },
            ],
          },
        },
        {
          'id': 'R2',
          'kind': 'unit',
          'main': {
            'pick': 'fastest',
            'chosen': null,
            'nodes': [
              {
                'key': 'src::c',
                'outbound': {'type': 'hysteria2', 'server': 'jp1.example', 'server_port': 443, 'password': password},
              },
            ],
          },
        },
      ],
      'current': 0,
    };

Map<String, dynamic> _line(int n, String msg, {String src = 'sing-box', String lvl = 'info'}) =>
    {'n': n, 't': 1760000000000 + n * 10, 'src': src, 'lvl': lvl, 'msg': msg};

List<Map<String, dynamic>> _lines(List<String> msgs) => [for (var i = 0; i < msgs.length; i++) _line(i, msgs[i])];

const _tcp = 'inbound/tun[tun-in]: inbound connection from 10.0.0.2:5000';
const _udp = 'inbound/tun[tun-in]: inbound packet connection from 10.0.0.2:5001';
String _found(int id, String pkg) => '[$id 0ms] router: found package name: $pkg';
String _filler(int id) => '[$id 1ms] router: match[0] => route(proxy)';

void main() {
  group('tunSummary', () {
    test('a healthy stack: every look-up sits next to a connection line of its own id — no orphans', () {
      final s = tunSummary(_lines([
        _found(10, 'org.telegram.messenger'),
        '[11 0ms] $_tcp',
        _found(12, 'org.telegram.messenger'),
        _found(20, 'com.android.chrome'),
        '[21 0ms] $_udp',
        _found(30, 'com.android.chrome'),
        '[31 0ms] $_tcp',
        _found(32, 'com.android.chrome'),
        for (var i = 0; i < 8; i++) _filler(100 + i),
      ]));
      expect((s['total'] as Map)['orphan'], 0);
      expect((s['total'] as Map)['syn'], 5);
      expect([(s['total'] as Map)['tcp'], (s['total'] as Map)['udp'], (s['total'] as Map)['dns']], [2, 1, 0]);
      final pk = (s['packages'] as List).cast<Map>();
      expect(pk.map((e) => e['package']).toSet(), {'org.telegram.messenger', 'com.android.chrome'});
    });

    test('a dead TCP path: look-ups that no connection line follows are orphans of that package', () {
      final s = tunSummary(_lines([
        for (var i = 0; i < 6; i++) _found(10 + i, 'com.example.chat'),
        for (var i = 0; i < 3; i++) _found(40 + i, 'com.example.video'),
        for (var i = 0; i < 12; i++) _filler(100 + i),
        '[200 0ms] $_udp', // UDP lives on
      ]));
      final pk = {for (final e in (s['packages'] as List).cast<Map>()) e['package']: e};
      expect(pk['com.example.chat']!['syn'], 6);
      expect(pk['com.example.chat']!['orphan'], 6);
      expect(pk['com.example.video']!['orphan'], 3);
      expect((s['packages'] as List).first['package'], 'com.example.chat', reason: 'most orphans first');
      expect((s['total'] as Map)['tcp'], 0);
      expect((s['total'] as Map)['udp'], 1);
    });

    test('a look-up with an inbound line of its own id is not a look-up (mixed inbound)', () {
      final s = tunSummary(_lines([
        '[7 0ms] inbound/mixed[mixed-in]: inbound connection from 127.0.0.1:5555',
        _found(7, 'org.example.app'),
        for (var i = 0; i < 10; i++) _filler(100 + i),
      ]));
      expect((s['total'] as Map)['syn'], 0);
      expect((s['total'] as Map)['orphan'], 0);
    });

    test('desktop: the program is the file name; top limits the list and sums the rest', () {
      final s = tunSummary(
        _lines([
          for (var i = 0; i < 5; i++) r'[1' '$i 0ms] router: found process path: C:\\Program Files\\App\\app$i.exe',
          for (var i = 0; i < 12; i++) _filler(100 + i),
        ]),
        top: 2,
      );
      final pk = (s['packages'] as List).cast<Map>();
      expect(pk, hasLength(2));
      expect(pk.first['package'], matches(RegExp(r'^app\d\.exe$')));
      expect((s['others'] as Map)['packages'], 3);
      expect((s['others'] as Map)['orphan'], 3);
      expect((s['total'] as Map)['orphan'], 5);
    });

    test('the window: lines counted, sing-box only; ping / speed lines and core notes are not', () {
      final s = tunSummary([
        _line(0, '[1 0ms] router: x'),
        _line(1, 'Connected', src: 'core'),
        _line(2, '[ping] [3 0ms] router: found package name: org.a'),
        _line(3, '[4 0ms] router: y'),
      ]);
      final w = s['window'] as Map;
      expect(w['lines'], 3, reason: 'the tagged line is a sing-box line (a throwaway box) but never a look-up');
      expect((s['total'] as Map)['syn'], 0);
      expect(w['from'], lessThan(w['to'] as int));
    });
  });

  group('planHash', () {
    test('the same plan, the same hash; credentials are not part of it; a different pick is', () {
      final a = planHash(_plan());
      expect(a, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(planHash(_plan()), a);
      expect(planHash(_plan(password: 'another-secret')), a, reason: 'servers are by key, never by what they hold');
      expect(planHash(_plan(chosen: 'src::b')), isNot(a));
      expect(planHash(_plan(global: true)), isNot(a));
    });
  });

  group('buildReport', () {
    final now = DateTime.utc(2026, 10, 10, 12, 30);
    Map<String, dynamic> build({Map<String, dynamic>? plan, Map<String, dynamic> appInfo = const {}, Redactor? r}) => buildReport(
          now: now,
          appInfo: appInfo,
          version: {'core': '0.9.0', 'singBox': '1.12.0', 'dataDir': r'C:\Users\someone\data', 'dart': '3.9.0', 'os': 'android'},
          status: {
            'connected': true,
            'mode': 'tun',
            'systemProxy': false,
            'error': null,
            'warning': 'warn text with https://sub.example.com/api/xyz?token=abc',
            'exit': {'ip': '203.0.113.7', 'country': 'DE', 'city': 'Berlin', 'org': 'Example', 'direct': false, 'at': 1},
            'restarts': 1,
            'auto': {
              'now': 'R1',
              'index': 0,
              'server': 'src::a',
              'entryServer': 'src::e',
              'routes': [
                {'id': 'R1', 'ms': 45, 'fails': 0, 'oks': 9, 'at': 5, 'strikes': 0, 'holdUntil': null, 'server': 'src::a', 'entryServer': 'src::e'},
                {'id': 'R2', 'ms': null, 'fails': 3, 'oks': 0, 'at': 5, 'strikes': 1, 'holdUntil': 99, 'server': 'src::c', 'entryServer': null},
              ],
              'switches': 2,
              'lastSwitch': {'from': 'R2', 'to': 'R1', 'reason': 'failover', 'at': 4},
            },
            'network': {'status': 'online', 'since': 3, 'offline': false},
          },
          plan: plan ?? _plan(),
          upSince: now.subtract(const Duration(minutes: 10)),
          settings: {'killSwitch': true, 'closeOnSwitch': true, 'ignoredSites': 2, 'screenOn': true},
          network: {'interfaces': ['wlan0', 'tun0'], 'tunUp': true},
          events: [
            {
              'id': 0, 'at': 1760000000000, 'cat': 'sub', 'type': 'failed', 'level': 'warn', 'own': false,
              'data': {'source': 's1', 'url': 'https://sub.example.com/api/v1/Zk93jd?token=abc', 'error': 'HTTP 500'},
            },
            {
              'id': 1, 'at': 1760000001000, 'cat': 'core', 'type': 'tunTcpDead', 'level': 'error', 'own': false, 'log': 7,
              'data': {'stack': 'mixed', 'synSeen': 9, 'apps': ['org.telegram.messenger']},
            },
          ],
          lines: _lines([
            'node loaded $vlessReality',
            '[resume] hand-over: tunnel kept, engine recreated',
            '[resume] Dart: resumed',
            'fetch https://sub.example.com/api/v1/Zk93jd failed',
            _found(10, 'org.telegram.messenger'),
          ]),
          failures: {'active': true, 'top': []},
          tunIngress: {'state': 'dead'},
          redactor: r,
        );

    test('the shape', () {
      final r = build(appInfo: {
        'version': '0.9.0',
        'versionCode': 90,
        'commit': 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',
        'platform': 'android',
        'androidApi': 34,
        'device': {'model': 'Pixel 7', 'manufacturer': 'Google'},
        'libbox': '1.12.0-libbox',
        'names': {'R1': 'Germany via Moscow', 'src::a': 'Frankfurt 01'},
        'network': {'type': 'wifi', 'vpn': true},
        'settings': {'language': 'ru'},
        'planSig': 'x' * 400,
      });
      expect(r['format'], 1);
      expect(r['createdAt'], '2026-10-10T12:30:00.000Z');
      expect(r['createdAtMs'], now.millisecondsSinceEpoch);
      // app: as passed, minus what the report places elsewhere; the commit stays readable
      final app = r['app'] as Map;
      expect(app['commit'], 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678');
      expect(app['device'], {'model': 'Pixel 7', 'manufacturer': 'Google'});
      for (final k in ['names', 'libbox', 'network', 'settings', 'planSig']) {
        expect(app.containsKey(k), isFalse, reason: k);
      }
      expect(r['core'], {'version': '0.9.0', 'singBox': '1.12.0', 'libbox': '1.12.0-libbox', 'dart': '3.9.0', 'os': 'android'});

      final c = r['connection'] as Map;
      expect([c['state'], c['mode'], c['stack'], c['routing'], c['manual']], ['connected', 'tun', 'mixed', 'rules', false]);
      expect(c['uptimeMs'], 600000);
      expect(c['servers'], 4);
      expect(c['planHash'], planHash(_plan()));
      expect((c['planSig'] as String).length, 12, reason: 'a long app signature is carried as a digest');
      expect(c['exit'], {'country': 'DE', 'direct': false, 'at': 1}, reason: 'no IP address in the report');
      final routes = (c['routes'] as List).cast<Map>();
      expect(routes.map((e) => [e['id'], e['kind'], e['servers'], e['current']]), [
        ['R1', 'chain', 2, true],
        ['R2', 'unit', 1, false],
      ]);
      expect(routes.first['name'], 'Germany via Moscow');
      expect((routes.first['health'] as Map)['ms'], 45);
      expect((routes.first['health'] as Map)['serverName'], 'Frankfurt 01');
      expect((routes.last['health'] as Map)['fails'], 3);
      expect((c['current'] as Map)['id'], 'R1');
      expect((c['current'] as Map)['serverName'], 'Frankfurt 01');
      expect((c['auto'] as Map)['switches'], 2);

      final s = r['settings'] as Map;
      expect([s['killSwitch'], s['mixedPort'], s['tunStack'], s['mixedAuth']], [true, 2080, 'mixed', true]);
      expect(s['app'], {'language': 'ru'});
      expect(s.keys, isNot(contains('mixedAuthUser')));

      final n = r['network'] as Map;
      expect([n['status'], n['interfaces'], n['tunUp']], ['online', ['wlan0', 'tun0'], true]);
      expect(n['host'], {'type': 'wifi', 'vpn': true});

      final k = r['counters'] as Map;
      expect(k['rings'], {'lines': 5, 'events': 2});
      expect(k['failures'], {'active': true, 'top': []});
      expect(k['tunIngress'], {'state': 'dead'});
      expect((k['tun'] as Map)['window'], containsPair('lines', 5));

      expect((r['events'] as List), hasLength(2));
      expect(((r['events'] as List).last as Map)['data'], containsPair('synSeen', 9));
      expect((r['raw'] as List), hasLength(5));
      expect((r['resume'] as List), hasLength(2));
      expect(((r['resume'] as List).first as Map)['msg'], startsWith('[resume] hand-over'));
    });

    test('nothing secret survives, anywhere; names and hosts do; the count says what was masked', () {
      final r = build();
      final text = jsonEncode(r);
      for (final bad in [_secret, 'localpass-777', _uuid, 'Zk93jd', 'abc', 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw', '6ba85179e30d4fc2', '203.0.113.7']) {
        expect(text, isNot(contains(bad)), reason: bad);
      }
      expect(text, contains('de1.example'));
      expect(text, contains('sub.example.com'));
      expect(text, contains('org.telegram.messenger'));
      final red = r['redactions'] as Map;
      expect(red['total'], greaterThan(0));
      expect((red['byKind'] as Map).keys, containsAll(['link', 'secret', 'url']));
      // the report is JSON all the way
      expect(jsonDecode(text), isA<Map>());
    });

    test('a disconnected core: no plan sections, no uptime', () {
      final r = buildReport(now: now, status: {'connected': false, 'mode': null}, plan: null);
      final c = r['connection'] as Map;
      expect(c['state'], 'disconnected');
      expect(c.containsKey('uptimeMs'), isFalse);
      expect(c.containsKey('routes'), isFalse);
      expect(r['events'], isEmpty);
      expect(r['raw'], isEmpty);
      expect((r['counters'] as Map)['failures'], isNull);
    });

    test('reportToText: the header, the events with their data and the raw lines', () {
      final t = reportToText(build(appInfo: {'version': '0.9.0'}));
      expect(t, startsWith('Jormungand report (format 1)'));
      expect(t, contains('created: 2026-10-10T12:30:00.000Z'));
      expect(t, contains('## Connection'));
      expect(t, contains('core/tunTcpDead'));
      expect(t, contains('"synSeen":9'));
      expect(t, contains('## Raw log (5 lines)'));
      expect(t, contains('org.telegram.messenger'));
      expect(t, isNot(contains(_secret)));
      expect(t, isNot(contains(_uuid)));
    });
  });

  group('CoreService.report', () {
    late Directory tmp;
    late CoreService svc;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-report');
      svc = CoreService(
        singBox: 'none',
        dataDir: p.join(tmp.path, 'data'),
        runner: _Runner(),
        sysProxy: NoSystemProxy(),
        exitCheck: (_) async => {'ip': '127.0.0.1', 'country': 'ZZ'},
        knownSingBoxVersion: '1.12.0',
      );
      await svc.init();
    });
    tearDown(() async {
      await svc.dispose();
      await tmp.delete(recursive: true);
    });

    test('from memory: status, plan, trackers, rings and events in one map, secrets masked', () async {
      await svc.connect({
        'plan': {
          'routes': [
            {
              'id': 'A',
              'kind': 'unit',
              'main': {
                'pick': 'priority',
                'chosen': 's::a',
                'nodes': [
                  {
                    'key': 's::a',
                    'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': _secret},
                  },
                ],
              },
            },
          ],
          'mixedPort': 2080,
          'global': true,
        },
        'systemProxy': false,
        'killSwitch': true,
      });
      svc.logBook.singBox('INFO[0001] [5 0ms] router: found package name: org.example.app');
      svc.logBook.note('warn', 'could not load $vlessReality');
      svc.eventBook.add('sub', 'failed', 'warn', data: {'source': 's1', 'error': 'password=$_secret'});

      final r = await svc.report(appInfo: {'version': '0.9.0', 'platform': 'test'});
      expect(r['format'], 1);
      expect((r['app'] as Map)['version'], '0.9.0');
      expect((r['core'] as Map)['singBox'], '1.12.0');
      final c = r['connection'] as Map;
      expect([c['state'], c['mode'], c['routing']], ['connected', 'proxy', 'global']);
      expect((c['routes'] as List), hasLength(1));
      final s = r['settings'] as Map;
      expect([s['killSwitch'], s['closeOnSwitch'], s['dnsAuto'], s['ignoredSites'], s['screenOn']], [true, true, true, 0, true]);
      expect((r['counters'] as Map).containsKey('failures'), isTrue);
      expect((r['counters'] as Map).containsKey('tunIngress'), isTrue);
      expect(((r['counters'] as Map)['rings'] as Map)['events'], (r['events'] as List).length);
      final raw = (r['raw'] as List).cast<Map>().map((l) => l['msg'] as String).toList();
      expect(raw.any((m) => m.contains('found package name: org.example.app')), isTrue, reason: 'the noise ring is in');
      expect(raw.any((m) => m.startsWith('could not load vless://')), isTrue);
      expect((r['events'] as List).any((e) => (e as Map)['type'] == 'failed'), isTrue);
      final text = jsonEncode(r);
      for (final bad in [_secret, _uuid, 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw', '6ba85179e30d4fc2']) {
        expect(text, isNot(contains(bad)), reason: bad);
      }
      expect(text, contains('de1.example'));
      expect(r['redactions'], containsPair('total', greaterThan(0)));
    });

    test('before any connection it still answers', () async {
      final r = await svc.report();
      expect((r['connection'] as Map)['state'], 'disconnected');
      expect(r['app'], isEmpty);
    });
  });

  group('jormd', () {
    late HttpServer server;
    late Daemon d;
    late Directory tmp;
    final client = HttpClient();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jormd-report');
      d = Daemon(
        singBox: 'no-sing-box',
        dataDir: tmp.path,
        uiFile: 'none',
        exitCheck: (_) async => throw StateError('no exit probes in tests'),
        sysProxy: _NoSysProxy(),
        process: _Runner(),
      );
      await d.init();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(d.handle);
    });
    tearDown(() async {
      await server.close(force: true);
      await d.shutdown();
      await tmp.delete(recursive: true);
    });

    Future<(int, dynamic)> call(String method, String path, [Object? body]) async {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      req.headers.set('X-Jorm', '1');
      if (body != null) req.add(utf8.encode(jsonEncode(body)));
      final res = await req.close();
      return (res.statusCode, jsonDecode(await utf8.decodeStream(res)));
    }

    test('GET /api/report; POST carries appInfo', () async {
      d.log.note('info', 'hello');
      var (code, r) = await call('GET', '/api/report');
      expect(code, 200);
      expect(r['format'], 1);
      expect((r['raw'] as List).any((l) => (l as Map)['msg'] == 'hello'), isTrue);
      expect(r['app'], isEmpty);

      (code, r) = await call('POST', '/api/report', {
        'appInfo': {'version': 'mockup', 'platform': 'web'},
      });
      expect(code, 200);
      expect(r['app'], {'version': 'mockup', 'platform': 'web'});
    });

    test('GET /api/log?conns=0 leaves the connection flood out and counts it', () async {
      d.log.singBox('INFO[0001] [1 5ms] inbound/mixed[mixed-in]: inbound connection to example.com:443');
      d.log.singBox('INFO[0001] ${_found(2, 'org.example.app')}');
      d.log.note('info', 'x');
      var (_, r) = await call('GET', '/api/log');
      expect((r['lines'] as List), hasLength(3));
      expect(r.containsKey('hidden'), isFalse);
      (_, r) = await call('GET', '/api/log?conns=0');
      expect((r['lines'] as List).map((l) => (l as Map)['msg']), ['x']);
      expect(r['hidden'], 2);
      expect(r['next'], 3);
      (_, r) = await call('GET', '/api/log?since=1&conns=0');
      expect(r['hidden'], 1);
    });
  });
}

class _NoSysProxy extends SystemProxy {
  _NoSysProxy() : super(File('never-written'));
  @override
  bool get isSet => false;
  @override
  Future<void> restore() async {}
}

/// A runner that is not sing-box: starts when told to, has no API service.
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
