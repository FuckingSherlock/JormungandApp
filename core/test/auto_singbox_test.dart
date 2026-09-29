// AutoService and crash recovery with the real sing-box, on loopback only: two
// shadowsocks "servers" (sing-box processes) in front of a local HTTP target, our client
// config with two routes, servers stopped and started again. Free ports, nothing leaves
// the machine (the daemon's exit check is replaced). Skipped when the binary is missing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

Map<String, dynamic> _ssServer(int port) => {
      'log': {'level': 'warn'},
      'inbounds': [
        {'type': 'shadowsocks', 'listen': '127.0.0.1', 'listen_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      // `target.test` = the loopback, known only to the servers: a client request to it
      // carries no IP, so the local-networks rule (always direct) does not catch it
      'dns': {
        'servers': [
          {'type': 'hosts', 'tag': 'hosts', 'predefined': {'target.test': '127.0.0.1'}},
        ],
      },
      'route': {'default_domain_resolver': 'hosts'},
    };

Map<String, dynamic> _node(String key, int port) => {
      'key': key,
      'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': port, 'method': 'aes-128-gcm', 'password': 'loopback'},
    };

class _Loop {
  late HttpServer target;
  late Directory tmp;
  final servers = <String, (SingBoxProcess, int port)>{};

  String get url => 'http://127.0.0.1:${target.port}/';
  String get hostUrl => 'http://target.test:${target.port}/'; // through the tunnel only

  Future<void> up(List<String> names) async {
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello from target')
      ..close());
    tmp = await Directory.systemTemp.createTemp('jorm-auto');
    for (final n in names) {
      final s = (SingBoxProcess(_bin, p.join(tmp.path, n)), await freePort());
      servers[n] = s;
      await start(n);
    }
  }

  Future<void> start(String n) async {
    final (sb, port) = servers[n]!;
    await sb.start(_ssServer(port));
  }

  Future<void> stop(String n) => servers[n]!.$1.stop();
  int port(String n) => servers[n]!.$2;

  Future<void> down() async {
    for (final s in servers.values) {
      await s.$1.stop();
    }
    await target.close(force: true);
    await tmp.delete(recursive: true);
  }
}

/// The system proxy as the daemon sees it, without the registry: records the calls.
class _FakeSysProxy extends SystemProxy {
  _FakeSysProxy() : super(File('never-written'));
  final calls = <String>[];
  bool _on = false;

  @override
  bool get isSet => _on;

  @override
  Future<String?> enable(int port) async {
    calls.add('enable');
    _on = true;
    return null;
  }

  @override
  Future<void> restore() async {
    if (_on) calls.add('restore');
    _on = false;
  }
}

Future<String> _get(int mixedPort, String url) async {
  final http = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixedPort';
  try {
    final res = await (await http.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 5));
    return await res.transform(utf8.decoder).join();
  } finally {
    http.close(force: true);
  }
}

void main() {
  test('Auto moves between routes and back through the Clash API, with no restart', () async {
    final loop = _Loop();
    await loop.up(['a', 'b']);
    final mixed = await freePort();
    final client = SingBoxProcess(_bin, p.join(loop.tmp.path, 'client'));
    try {
      final plan = {
        'routes': [
          {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [_node('s::a', loop.port('a'))]}},
          {'id': 'B', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::b', 'nodes': [_node('s::b', loop.port('b'))]}},
        ],
        'current': 0,
        'mixedPort': mixed,
        'global': true,
        'urlTest': {'url': loop.url, 'interval': 60},
      };
      final probe = Probe(await freePort());
      await client.start(buildConfig(plan, probe: probe));
      final pid = client.pid;
      expect(client.api, isNotNull);

      final auto = AutoService(client.api!, plan, delay: probe.delayTest,
          settings: AutoSettings(failAfter: 1, threshold: 5000, flapGuard: false, url: loop.url, timeoutMs: 1500, firstCheck: const Duration(days: 1)));
      await auto.check();
      expect(auto.toJson()['now'], 'A');
      expect(await _get(mixed, loop.url), 'hello from target');

      await loop.stop('a');
      await auto.check();
      expect(auto.toJson()['now'], 'B');
      expect(await _get(mixed, loop.url), 'hello from target');

      await loop.start('a');
      await auto.check();
      expect(auto.toJson()['now'], 'A');
      expect(client.api!.groups['proxy']?.selected, 'route0');
      expect(client.pid, pid, reason: 'sing-box was never restarted');
      auto.stop();
    } finally {
      await client.stop();
      await loop.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('routes + rules + tunnel-in: sing-box check passes; the main flow, final and tunnel-in follow the Auto selector, a rule target does not', () async {
    final loop = _Loop();
    await loop.up(['a', 'b']);
    final side = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    side.listen((r) => r.response
      ..write('side')
      ..close());
    final mixed = await freePort(), tunnel = await freePort();
    final client = SingBoxProcess(_bin, p.join(loop.tmp.path, 'client'));
    Future<String?> tryGet(int port, String url) => _get(port, url).then<String?>((b) => b, onError: (_) => null);
    try {
      final plan = {
        'routes': [
          {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [_node('s::a', loop.port('a'))]}},
          {'id': 'B', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::b', 'nodes': [_node('s::b', loop.port('b'))]}},
        ],
        'current': 0,
        'mixedPort': mixed,
        'urlTest': {'url': loop.url},
        'routing': {
          'targets': {
            'src:x': {
              'kind': 'unit',
              'main': {'pick': 'fastest', 'nodes': [{'key': 'x::0', 'outbound': {'type': 'direct'}}]},
            },
          },
          'rules': [
            {
              'id': 'r1', 'name': '', 'action': 'proxy', 'target': 'src:x', 'fallback': 'default', 'block': 'drop', 'dns': 'auto',
              'groups': {'port': {'not': false, 'v': {'port': ['${side.port}']}}},
            },
          ],
          'quick': {'final': 'proxy'},
        },
      };
      final probe = Probe(await freePort());
      final config = buildConfig(plan, tunnelPort: tunnel, probe: probe);
      final f = File(p.join(loop.tmp.path, 'routes-rules.json'))..writeAsStringSync(jsonEncode(config));
      final r = await Process.run(_bin, ['check', '-c', f.path, '--disable-color']);
      expect(r.exitCode, 0, reason: '${r.stderr}${r.stdout}');
      final route = config['route'] as Map, outs = (config['outbounds'] as List).cast<Map>();
      expect(route['final'], topTag);
      expect(route['rules'], contains(equals({'inbound': ['tunnel-in'], 'action': 'route', 'outbound': topTag})));
      expect((route['rules'] as List).cast<Map>().any((x) => x['outbound'] == 'src:x~proxy'), isTrue);
      expect(outs.firstWhere((o) => o['tag'] == topTag)['outbounds'], ['route0', 'route1']);

      await client.start(config);
      expect(await _get(mixed, loop.hostUrl), 'hello from target');
      expect(await _get(mixed, 'http://127.0.0.1:${side.port}/'), 'side');

      await loop.stop('a'); // route A down: the main flow and tunnel-in with it, the rule target not
      expect(await tryGet(mixed, loop.hostUrl), isNot('hello from target'));
      expect(await tryGet(tunnel, loop.hostUrl), isNot('hello from target'));
      expect(await _get(mixed, 'http://127.0.0.1:${side.port}/'), 'side');

      final auto = AutoService(client.api!, plan, delay: probe.delayTest, settings: AutoSettings(failAfter: 1, url: loop.url, timeoutMs: 1500, firstCheck: const Duration(days: 1)));
      await auto.check();
      expect(auto.toJson()['now'], 'B');
      expect(await _get(mixed, loop.hostUrl), 'hello from target');
      expect(await _get(tunnel, loop.hostUrl), 'hello from target');
      auto.stop();
    } finally {
      await client.stop();
      await side.close(force: true);
      await loop.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('routes with a chain and a Priority exit: sing-box takes the config, the chain enters through its own entry', () async {
    final loop = _Loop();
    await loop.up(['a', 'b']);
    final mixed = await freePort();
    final client = SingBoxProcess(_bin, p.join(loop.tmp.path, 'client'));
    try {
      final a = _node('s::a', loop.port('a')), b = _node('s::b', loop.port('b'));
      final plan = {
        'routes': [
          {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [a, b]}},
          {
            'id': 'X',
            'kind': 'chain',
            'entry': {'pick': 'fastest', 'nodes': [a]},
            'main': {'pick': 'priority', 'chosen': 's::b', 'nodes': [a, b]},
          },
        ],
        'current': 1,
        'mixedPort': mixed,
        'global': true,
        'urlTest': {'url': loop.url},
      };
      final probe = Probe(await freePort());
      await client.start(buildConfig(plan, probe: probe));
      // the groups stream's first snapshot (sing-box's own async push) may not have
      // arrived yet right after start(): wait for the chain's entry group to show up
      for (var i = 0; i < 50 && !client.api!.groups.containsKey('route1-entry'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final auto = AutoService(client.api!, plan, delay: probe.delayTest, settings: AutoSettings(url: loop.url, timeoutMs: 1500, firstCheck: const Duration(days: 1)));
      await auto.check();
      final j = auto.toJson();
      expect([j['now'], j['server'], j['entryServer']], ['X', 's::b', 's::a']);
      expect(await _get(mixed, loop.url), 'hello from target');
      auto.stop();
    } finally {
      await client.stop();
      await loop.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('Fastest: urltest re-picks at once when its server stops answering', () async {
    final loop = _Loop();
    await loop.up(['a', 'b']);
    final mixed = await freePort();
    final client = SingBoxProcess(_bin, p.join(loop.tmp.path, 'client'));
    try {
      final plan = {
        'routes': [
          {
            'id': 'A',
            'kind': 'unit',
            'main': {
              'pick': 'fastest',
              'nodes': [_node('s::a', loop.port('a')), _node('s::b', loop.port('b'))],
            },
          },
        ],
        'mixedPort': mixed,
        'global': true,
        'urlTest': {'url': loop.url, 'interval': 600},
      };
      final probe = Probe(await freePort());
      await client.start(buildConfig(plan, probe: probe));
      final auto = AutoService(client.api!, plan, delay: probe.delayTest,
          settings: AutoSettings(failAfter: 2, url: loop.url, timeoutMs: 1500, firstCheck: const Duration(days: 1)));
      // urltest's own first round picks one; wait for it
      for (var i = 0; i < 50 && auto.toJson()['server'] == null; i++) {
        await auto.refresh();
        if (auto.toJson()['server'] == null) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final first = auto.toJson()['server'] as String;
      await loop.stop(first == 's::a' ? 'a' : 'b');
      // sing-box's URLTest RPC (testGroup) ignores a forced re-test called too soon after
      // the previous one (an internal cooldown, observed on loopback, outside our control):
      // retry the round for a while instead of a single check().
      Map<String, dynamic> j = auto.toJson();
      for (var i = 0; i < 20 && j['server'] == first; i++) {
        await auto.check();
        j = auto.toJson();
        if (j['server'] == first) await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      expect(j['server'], isNot(first));
      expect((j['routes'] as List).first['fails'], 0);
      expect(await _get(mixed, loop.url), 'hello from target');
      auto.stop();
    } finally {
      await client.stop();
      await loop.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('daemon: sing-box killed from outside: started again in the background, the system proxy never released', () async {
    final loop = _Loop();
    await loop.up(['a']);
    final mixed = await freePort();
    final sys = _FakeSysProxy();
    final daemon = Daemon(
      singBox: _bin,
      dataDir: p.join(loop.tmp.path, 'data'),
      uiFile: p.join(loop.tmp.path, 'none.html'),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sysProxy: sys,
    );
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api.listen(daemon.handle);
    Future<Map<String, dynamic>> call(String path, [Map<String, dynamic>? body]) async {
      final c = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final req = await c.openUrl(body == null ? 'GET' : 'POST', Uri.parse('http://127.0.0.1:${api.port}$path'));
        req.headers.set('X-Jorm', '1');
        if (body != null) req.write(jsonEncode(body));
        final res = await req.close();
        return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>();
      } finally {
        c.close(force: true);
      }
    }

    try {
      final st = await call('/api/connect', {
        'plan': {
          'routes': [
            {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [_node('s::a', loop.port('a'))]}},
          ],
          'mixedPort': mixed,
          'global': true,
          'urlTest': {'url': loop.url},
        },
        'systemProxy': true,
      });
      expect(st['connected'], isTrue);
      expect(st['systemProxy'], isTrue);
      expect((st['auto'] as Map)['now'], 'A');
      final pid = daemon.main.pid!;
      Process.killPid(pid);
      Map<String, dynamic> s = {};
      var sawRecovering = false, sysOffWhileDown = false, connectedDropped = false;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        s = await call('/api/status');
        connectedDropped |= s['connected'] == false;
        if (s['recovering'] != null) {
          sawRecovering = true;
          sysOffWhileDown |= s['systemProxy'] == false;
        }
        if (s['restarts'] == 1 && s['recovering'] == null) break;
      }
      expect(sawRecovering, isTrue);
      expect(sysOffWhileDown, isFalse, reason: 'the system proxy stays while sing-box restarts');
      expect(connectedDropped, isFalse);
      expect([s['connected'], s['restarts'], s['error'], s['systemProxy'], s['down']], [true, 1, null, true, null]);
      expect(sys.calls, ['enable']);
      expect(daemon.main.pid, isNot(pid));
      expect(await _get(mixed, loop.url), 'hello from target');
      final off = await call('/api/disconnect', {});
      expect([off['connected'], off['systemProxy']], [false, false]);

      // the journal: connect (the user's), the crash, the restart (the core's, no proxy events:
      // it was never taken off), disconnect (the user's)
      final ev = [
        for (final e in (await call('/api/events'))['events'] as List)
          if ((e as Map)['type'] != 'deprecated') e,
      ];
      expect([for (final e in ev) '${e['cat']}/${e['type']}'], [
        'core/sysProxy',
        'conn/connected',
        'core/crashed',
        'core/restarted',
        'conn/disconnected',
        'core/sysProxy',
      ]);
      expect([for (final e in ev) e['own']], [true, true, false, false, true, true]);
      expect([for (final e in ev) (e['data'] as Map)['on']], [true, null, null, null, null, false]);
      expect(ev[1]['data'], {'entry': 'A', 'mode': 'proxy', 'route': 'global', if ((ev[1]['data'] as Map).containsKey('server')) 'server': isA<String>()});
      expect(ev[2]['data'], {'code': isA<int>()});
      expect(ev[2]['level'], 'error');
      expect(ev[3]['data'], {'attempt': 1});
      expect(ev[4]['data'], {'by': 'user'});
      expect(ev.every((e) => e['log'] is int), isTrue, reason: 'every one of them wrote its raw line');
    } finally {
      await daemon.shutdown();
      await api.close(force: true);
      await loop.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

  test('daemon: an Auto failover is an auto/switched event, with the raw line it links to', () async {
    final loop = _Loop();
    await loop.up(['a', 'b']);
    await loop.stop('a'); // route A is dead from the start: the first check moves to B
    final mixed = await freePort();
    final daemon = Daemon(
      singBox: _bin,
      dataDir: p.join(loop.tmp.path, 'data'),
      uiFile: p.join(loop.tmp.path, 'none.html'),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sysProxy: _FakeSysProxy(),
    );
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api.listen(daemon.handle);
    Future<Map<String, dynamic>> call(String path, [Map<String, dynamic>? body]) async {
      final c = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final req = await c.openUrl(body == null ? 'GET' : 'POST', Uri.parse('http://127.0.0.1:${api.port}$path'));
        req.headers.set('X-Jorm', '1');
        if (body != null) req.write(jsonEncode(body));
        final res = await req.close();
        return (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>();
      } finally {
        c.close(force: true);
      }
    }

    try {
      await call('/api/connect', {
        'plan': {
          'routes': [
            {'id': 'A', 'kind': 'unit', 'main': {'pick': 'fastest', 'nodes': [_node('s::a', loop.port('a'))]}},
            {'id': 'B', 'kind': 'unit', 'main': {'pick': 'priority', 'chosen': 's::b', 'nodes': [_node('s::b', loop.port('b'))]}},
          ],
          'mixedPort': mixed,
          'global': true,
          'urlTest': {'url': loop.url},
          'auto': {'failAfter': 1, 'checkers': <String>[], 'returnTo': 'never', 'retryPause': 0.1},
        },
        'systemProxy': false,
      });
      List<Map> switched = [];
      for (var i = 0; i < 100 && switched.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        switched = [
          for (final e in (await call('/api/events'))['events'] as List)
            if ((e as Map)['cat'] == 'auto') e,
        ];
      }
      expect(switched, hasLength(1));
      final e = switched.single;
      expect([e['type'], e['level'], e['own']], ['switched', 'info', false]);
      expect(e['data'], {'from': 'A', 'to': 'B', 'reason': 'failover'});
      final raw = ((await call('/api/log'))['lines'] as List).cast<Map>();
      expect(raw.firstWhere((l) => l['n'] == e['log'])['msg'], contains('auto: A → B (failover)'));
      expect((await call('/api/status'))['auto']['now'], 'B');
    } finally {
      await daemon.shutdown();
      await api.close(force: true);
      await loop.down();
    }
  }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
}
