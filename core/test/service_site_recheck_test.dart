// CoreService as the site events and the live Priority order need it (docs/connect-model.md 466-480 and 936-950):
// (A) a site event from the connection book stores the node key of its outbound (`server`, `sid::nid`), never the raw
// tag; (B) `applyOrder(plan)`: only the Priority order of a group differs -> applied, no sing-box restart, the restart
// after a crash uses the new order; anything else -> not applied, nothing changes; (C) `recheckSite(id)`: the probe
// ladder of the first verdict again, the same event changed in place (`data.checks`), an opening site closes it as a
// pair (`data.reopened`), one run at a time, unknown / not a site event / VPN off -> ok false.
// A fake sing-box runner (no process; it counts its starts and keeps each config), the probes are the seams
// (probeSame / probeScout / probeElsewhere), time by hand (FakeTime).
import 'dart:async';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

/// An API service that is not sing-box's (no groups, no connections), so Auto starts on a running core.
class _Api extends SingBoxApi {
  _Api() : super(0, '');
  @override
  Map<String, String> get selected => const {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async => true;
  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => true;
  @override
  Future<bool> closeAllConnections() async => true;
  @override
  Stream<ClosedConnection> closedConnections() => const Stream.empty();
  @override
  void watch() {}
  @override
  Future<void> close() async {}
}

class _Runner implements BoxRunner {
  bool up = false;
  bool withApi = false;
  /// Every config the runner was started with, in order: `configs.length` is the number of starts.
  final configs = <Map<String, dynamic>>[];
  final _api = _Api();
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;

  @override
  bool get running => up;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => up && withApi ? _api : null;
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async {
    configs.add(config);
    up = true;
  }

  @override
  Future<void> stop() async => up = false;
}

const _nodes = ['src1::n1', 'src1::n2', 'src2::n3']; // the Priority order of route A, the first one is chosen
const _reordered = ['src1::n1', 'src2::n3', 'src1::n2']; // the first place kept, the other two swapped
const _tags = ['route0/src1::n1', 'route0/src1::n2', 'route0/src2::n3'];
const _reorderedTags = ['route0/src1::n1', 'route0/src2::n3', 'route0/src1::n2'];

/// The plan the app sends: one unit route whose main group is a Priority group over [nodes].
Map<String, dynamic> _plan({List<String> nodes = _nodes, int mixedPort = 2080, bool global = true}) => {
      'routes': [
        {
          'id': 'A',
          'kind': 'unit',
          'main': {
            'pick': 'priority',
            'chosen': nodes.first,
            'nodes': [
              for (final k in nodes)
                {
                  'key': k,
                  'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
            ],
          },
        },
      ],
      'mixedPort': mixedPort,
      'global': global,
    };

/// The order [tags] have in the first list of the config that holds all of them (the group the Priority order is in).
List<String> orderIn(Map<String, dynamic> config, List<String> tags) {
  List<Object?>? found;
  void walk(Object? v) {
    if (found != null) return;
    if (v is List && tags.every(v.contains)) {
      found = v;
      return;
    }
    if (v is Map) v.values.forEach(walk);
    if (v is List) v.forEach(walk);
  }

  walk(config);
  if (found == null) throw TestFailure('no list of the config holds ${tags.join(', ')}');
  return [for (final x in found!) if (tags.contains(x)) x as String];
}

ClosedConnection _closed({String dest = 'example.org:443', int down = 0, int? ms = 5000, String outbound = 'route0/src1::n1'}) => ClosedConnection(
      rule: '',
      outbound: outbound,
      chain: [outbound, 'route0', 'proxy'],
      destination: dest,
      up: 0,
      down: down,
      pkg: 'org.example.app',
      process: '',
      network: 'tcp',
      inbound: 'tun-in',
      durationMs: ms,
    );

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;
  late FakeTime time;

  Future<void> start({bool connected = true, bool api = false, List<String> nodes = _nodes}) async {
    tmp = await Directory.systemTemp.createTemp('jorm-site-recheck');
    runner = _Runner()..withApi = api;
    time = FakeTime();
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false, // hermetic: no real DoH
      directProbe: (_, _) async => 5, // hermetic: the direct path answers
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      // never the real check-host.net: a checker whose every request fails
      siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
    );
    await svc.init();
    if (connected) {
      await svc.connect({'plan': _plan(nodes: nodes)});
      await time.advanceSeconds(6); // settled: 5 s after the start
    }
  }

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  List<Map> events(String cat, String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat && e['type'] == type) e,
      ];
  Map eventById(int id) => (svc.events()['events'] as List).cast<Map>().firstWhere((e) => e['id'] == id);
  List<String> types() => [for (final e in (svc.events()['events'] as List).cast<Map>()) '${e['cat']}/${e['type']}'];
  /// The one site/blocked of the test; the journal's types say what came instead when it is missing.
  Map siteBlocked() {
    final all = events('site', 'blocked');
    if (all.length != 1) throw TestFailure('want one site/blocked, got ${all.length}: ${types()} ${events('conn', 'vpnDown')} ${events('conn', 'failing')}');
    return all.single;
  }
  void fail(int n, {String outbound = 'route0/src1::n1', String dest = 'example.org:443'}) {
    for (var i = 0; i < n; i++) {
      svc.failures.onClosed(_closed(dest: dest, outbound: outbound));
    }
  }

  /// A crashed sing-box is started again by the core with the stored plan (after a pause of a second or so).
  Future<void> crashAndRestart() async {
    final n = runner.configs.length;
    runner.up = false;
    runner.onExit!(9);
    for (var i = 0; i < 600 && runner.configs.length == n; i++) {
      await time.advance(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(runner.configs.length, n + 1, reason: 'restarted once, with the stored plan');
  }

  /// A site that does not open through its server but opens through another route: the site/blocked of the first verdict.
  Future<int> blockedSite() async {
    await start(nodes: const ['src1::n1']);
    svc.probeSame = (o, d, c) async => false;
    svc.probeScout = (o, d, c) async => const AltReach(via: 'route1', viaServer: 'src2::n3');
    svc.probeElsewhere = (o, d, s, c) async => const AltReach();
    fail(3);
    await time.advanceSeconds(11);
    return siteBlocked()['id'] as int;
  }

  group('site events store node keys', () {
    test('a site/blocked from the connection book: data.server is the node key of the outbound, and the raw note names both nodes', () async {
      await start(nodes: const ['src1::n1']);
      svc.probeSame = (o, d, c) async => false;
      svc.probeScout = (o, d, c) async => const AltReach(via: 'route1', viaServer: 'src2::n3');
      svc.probeElsewhere = (o, d, s, c) async => const AltReach();
      fail(3); // outbound route0/src1::n1, the evidence of the connection book carries no `noticed`
      await time.advanceSeconds(11);
      final e = siteBlocked();
      expect(e['data'], containsPair('server', 'src1::n1'));
      final lines = [for (final l in (svc.log()['lines'] as List).cast<Map>()) '${l['msg']}'];
      expect(lines.any((m) => m.contains('src1::n1') && m.contains('src2::n3')), isTrue, reason: 'the note names the failed node and the one it opened through: $lines');
    });

    test('a conn/failing of the same outbound carries the node key as well', () async {
      await start(nodes: const ['src1::n1']);
      svc.probeSame = (o, d, c) async {
        fail(1); // the app's own request fails while the probe goes: a confirmed conn/failing
        return true;
      };
      svc.probeScout = (o, d, c) async => const AltReach();
      svc.probeElsewhere = (o, d, s, c) async => const AltReach();
      fail(3);
      await time.advanceSeconds(11);
      final e = events('conn', 'failing').single;
      expect(e['data'], containsPair('server', 'src1::n1'));
    });
  });

  group('applyOrder: the Priority order live', () {
    test('only the order of a Priority group differs: applied, no restart, no reconnect, and the restart after a crash uses the new order', () async {
      await start(api: true);
      final starts = runner.configs.length;
      final r = await svc.applyOrder(_plan(nodes: _reordered));
      expect(r, containsPair('applied', true));
      expect(runner.configs.length, starts, reason: 'sing-box is not restarted');
      expect(events('conn', 'reconnected'), isEmpty);
      expect(orderIn(runner.configs.last, _tags), isNot(_reorderedTags), reason: 'the config the core started with has the old order');
      await crashAndRestart();
      expect(orderIn(runner.configs.last, _tags), _reorderedTags, reason: 'the stored plan has the new order');
    });

    for (final (name, plan) in <(String, Map<String, dynamic>)>[
      ('a server added', _plan(nodes: [..._reordered, 'src3::n9'])),
      ('the mixed port changed', _plan(nodes: _reordered, mixedPort: 2081)),
      ('global changed besides the order', _plan(nodes: _reordered, global: false)),
    ]) {
      test('$name besides the order: not applied, nothing changes', () async {
        await start(api: true);
        final before = orderIn(runner.configs.last, _tags);
        final starts = runner.configs.length;
        expect(await svc.applyOrder(plan), containsPair('applied', false));
        expect(runner.configs.length, starts);
        await crashAndRestart();
        expect(orderIn(runner.configs.last, _tags), before, reason: 'the restart keeps the old plan');
      });
    }

    test('nothing runs: not applied', () async {
      await start(connected: false);
      expect(await svc.applyOrder(_plan(nodes: _reordered)), containsPair('applied', false));
    });
  });

  group('recheckSite: Check again', () {
    test('still blocked: the same event changed in place (rev up, the previous result in checks), no new event, the ladder from the failed server', () async {
      final id = await blockedSite();
      final rev = (eventById(id)['rev'] as int?) ?? 0;
      final linesBefore = (svc.log()['lines'] as List).length;
      final asked = <String>[];
      svc.probeSame = (o, d, c) async {
        asked.add(o);
        return false;
      };
      svc.probeScout = (o, d, c) async => const AltReach(via: 'route1', viaServer: 'src2::n3');
      final r = await svc.recheckSite(id);
      expect([r['ok'], r['result']], [true, 'blocked']);
      expect(asked.single, contains('src1::n1'), reason: 'through the server the site did not open through first');
      final e = eventById(id);
      expect([e['id'], e['cat'], e['type']], [id, 'site', 'blocked']);
      expect(e['rev'], greaterThan(rev));
      expect(events('site', 'blocked'), hasLength(1), reason: 'no new event');
      expect(types().where((t) => t == 'site/unreachable'), isEmpty);
      final data = e['data'] as Map;
      expect(data, containsPair('server', 'src1::n1'));
      final checks = (data['checks'] as List).cast<Map>();
      expect(checks, hasLength(1));
      expect(checks.single, allOf(containsPair('kind', 'blocked'), containsPair('server', 'src1::n1'), containsPair('at', isNotNull)));
      expect((svc.log()['lines'] as List).length, greaterThan(linesBefore), reason: 'a raw note of the recheck');
    });

    test('nothing opens it now: result unreachable, the same event id, the earlier result kept in checks', () async {
      final id = await blockedSite();
      svc.probeSame = (o, d, c) async => false;
      svc.probeScout = (o, d, c) async => const AltReach(tried: [(route: 'route1', server: 'src2::n3')]);
      svc.probeElsewhere = (o, d, s, c) async => const AltReach();
      final r = await svc.recheckSite(id);
      expect([r['ok'], r['result']], [true, 'unreachable']);
      expect(eventById(id)['id'], id);
      final checks = ((eventById(id)['data'] as Map)['checks'] as List).cast<Map>();
      expect(checks.single, containsPair('kind', 'blocked'));
    });

    test('opens again through its route: the same event closes as a pair (data.reopened, level info), no new event', () async {
      final id = await blockedSite();
      svc.probeSame = (o, d, c) async => true;
      final r = await svc.recheckSite(id);
      expect([r['ok'], r['result']], [true, 'opens']);
      final e = eventById(id);
      expect(e['id'], id);
      expect(e['level'], 'info');
      expect(e['data'], containsPair('reopened', allOf(containsPair('server', 'src1::n1'), containsPair('at', isNotNull), containsPair('entry', isNotNull))));
      expect(events('site', 'blocked'), hasLength(1));
    });

    test('a second Check again while one runs awaits the same run: the probes run once', () async {
      final id = await blockedSite();
      final gate = Completer<bool?>();
      var runs = 0;
      svc.probeSame = (o, d, c) {
        runs++;
        return gate.future;
      };
      svc.probeScout = (o, d, c) async => const AltReach(via: 'route1', viaServer: 'src2::n3');
      final a = svc.recheckSite(id);
      final b = svc.recheckSite(id);
      await pumpEventQueue();
      gate.complete(false);
      final ra = await a;
      final rb = await b;
      expect(ra, rb);
      expect([ra['ok'], ra['result']], [true, 'blocked']);
      expect(runs, 1);
      expect(((eventById(id)['data'] as Map)['checks'] as List), hasLength(1), reason: 'one run, one earlier result');
    });

    test('unknown id, not a site event, VPN off: ok false with a reason, no probe', () async {
      final id = await blockedSite();
      var probes = 0;
      svc.probeSame = (o, d, c) async {
        probes++;
        return true;
      };
      final dns = svc.eventBook.add('dns', 'failed', 'warn', data: {'server': 'g-udp1'});
      for (final bad in [999999, dns]) {
        expect(await svc.recheckSite(bad), allOf(containsPair('ok', false), containsPair('reason', isNotNull)), reason: 'event $bad');
      }
      await svc.disconnect();
      expect(await svc.recheckSite(id), allOf(containsPair('ok', false), containsPair('reason', isNotNull)), reason: 'VPN off');
      expect(probes, 0);
    });
  });
}
