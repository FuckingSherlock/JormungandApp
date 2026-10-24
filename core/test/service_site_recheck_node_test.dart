// CoreService.recheckSiteNode(eventId, node): a tap on one row of the site card rechecks the site through THAT node only
// (docs/connect-model.md «Перепроверка ряда»). Rows never vanish (`data.nodes` keeps every checked node), the legacy
// fields (tried / via / viaServer / viaTarget / type) are derived from `nodes`, the own node of the event reopens it as
// a pair, parallel rechecks of different nodes both keep their results, the same node twice is one probe.
// Plus siteCheck: the previous outcome stays under `check.prev` while the new check is pending.
// Harness of service_site_recheck_test.dart: a fake runner (no process), probeSame as the seam, time by hand.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sentinel_fakes.dart';

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

/// A fake probe inbound (sing-box's `probe-in`): a loopback SOCKS5 server that accepts every CONNECT and answers every
/// HTTP request 200, so that Auto's tests of all servers answer and `workingNodes()` lists them.
class _Socks {
  ServerSocket? _server;
  final _open = <Socket>[];

  Future<void> bind(int port) async {
    await close();
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_serve);
  }

  Future<void> close() async {
    final s = _server;
    _server = null;
    for (final c in _open.toList()) {
      c.destroy();
    }
    _open.clear();
    await s?.close();
  }

  Future<void> _serve(Socket c) async {
    _open.add(c);
    final buf = <int>[];
    Completer<void>? more;
    var closed = false;
    void wake() {
      more?.complete();
      more = null;
    }

    c.listen((d) {
      buf.addAll(d);
      wake();
    }, onDone: () {
      closed = true;
      wake();
    }, onError: (Object _) {
      closed = true;
      wake();
    });
    Future<List<int>> take(int n) async {
      while (buf.length < n) {
        if (closed) throw const SocketException('closed');
        await (more ??= Completer<void>()).future;
      }
      final out = buf.sublist(0, n);
      buf.removeRange(0, n);
      return out;
    }

    int headEnd() {
      for (var i = 0; i + 3 < buf.length; i++) {
        if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) return i;
      }
      return -1;
    }

    try {
      await take(3);
      c.add([5, 2]);
      await take(1);
      await take((await take(1))[0]);
      await take((await take(1))[0]);
      c.add([1, 0]);
      await take(4);
      await take((await take(1))[0] + 2);
      c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      for (;;) {
        while (headEnd() < 0) {
          if (closed) return;
          await (more ??= Completer<void>()).future;
        }
        buf.removeRange(0, headEnd() + 4);
        c.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'));
      }
    } catch (_) {
      c.destroy();
    } finally {
      _open.remove(c);
    }
  }
}

class _Runner implements BoxRunner {
  bool up = false;
  final socks = _Socks();
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
  SingBoxApi? get api => up ? _api : null; // an API so that Auto runs and knows the working nodes
  @override
  void note(String line) => onLog?.call('[jormd] $line');
  @override
  Future<void> start(Map<String, dynamic> config) async {
    up = true;
    for (final i in (config['inbounds'] as List?)?.cast<Map>() ?? const []) {
      if (i['tag'] == 'probe-in') await socks.bind(i['listen_port'] as int);
    }
  }

  @override
  Future<void> stop() async {
    up = false;
    await socks.close();
  }
}

const _own = 'src1::n1', _n2 = 'src1::n2', _n3 = 'src2::n3';

Map<String, dynamic> _plan() => {
      'routes': [
        {
          'id': 'A',
          'kind': 'unit',
          'main': {
            'pick': 'priority',
            'chosen': _own,
            'nodes': [
              for (final k in [_own, _n2, _n3])
                {
                  'key': k,
                  'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
            ],
          },
        },
      ],
      'mixedPort': 2080,
      'urlTest': {'url': 'http://probe.test/'}, // plain http: the fake probe inbound answers without TLS
      'auto': {'flapGuard': false},
      'global': true,
    };

void main() {
  late Directory tmp;
  late CoreService svc;
  late _Runner runner;
  late FakeTime time;
  Completer<void>? checkerGate;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-site-recheck-node');
    runner = _Runner();
    time = FakeTime();
    checkerGate = null;
    svc = CoreService(
      singBox: 'none',
      resolveAddresses: false,
      directProbe: (_, _) async => 5,
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      boxFactory: (_) => _Runner(),
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => time.t,
      timer: time.clock.timer,
      sentinelClock: time.clock,
      siteChecker: SiteChecker(
        get: (_, {proxyPort, timeout = Duration.zero}) async {
          final g = checkerGate;
          if (g != null) await g.future;
          throw const SocketException('no network in tests');
        },
        delay: (_) async {},
      ),
    );
    await svc.init();
    await svc.connect({'plan': _plan()});
    await time.advanceSeconds(6);
    // wait (real time: the probe inbound is a real socket) until Auto lists the other nodes as working: a recheck whose
    // probe throws answers `failed` once the outbound of the node is known, `noServer` before
    final scratch = svc.eventBook.add('site', 'blocked', 'warn', data: {'host': 'ready.example', 'port': 443, 'server': _own, 'outbound': 'route0/$_own'});
    svc.probeSame = (o, d, c) async => throw StateError('ready check');
    for (var i = 0; i < 1000; i++) {
      final r = await svc.recheckSiteNode(scratch, _n3);
      if (r['reason'] != 'noServer') break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (i % 20 == 19) await time.advanceSeconds(1);
    }
    svc.clearEvents();
    svc.probeSame = null;
  });

  tearDown(() async {
    await svc.dispose();
    await tmp.delete(recursive: true);
  });

  /// A site/blocked of the node [_own] that also did not open through [_n2] and opened through [_n3].
  int site({String type = 'blocked', List<Map>? tried, String? via = 'route1', String? viaServer = _n3, Map<String, dynamic> extra = const {}}) =>
      svc.eventBook.add('site', type, 'warn', data: {
        'host': 'example.org',
        'port': 443,
        'dest': 'example.org:443',
        'server': _own,
        'outbound': 'route0/$_own',
        'entry': 'route0',
        'tried': tried ?? [<String, dynamic>{'entry': 'route0', 'server': _n2}],
        if (via != null) 'via': via,
        if (viaServer != null) 'viaServer': viaServer,
        ...extra,
      });

  Map ev(int id) => svc.eventBook.byId(id)!;
  Map data(int id) => ev(id)['data'] as Map;
  List<Map> nodes(int id) => ((data(id)['nodes'] as List?) ?? const []).cast<Map>();
  List<Map> checks(int id) => ((data(id)['checks'] as List?) ?? const []).cast<Map>();
  String snap(int id) => jsonEncode(data(id));

  /// The probe answers by the node key found in the outbound tag it is asked through.
  Map<String, bool> answers = {};
  List<String> asked = [];
  void probesBy(Map<String, bool> a) {
    answers = a;
    asked = [];
    svc.probeSame = (o, d, c) async {
      asked.add(o);
      for (final e in answers.entries) {
        if (o.contains(e.key)) return e.value;
      }
      throw StateError('unexpected outbound $o');
    };
  }

  group('a row rechecks through its node only', () {
    for (final arg in [_n2, 'route0/$_n2']) {
      test('a red node opens ($arg): its item green with ms, type blocked, via = that node, tried without it, one «node» check', () async {
        final id = site();
        probesBy({_n2: true});
        final r = await svc.recheckSiteNode(id, arg);
        expect([r['ok'], r['result']], [true, 'opens']);
        expect(r['ms'], isNotNull);
        expect(asked, hasLength(1), reason: 'only the asked node is probed');
        expect(asked.single, contains(_n2));
        final n = nodes(id);
        expect(n.map((x) => x['server']), [_n2, _n3], reason: 'seeded from tried then via; the own node is not in the list');
        expect(n[0], allOf(containsPair('ok', true), containsPair('entry', 'route0'), containsPair('ms', isNotNull), containsPair('at', isNotNull)));
        expect(n[1], allOf(containsPair('ok', true), containsPair('entry', 'route1')));
        final d = data(id);
        expect(ev(id)['type'], 'blocked');
        expect([d['via'], d['viaServer'], d['viaTarget']], ['route0', _n2, 'node:$_n2'], reason: 'via is the first green item; it equals the entry');
        expect((d['tried'] as List?) ?? const [], isEmpty);
        expect(checks(id), hasLength(1));
        expect(checks(id).single, allOf(containsPair('kind', 'node'), containsPair('server', _n2), containsPair('ok', true), containsPair('at', isNotNull)));
        expect(d['checkedAt'], isNotNull);
      });
    }

    test('the only green node fails: type unreachable, via removed, the row stays red in tried', () async {
      final id = site(tried: []);
      probesBy({_n3: false});
      final r = await svc.recheckSiteNode(id, _n3);
      expect([r['ok'], r['result']], [true, 'fails']);
      expect(r.containsKey('ms'), isFalse, reason: 'ms only when it opened');
      final d = data(id);
      expect(ev(id)['type'], 'unreachable');
      expect(d.containsKey('via'), isFalse);
      expect(d.containsKey('viaServer'), isFalse);
      expect(d.containsKey('viaTarget'), isFalse);
      expect((d['tried'] as List).cast<Map>().map((t) => t['server']), [_n3]);
      expect(nodes(id).single, allOf(containsPair('server', _n3), containsPair('ok', false)));
      expect(nodes(id).single.containsKey('ms'), isFalse);
    });

    test('rows never vanish: several rechecks keep the length and the order, the derived fields follow the items', () async {
      final id = site();
      final steps = <(String, bool, String, String?)>[
        // node, opens, type after, via server after
        (_n2, true, 'blocked', _n2),
        (_n3, false, 'blocked', _n2),
        (_n2, false, 'unreachable', null),
        (_n3, true, 'blocked', _n3),
      ];
      for (final (node, ok, type, viaServer) in steps) {
        probesBy({node: ok});
        expect((await svc.recheckSiteNode(id, node))['ok'], true);
        expect(nodes(id).map((x) => x['server']), [_n2, _n3], reason: 'after $node=$ok');
        expect(ev(id)['type'], type, reason: 'after $node=$ok');
        expect(data(id)['viaServer'], viaServer, reason: 'after $node=$ok');
        final red = nodes(id).where((x) => x['ok'] == false).map((x) => x['server']);
        expect(((data(id)['tried'] as List?) ?? const []).cast<Map>().map((t) => t['server']), red);
      }
      expect(checks(id).map((c) => c['server']), [_n2, _n3, _n2, _n3]);
    });

    test('a node that is not in the list yet is appended; the checks keep the cap of 20', () async {
      final old = [for (var i = 0; i < 20; i++) <String, dynamic>{'at': i, 'kind': 'blocked'}];
      final id = site(tried: [], via: null, viaServer: null, type: 'unreachable', extra: {'checks': old});
      probesBy({_n2: false, _n3: true});
      await svc.recheckSiteNode(id, _n2);
      await svc.recheckSiteNode(id, _n3);
      expect(nodes(id).map((x) => x['server']), [_n2, _n3]);
      expect(ev(id)['type'], 'blocked');
      expect(checks(id), hasLength(20));
      expect(checks(id).last, containsPair('server', _n3));
    });
  });

  group('the own node of the event', () {
    test('opens: exactly the reopened pair (level info, reopened set, checks kept plus the new entry)', () async {
      final id = site(extra: {'checks': [<String, dynamic>{'at': 1, 'kind': 'blocked'}]});
      probesBy({_own: true});
      final r = await svc.recheckSiteNode(id, _own);
      expect([r['ok'], r['result']], [true, 'opens']);
      expect(ev(id)['level'], 'info');
      expect(data(id), containsPair('reopened', allOf(containsPair('server', _own), containsPair('entry', 'route0'), containsPair('at', isNotNull))));
      expect(checks(id), hasLength(2));
      expect(checks(id).last, allOf(containsPair('kind', 'node'), containsPair('server', _own), containsPair('ok', true)));
      expect([for (final e in (svc.events()['events'] as List).cast<Map>()) if (e['cat'] == 'site') e], hasLength(1), reason: 'no new event');
    });

    test('fails: only the check entry and checkedAt are added, nothing else changes', () async {
      final id = site();
      final level = ev(id)['level'], type = ev(id)['type'];
      final before = Map<String, dynamic>.from(jsonDecode(snap(id)) as Map)..remove('checks')..remove('checkedAt');
      probesBy({_own: false});
      final r = await svc.recheckSiteNode(id, _own);
      expect([r['ok'], r['result']], [true, 'fails']);
      final after = Map<String, dynamic>.from(jsonDecode(snap(id)) as Map);
      expect(after['checks'], hasLength(1));
      expect(checks(id).single, allOf(containsPair('kind', 'node'), containsPair('server', _own), containsPair('ok', false)));
      expect(after['checkedAt'], isNotNull);
      after..remove('checks')..remove('checkedAt');
      expect(after, before);
      expect([ev(id)['level'], ev(id)['type']], [level, type]);
    });
  });

  group('concurrency', () {
    test('two nodes at once, the probes finish in reverse order: both results are kept', () async {
      final id = site();
      final gates = {_n2: Completer<bool>(), _n3: Completer<bool>()};
      svc.probeSame = (o, d, c) => gates.entries.firstWhere((e) => o.contains(e.key)).value.future;
      final a = svc.recheckSiteNode(id, _n2);
      final b = svc.recheckSiteNode(id, _n3);
      await pumpEventQueue();
      gates[_n3]!.complete(false);
      expect((await b)['result'], 'fails');
      gates[_n2]!.complete(true);
      expect((await a)['result'], 'opens');
      final byServer = {for (final n in nodes(id)) n['server']: n};
      expect(byServer[_n2], containsPair('ok', true));
      expect(byServer[_n3], containsPair('ok', false), reason: 'the later write merged into the latest data, not into a stale snapshot');
      expect(data(id)['viaServer'], _n2);
      expect(checks(id).map((c) => c['server']).toSet(), {_n2, _n3});
    });

    test('the same node twice: one probe, both callers get the same result, one check entry', () async {
      final id = site();
      final gate = Completer<bool>();
      var runs = 0;
      svc.probeSame = (o, d, c) {
        runs++;
        return gate.future;
      };
      final a = svc.recheckSiteNode(id, _n2);
      final b = svc.recheckSiteNode(id, _n2);
      await pumpEventQueue();
      gate.complete(true);
      final ra = await a, rb = await b;
      expect(ra, rb);
      expect(runs, 1);
      expect(checks(id), hasLength(1));
      // after it finished a new call probes again
      probesBy({_n2: false});
      await svc.recheckSiteNode(id, _n2);
      expect(asked, hasLength(1));
    });
  });

  group('refusals write nothing', () {
    Future<void> expectRefused(int id, String node, String reason) async {
      final before = snap(id), rev = ev(id)['rev'];
      final r = await svc.recheckSiteNode(id, node);
      expect(r, allOf(containsPair('ok', false), containsPair('reason', reason)));
      expect(snap(id), before);
      expect(ev(id)['rev'], rev);
    }

    test('noServer: a node with no outbound', () async {
      final id = site();
      probesBy({});
      await expectRefused(id, 'src9::nowhere', 'noServer');
      expect(asked, isEmpty);
    });

    test('notSiteEvent', () async {
      final dns = svc.eventBook.add('dns', 'failed', 'warn', data: {'server': 'g-udp1'});
      probesBy({});
      await expectRefused(dns, _n2, 'notSiteEvent');
    });

    test('gone: an unknown id', () async {
      probesBy({});
      expect(await svc.recheckSiteNode(999999, _n2), allOf(containsPair('ok', false), containsPair('reason', 'gone')));
    });

    test('notConnected: VPN off, no probe', () async {
      final id = site();
      probesBy({_n2: true});
      await svc.disconnect();
      await expectRefused(id, _n2, 'notConnected');
      expect(asked, isEmpty);
    });

    test('the VPN goes off during the probe: notConnected, nothing written', () async {
      final id = site();
      final before = snap(id);
      svc.probeSame = (o, d, c) async {
        runner.up = false;
        return true;
      };
      final r = await svc.recheckSiteNode(id, _n2);
      expect(r, allOf(containsPair('ok', false), containsPair('reason', 'notConnected')));
      expect(snap(id), before);
    });

    test('the event is deleted during the probe: gone, nothing written', () async {
      final id = site();
      final gate = Completer<bool>();
      svc.probeSame = (o, d, c) => gate.future;
      final f = svc.recheckSiteNode(id, _n2);
      await pumpEventQueue();
      svc.clearEvents();
      gate.complete(true);
      expect(await f, allOf(containsPair('ok', false), containsPair('reason', 'gone')));
    });

    test('the probe throws: failed, nothing written, and a later call runs again', () async {
      final id = site();
      final before = snap(id);
      svc.probeSame = (o, d, c) async => throw StateError('boom');
      expect(await svc.recheckSiteNode(id, _n2), allOf(containsPair('ok', false), containsPair('reason', 'failed')));
      expect(snap(id), before);
      probesBy({_n2: true});
      expect((await svc.recheckSiteNode(id, _n2))['ok'], true, reason: 'the failed run is not stuck in the running map');
    });
  });

  group('siteCheck keeps the shown outcome', () {
    test('the previous outcome is under check.prev while pending (without its own prev), and gone after the result', () async {
      final id = site(extra: {
        'check': <String, dynamic>{'state': 'opens', 'at': 5, 'prev': <String, dynamic>{'state': 'down'}},
      });
      checkerGate = Completer<void>();
      final f = svc.siteCheck({'event': id});
      await pumpEventQueue();
      final c = data(id)['check'] as Map;
      expect(c['state'], 'pending');
      expect(c['prev'], allOf(containsPair('state', 'opens'), containsPair('at', 5)));
      expect((c['prev'] as Map).containsKey('prev'), isFalse);
      checkerGate!.complete();
      await f;
      final done = data(id)['check'] as Map;
      expect(done['state'], isNot('pending'));
      expect(done.containsKey('prev'), isFalse);
    });

    test('no previous outcome (or a pending one): no prev', () async {
      final id = site();
      checkerGate = Completer<void>();
      final f = svc.siteCheck({'event': id});
      await pumpEventQueue();
      expect((data(id)['check'] as Map).containsKey('prev'), isFalse);
      checkerGate!.complete();
      await f;
    });
  });
}
