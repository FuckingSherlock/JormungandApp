// «Check now» and «Retry» of an event's row (docs/core.md, jormd HTTP API: POST /api/check-now and
// POST /api/rule-sets/retry; plan .claude_states/t1_app_plan_b.md, B-core). CoreService.checkNow(eventId) checks the
// event's subject out of turn by the path of the scheduled round (no events of its own, `data.recheck`
// pending -> ok / fail through EventBook.update, a second command joins the running check, not connected ->
// notConnected, no event / a type without a check -> FormatException = 400, a check that was not judged (the service
// went away mid-run) leaves no `recheck` behind). CoreService.retryRuleSets(eventId) loads the lists of the event again
// (all tags of its `ruleSets` op, else the single tag) under a new op and answers {updated, failed} for exactly the
// requested tags after the load. A fake sing-box runner (no process) whose probe inbound is a loopback SOCKS5 server
// (it answers, refuses or holds each probe, and records WHICH outbound was asked), time by hand (FakeTime), a loopback
// origin for the lists: no network, no real sing-box.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';
import 'sentinel_fakes.dart';

// A fake sing-box probe inbound: a SOCKS5 server on the `probe-in` port of the started config. Every SOCKS user (the
// outbound tag, or `dns-check/..`) is asked and counted; CONNECTs of a user in [refuse] fail (reply 5), [gate] (when
// set) holds every CONNECT answer until it completes; an HTTP request is answered 200 keep-alive.
class _Socks {
  ServerSocket? _server;
  final asked = <String>[]; // the SOCKS user of each CONNECT, in order
  final refuse = <bool Function(String user)>[];
  Completer<void>? gate;
  final _open = <Socket>[];

  Future<void> bind(int port) async {
    await close();
    final s = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    s.listen(_serve);
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

  bool refused(String user) => refuse.any((f) => f(user));

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

    try {
      await take(3);
      c.add([5, 2]);
      await take(1);
      final ulen = (await take(1))[0];
      final user = utf8.decode(await take(ulen));
      final plen = (await take(1))[0];
      await take(plen);
      c.add([1, 0]);
      await take(4);
      final hlen = (await take(1))[0];
      await take(hlen + 2);
      asked.add(user);
      final g = gate;
      if (g != null) await g.future;
      if (refused(user)) {
        c.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
        await c.flush();
        c.destroy();
        return;
      }
      c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      if (user.startsWith('dns-check/') || user.startsWith('flag-check/')) {
        await c.flush();
        c.destroy();
        return;
      }
      for (;;) {
        while (_headEnd(buf) < 0) {
          if (closed) return;
          await (more ??= Completer<void>()).future;
        }
        buf.removeRange(0, _headEnd(buf) + 4);
        c.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n'));
      }
    } catch (_) {
      c.destroy();
    } finally {
      _open.remove(c);
    }
  }

  static int _headEnd(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
    }
    return -1;
  }
}

class _Api extends SingBoxApi {
  _Api() : super(0, '');
  @override
  final Map<String, String> selected = {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async {
    selected[group] = outbound;
    return true;
  }

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
  final socks = _Socks();
  @override
  Future<void> start(Map<String, dynamic> config) async {
    up = true;
    final outs = (config['outbounds'] as List?)?.cast<Map>() ?? const [];
    for (final o in outs) {
      if (o['type'] == 'selector') _api.selected['${o['tag']}'] = '${o['default'] ?? (o['outbounds'] as List).first}';
    }
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

class _Idle implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => true;
  @override
  int get tick => 0;
}

Map<String, dynamic> _plain() => {
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
                  'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
                },
              ],
            },
          },
        ],
        'mixedPort': 2080,
        'urlTest': {'url': 'http://probe.test/'}, // plain http: the fake probe inbound answers without TLS
        // no flap hold: a target that dropped may go back at once (the hold counts in wall-clock minutes, which the test's
        // fake clock cannot move: CoreService passes no clock to FallbackService / AutoService / DnsFailover / ProbePool)
        'auto': {'flapGuard': false},
        'global': false, // rules mode: in global mode the plan's rules are not applied, so no fallback selector exists
        // what the subjects of the events below are in a real config: a rule whose target `src:x` falls back to Block
        // (FallbackService target `src:x`) and a DNS server (candidate `g-udp1`: DnsFailover server)
        'routing': {
          'fallback': 'main',
          'targets': {
            'src:x': {
              'kind': 'unit',
              'main': {
                'pick': 'priority',
                'chosen': 's::x',
                'nodes': [
                  {
                    'key': 's::x',
                    'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 2, 'method': 'aes-128-gcm', 'password': 'x'},
                  },
                ],
              },
            },
          },
          'dns': {
            'servers': [
              {'id': 'g', 'addr': 'udp://127.0.0.1:5353', 'via': 'direct', 'on': true},
              {'id': 'h', 'addr': 'udp://127.0.0.1:5354', 'via': 'direct', 'on': true}, // a second one: a failover needs a spare
            ],
          },
          'rules': [
            {
              'id': 'r1',
              'name': '',
              'on': true,
              'action': 'proxy',
              'target': 'src:x',
              'fallback': 'block',
              'dns': 'auto',
              'groups': {
                'domain': {
                  'not': false,
                  'v': {'domain_suffix': ['r1.test']},
                },
              },
            },
          ],
        },
      },
    };

/// Waits (real time: the fake probe inbound is a real socket) until [cond]; the fake clock moves a second now and then.
Future<void> until(bool Function() cond, {FakeTime? time, String what = 'condition'}) async {
  for (var i = 0; i < 1000; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (time != null && i % 20 == 19) await time.advanceSeconds(1);
  }
  fail('timed out waiting for $what');
}

/// Awaits [f] the same way.
Future<T> settle<T>(Future<T> f, {FakeTime? time}) async {
  var done = false;
  unawaited(f.then((_) => done = true, onError: (_) => done = true));
  await until(() => done, time: time, what: 'the command to answer');
  return f;
}

void main() {
  group('check now', () {
    late Directory tmp;
    late CoreService svc;
    late FakeTime time;
    late _Runner box;
    var disposed = false;

    Future<void> start({bool connected = true}) async {
      tmp = await Directory.systemTemp.createTemp('jorm-chk');
      time = FakeTime();
      disposed = false;
      box = _Runner()..withApi = true;
      svc = CoreService(
        singBox: 'none',
        resolveAddresses: false,
        directProbe: (_, _) async => 5,
        dataDir: p.join(tmp.path, 'data'),
        runner: box,
        boxFactory: (_) => _Runner(),
        sysProxy: NoSystemProxy(),
        exitCheck: (_) async => {'ip': '127.0.0.1'},
        now: () => time.t,
        timer: time.clock.timer,
        sentinelClock: time.clock,
        windows: FailureWindows.instant(),
        siteChecker: SiteChecker(get: (_, {proxyPort, timeout = Duration.zero}) async => throw const SocketException('no network in tests'), delay: (_) async {}),
      );
      await svc.init();
      if (connected) {
        await svc.connect(_plain());
        await time.advanceSeconds(6);
      }
    }

    tearDown(() async {
      if (!disposed) await svc.dispose();
      await tmp.delete(recursive: true);
    });

    int add(String cat, String type, [Map<String, dynamic> data = const {}]) => svc.eventBook.add(cat, type, 'warn', data: data, verdict: 'confirmed');
    Map<String, dynamic> ev(int id) => svc.eventBook.byId(id)!;
    Map? recheck(int id) => (ev(id)['data'] as Map)['recheck'] as Map?;
    List<Map> all() => (svc.events()['events'] as List).cast<Map>();
    int count() => all().length;
    _Socks socks() => box.socks;

    const supported = {
      'conn/lost': <String, dynamic>{'routes': 1},
      // the data the core writes: evidence of the suspicion (`id` = the route), `rule` / `target` / `to` of the fallback
      'auto/unstable': <String, dynamic>{'id': 'A', 'strikes': 3, 'holdMs': 60000},
      'rules/fallback': <String, dynamic>{'rule': 'r1', 'target': 'src:x', 'to': 'block'},
      'dns/failed': <String, dynamic>{'server': 'g-udp1'},
      'dns/failedOnNode': <String, dynamic>{'server': 'g-udp1'},
    };
    // WHICH check ran: the SOCKS user (outbound) the fake probe inbound was asked through
    const prefix = {
      'conn/lost': 'route0/',
      'auto/unstable': 'route0/',
      'rules/fallback': 'src:x/',
      'dns/failed': 'dns-check/',
      'dns/failedOnNode': 'dns-check/',
    };

    for (final t in supported.entries) {
      test('${t.key}: pending while the probe is held, then ok; the check of its own subject ran; no events of its own', () async {
        await start();
        final parts = t.key.split('/');
        final id = add(parts[0], parts[1], t.value);
        final before = count();
        socks().asked.clear();
        socks().gate = Completer<void>();
        final f = svc.checkNow(id);
        var done = false;
        unawaited(f.whenComplete(() => done = true));
        await until(() => socks().asked.isNotEmpty, time: time, what: 'the probe to be asked');
        // the probe is held: the check is under way, deterministically
        expect(done, isFalse);
        expect(recheck(id), containsPair('state', 'pending'));
        expect(recheck(id)!['at'], isA<int>());
        socks().gate!.complete();
        final r = await settle(f, time: time);
        expect(r, {'ok': true}, reason: 'connected: the command is taken');
        final rc = recheck(id)!;
        expect(rc['state'], 'ok', reason: 'the probe inbound answers: the subject works');
        expect(rc['at'], isA<int>());
        expect(ev(id)['rev'], greaterThan(0), reason: 'changed in place (EventBook.update)');
        expect(ev(id)['data'], containsPair(t.value.keys.first, t.value.values.first), reason: 'the event\'s own data stays');
        final want = prefix[t.key]!;
        expect(socks().asked.any((u) => u.startsWith(want)), isTrue, reason: 'asked through $want: ${socks().asked}');
        final others = prefix.values.toSet()..remove(want);
        expect(socks().asked.where((u) => others.any((o) => o != 'route0/' && u.startsWith(o) || want != 'route0/' && o == 'route0/' && u.startsWith(o))), isEmpty,
            reason: 'the check of another subject did not run: ${socks().asked}');
        final types = [for (final e in all().skip(before)) '${e['cat']}/${e['type']}'];
        expect(types.where((x) => !const {'conn/restored', 'rules/targetBack', 'dns/switched', 'conn/online'}.contains(x)), isEmpty);
      });
    }

    test('a miss is fail (the probe refused), and the outage opens no pair', () async {
      await start();
      final id = add('rules', 'fallback', {'rule': 'r1', 'target': 'src:x', 'to': 'block'});
      socks().refuse.add((u) => u.startsWith('src:x/'));
      expect(await settle(svc.checkNow(id), time: time), {'ok': true});
      expect(recheck(id), containsPair('state', 'fail'));
    });

    test('conn/lost: a route that answers closes the outage: conn/restored opens the real conn/lost', () async {
      await start();
      // the outage as the core opens it (a refused route alone does not make one: the direct path is judged too)
      final nowMs = time.t.millisecondsSinceEpoch;
      svc.autoMemory.lostAt = nowMs;
      svc.routesLost(AutoNet(kind: 'lost', at: nowMs), 1);
      await pumpEventQueue();
      await until(() => all().any((e) => e['cat'] == 'conn' && e['type'] == 'lost'), time: time, what: 'the real conn/lost');
      final lost = all().firstWhere((e) => e['cat'] == 'conn' && e['type'] == 'lost')['id'] as int;
      expect(await settle(svc.checkNow(lost), time: time), {'ok': true});
      expect(recheck(lost), containsPair('state', 'ok'));
      final closing = all().where((e) => e['cat'] == 'conn' && e['type'] == 'restored').toList();
      expect(closing, hasLength(1));
      expect(closing.single['opens'], lost, reason: 'the pair is closed on the very event the user pressed «Check now» on');
    });

    test('rules/fallback: the target answering again goes back: rules/targetBack opens the rules/fallback', () async {
      await start();
      socks().refuse.add((u) => u.startsWith('src:x/'));
      final seed = add('rules', 'fallback', {'rule': 'r1', 'target': 'src:x', 'to': 'block'});
      for (var i = 0; i < 6 && !all().any((e) => e['cat'] == 'rules' && e['type'] == 'fallback' && e['id'] != seed); i++) {
        await settle(svc.checkNow(seed), time: time); // the same test as a round: the target is judged down
      }
      final real = all().where((e) => e['cat'] == 'rules' && e['type'] == 'fallback' && e['id'] != seed).toList();
      expect(real, isNotEmpty, reason: 'a target that misses goes to the fallback');
      final id = real.first['id'] as int;
      socks().refuse.clear();
      // it goes back after failAfter (2) answers in a row: the first answer alone does not
      expect(await settle(svc.checkNow(id), time: time), {'ok': true});
      expect(all().where((e) => e['cat'] == 'rules' && e['type'] == 'targetBack'), isEmpty, reason: 'one answer is not enough');
      expect(await settle(svc.checkNow(id), time: time), {'ok': true});
      expect(recheck(id), containsPair('state', 'ok'));
      final back = all().where((e) => e['cat'] == 'rules' && e['type'] == 'targetBack').toList();
      expect(back, hasLength(1));
      expect(back.single['opens'], id);
    });

    test('dns/failed: the server answering again closes it with dns/switched', () async {
      await start();
      // only g: when the spare h and the path miss too, the failure is the path's, not the server's
      socks().refuse.add((u) => u == 'dns-check/dns-g-udp1');
      final seed = add('dns', 'failed', {'server': 'g-udp1'});
      for (var i = 0; i < 6 && !all().any((e) => e['cat'] == 'dns' && e['type'] == 'failed' && e['id'] != seed); i++) {
        await settle(svc.checkNow(seed), time: time);
      }
      for (var i = 0; i < 400 && !all().any((e) => e['cat'] == 'dns' && e['type'] == 'failed' && e['id'] != seed); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (i % 20 == 19) await time.advanceSeconds(10);
      }
      final real = all().where((e) => e['cat'] == 'dns' && e['type'] == 'failed' && e['id'] != seed).toList();
      expect(real, isNotEmpty, reason: 'a server that misses is judged failed');
      final id = real.first['id'] as int;
      socks().refuse.clear();
      // the flag comes back after failAfter (2) answers in a row (rules.md §6): the first answer alone closes the root only
      expect(await settle(svc.checkNow(id), time: time), {'ok': true});
      expect(all().where((e) => e['cat'] == 'dns' && e['type'] == 'switched' && (e['data'] as Map)['reason'] == 'back'), isEmpty,
          reason: 'one answer is not enough');
      expect(await settle(svc.checkNow(id), time: time), {'ok': true});
      expect(recheck(id), containsPair('state', 'ok'));
      // the DNS pair is dns/switched failover → back (logs.md «По типам»); dns/failed itself has no closer
      final switched = all().where((e) => e['cat'] == 'dns' && e['type'] == 'switched').toList();
      final failover = switched.firstWhere((e) => (e['data'] as Map)['reason'] == 'failover');
      final back = switched.where((e) => (e['data'] as Map)['reason'] == 'back').toList();
      expect(back, isNotEmpty, reason: 'the server answering again switches the side back');
      expect(back.last['opens'], failover['id']);
    });

    // the route probes only: the fallback / DNS services of the harness ask on their own meanwhile
    int routeAsks() => socks().asked.where((u) => u.startsWith('route0/')).length;
    // The probe pool reuses an answer younger than AutoSettings.reuse: a run to be counted gets a fresh service (an
    // empty pool), so the count does not depend on how far the fake clock was moved.
    Future<int> freshRun(int Function() addEvent, {bool gated = false}) async {
      await svc.dispose();
      disposed = true;
      await tmp.delete(recursive: true);
      await start();
      final id = addEvent();
      socks().asked.clear();
      await settle(svc.checkNow(id), time: time);
      return routeAsks();
    }

    test('two commands on one event: exactly one run (probes counted), pending once, both answers agree', () async {
      await start();
      final single = await freshRun(() => add('conn', 'lost', {'routes': 1}));
      expect(single, greaterThan(0));
      await svc.dispose();
      disposed = true;
      await tmp.delete(recursive: true);
      await start();
      final id = add('conn', 'lost', {'routes': 1});
      final updates = <String>[];
      final sub = svc.eventBook.stream.where((e) => e['id'] == id).listen((e) => updates.add('${((e['data'] as Map)['recheck'] as Map?)?['state']}'));
      addTearDown(sub.cancel);
      socks().asked.clear();
      socks().gate = Completer<void>();
      final a = svc.checkNow(id);
      await until(() => routeAsks() > 0, time: time);
      final b = svc.checkNow(id);
      await pumpEventQueue();
      socks().gate!.complete();
      final ra = await settle(a, time: time), rb = await settle(b, time: time);
      expect(rb, ra);
      expect(routeAsks(), single, reason: 'the second command started no second run');
      expect(updates.where((s) => s == 'pending'), hasLength(1));
      expect(updates.where((s) => s == 'ok' || s == 'fail'), hasLength(1));
      // once over, a new command is a new check
      await settle(svc.checkNow(id), time: time);
      expect(updates.where((s) => s == 'pending'), hasLength(2));
    });

    test('two events with the same subject: one run, both events get pending and the same result, both answers agree', () async {
      await start();
      final single = await freshRun(() => add('conn', 'lost', {'routes': 1}));
      expect(single, greaterThan(0));
      await svc.dispose();
      disposed = true;
      await tmp.delete(recursive: true);
      await start();
      final a1 = add('conn', 'lost', {'routes': 1}), a2 = add('conn', 'lost', {'routes': 1});
      socks().asked.clear();
      socks().gate = Completer<void>();
      final fa = svc.checkNow(a1);
      await until(() => routeAsks() > 0, time: time);
      final fb = svc.checkNow(a2);
      await pumpEventQueue();
      expect(recheck(a2), containsPair('state', 'pending'), reason: 'the second event shows the running check too');
      socks().gate!.complete();
      final ra = await settle(fa, time: time), rb = await settle(fb, time: time);
      expect(rb, ra);
      expect(routeAsks(), single, reason: 'one run for the subject, not one per event');
      expect(recheck(a1)!['state'], recheck(a2)!['state']);
      expect(recheck(a2)!['state'], anyOf('ok', 'fail'));
    });

    test('not judged: the service disposed mid-run leaves no recheck on the event (not pending, not fail)', () async {
      await start();
      final id = add('rules', 'fallback', {'rule': 'r1', 'target': 'src:x', 'to': 'block'});
      socks().gate = Completer<void>();
      final f = svc.checkNow(id);
      await until(() => socks().asked.isNotEmpty, time: time);
      expect(recheck(id), containsPair('state', 'pending'));
      disposed = true;
      await svc.dispose();
      final r = await f.timeout(const Duration(seconds: 10));
      expect(r['ok'], isFalse);
      expect(recheck(id), isNull, reason: 'a check that was not judged removes data.recheck');
    });

    test('not judged: Auto replaced by a reconnect mid-run: notConnected and no recheck on the event', () async {
      await start();
      final id = add('rules', 'fallback', {'rule': 'r1', 'target': 'src:x', 'to': 'block'});
      socks().gate = Completer<void>();
      final f = svc.checkNow(id);
      await until(() => socks().asked.isNotEmpty, time: time);
      expect(recheck(id), containsPair('state', 'pending'));
      final re = svc.connect(_plain());
      await pumpEventQueue();
      socks().gate!.complete();
      await settle(re, time: time);
      expect(await settle(f, time: time), {'ok': false, 'error': 'notConnected'});
      expect(recheck(id), isNull, reason: 'not judged: neither pending nor fail');
    });

    test('gone: the subject left the plan: {ok: false, error: gone} and no recheck', () async {
      await start();
      for (final (cat, type, data) in [
        ('rules', 'fallback', {'rule': 'r9', 'target': 'src:zz', 'to': 'block'}),
        ('auto', 'unstable', {'id': 'ZZ', 'strikes': 3}),
      ]) {
        final id = add(cat, type, data);
        expect(await settle(svc.checkNow(id), time: time), {'ok': false, 'error': 'gone'}, reason: '$cat/$type');
        expect(recheck(id), isNull, reason: '$cat/$type: gone is not a fail');
      }
    });

    test('not connected: {ok: false, error: notConnected}, the event is left as it was', () async {
      await start(connected: false);
      final id = add('conn', 'lost', {'routes': 1});
      final rev = ev(id)['rev'];
      expect(await svc.checkNow(id), {'ok': false, 'error': 'notConnected'});
      expect(ev(id)['rev'], rev);
      expect(recheck(id), isNull);
    });

    test('after a disconnect the command is notConnected again', () async {
      await start();
      final id = add('dns', 'failed', {'server': 'dns-a'});
      await svc.disconnect();
      expect(await svc.checkNow(id), {'ok': false, 'error': 'notConnected'});
    });

    test('no such event, and a type with no check: FormatException (400) with a message', () async {
      await start();
      await expectLater(svc.checkNow(987654), throwsA(isA<FormatException>()));
      for (final t in const ['conn/offline', 'conn/restored', 'auto/switched', 'rules/ruleSetFailed', 'dns/switched', 'core/crashed', 'site/unreachable']) {
        final parts = t.split('/');
        final id = add(parts[0], parts[1]);
        await expectLater(svc.checkNow(id), throwsA(isA<FormatException>()), reason: t);
        expect(recheck(id), isNull, reason: '$t: nothing was started');
      }
    });
  });

  group('retry rule sets', () {
    late Directory tmp;
    late HttpServer origin;
    late CoreService svc;
    late List<String> hits;
    late Set<String> broken;
    Completer<void>? hold; // holds every answer of the origin while set
    final srs = [0x53, 0x52, 0x53, 0x01];

    Map<String, dynamic> body() => {
          'plan': {
            'kind': 'unit',
            'main': {
              'pick': 'fastest',
              'nodes': [
                {'key': 's::0', 'outbound': parseLink(ssSip002)!.outbound},
              ],
            },
            'global': false,
            'mixedPort': 2080,
            'routing': {
              'ruleSets': [
                for (final n in const ['mine', 'other', 'third'])
                  {'name': n, 'url': 'http://127.0.0.1:${origin.port}/$n.srs', 'format': 'srs', 'via': 'direct', 'every': 3600},
              ],
              'rules': [
                {
                  'id': 'r1',
                  'name': '',
                  'action': 'direct',
                  'target': '',
                  'fallback': 'default',
                  'block': 'drop',
                  'dns': 'auto',
                  'groups': {
                    'domain': {
                      'not': false,
                      'v': {
                        'rule_set': ['mine', 'other', 'third'],
                      },
                    },
                  },
                },
              ],
            },
          },
        };

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-retry');
      hits = [];
      broken = {};
      hold = null;
      origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((r) async {
        hits.add(r.uri.path);
        final h = hold;
        if (h != null) await h.future;
        if (broken.contains(r.uri.path)) {
          r.response.statusCode = 404;
        } else {
          r.response.add([...srs, 1]);
        }
        await r.response.close();
      });
      svc = CoreService(
        singBox: 'none',
        resolveAddresses: false,
        dataDir: p.join(tmp.path, 'data'),
        runner: _Runner(),
        boxFactory: (_) => _Runner(),
        sysProxy: NoSystemProxy(),
        exitCheck: (_) async => {'ip': '127.0.0.1'},
        sentinelClock: FakeTime().clock,
        windows: FailureWindows.instant(),
        timer: (d, f) => _Idle(),
      );
      await svc.init();
      // stale copies of all lists: used at connect, not fetched
      for (final n in const ['mine', 'other', 'third']) {
        final f = File(p.join(tmp.path, 'data', 'rulesets', 'set-$n.srs'))..createSync(recursive: true);
        f.writeAsBytesSync([...srs, 0]);
        f.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
      }
      final fetch = ServiceFetch(endpoint: () => null, context: svc.sentinel.context);
      svc.ruleSets.fetchSource = () => fetch;
      await svc.connect(body());
      await pumpEventQueue();
      hits.clear();
    });

    tearDown(() async {
      if (hold != null && !hold!.isCompleted) hold!.complete();
      await svc.dispose();
      await origin.close(force: true);
      await tmp.delete(recursive: true);
    });

    int failedEvent(String tag, {Map<String, Object?>? op}) =>
        svc.eventBook.add('rules', 'ruleSetFailed', 'warn', data: {'tag': tag, 'url': 'http://x.example/$tag', 'error': 'e', 'hasCopy': true}, op: op, link: false);
    List<Map> events(String type) => [
          for (final e in (svc.events()['events'] as List).cast<Map>())
            if (e['cat'] == 'rules' && e['type'] == type) e,
        ];

    test('an event with an op ruleSets: every tag of that op is loaded (not the lists of other ops), the answer is {updated, failed}', () async {
      final op = {'id': 'ruleSets-1', 'kind': 'ruleSets'};
      final a = failedEvent('set-mine', op: op);
      failedEvent('set-other', op: op);
      failedEvent('set-third', op: {'id': 'ruleSets-2', 'kind': 'ruleSets'});
      final r = await svc.retryRuleSets(a);
      expect((r['updated'] as List).toSet(), {'set-mine', 'set-other'});
      expect(r['failed'], isEmpty);
      expect(hits.toSet(), {'/mine.srs', '/other.srs'}, reason: 'the list of the other op is not touched');
    });

    test('an event without an op: the single tag of the event', () async {
      // a fresh copy (younger than `every`): only a forced load fetches it again
      File(p.join(tmp.path, 'data', 'rulesets', 'set-third.srs')).setLastModifiedSync(DateTime.now());
      final a = failedEvent('set-third');
      failedEvent('set-mine'); // another event, no op: not this one's
      final r = await svc.retryRuleSets(a);
      expect(r['updated'], ['set-third']);
      expect(r['failed'], isEmpty);
      expect(hits, ['/third.srs']);
    });

    test('a list that still fails is in failed, the others in updated; the answer comes after the load', () async {
      broken.add('/other.srs');
      final op = {'id': 'ruleSets-1', 'kind': 'ruleSets'};
      final a = failedEvent('set-mine', op: op);
      failedEvent('set-other', op: op);
      final r = await svc.retryRuleSets(a);
      expect(r['updated'], ['set-mine']);
      expect(r['failed'], ['set-other']);
      expect(hits.toSet(), {'/mine.srs', '/other.srs'}, reason: 'both were tried before the answer');
    });

    test('a tag that is not in the plan is failed (never fetched), the tags of the plan are loaded', () async {
      final op = {'id': 'ruleSets-1', 'kind': 'ruleSets'};
      final a = failedEvent('set-gone', op: op);
      failedEvent('set-mine', op: op);
      final r = await svc.retryRuleSets(a);
      expect(r['updated'], ['set-mine']);
      expect(r['failed'], ['set-gone']);
      expect(hits, ['/mine.srs']);
      final alone = failedEvent('set-gone');
      hits.clear();
      expect(await svc.retryRuleSets(alone), {'updated': <String>[], 'failed': ['set-gone']});
      expect(hits, isEmpty);
    });

    test('not connected: every tag is failed, nothing is fetched', () async {
      final op = {'id': 'ruleSets-1', 'kind': 'ruleSets'};
      final a = failedEvent('set-mine', op: op);
      failedEvent('set-other', op: op);
      failedEvent('set-third', op: {'id': 'ruleSets-2', 'kind': 'ruleSets'});
      await svc.disconnect();
      hits.clear();
      final r = await svc.retryRuleSets(a);
      expect(r['updated'], isEmpty);
      expect(r['failed'], ['set-mine', 'set-other']);
      expect(hits, isEmpty);
    });

    test('joining a running ruleSets op: each command answers for exactly the tags it asked for', () async {
      final op = {'id': 'ruleSets-1', 'kind': 'ruleSets'};
      final a = failedEvent('set-mine', op: op);
      failedEvent('set-other', op: op);
      final b = failedEvent('set-third');
      hold = Completer<void>();
      final fa = svc.retryRuleSets(a);
      await until(() => hits.isNotEmpty, what: 'the first load to start');
      final fb = svc.retryRuleSets(b); // while the first op runs
      await pumpEventQueue();
      hold!.complete();
      final ra = await fa.timeout(const Duration(seconds: 20)), rb = await fb.timeout(const Duration(seconds: 20));
      expect((ra['updated'] as List).toSet(), {'set-mine', 'set-other'}, reason: 'not widened by the other command');
      expect(ra['failed'], isEmpty);
      expect(rb['updated'], ['set-third'], reason: 'not widened by the running op');
      expect(rb['failed'], isEmpty);
    });

    test('the retry is a new op ruleSets: its events do not carry the op of the failed round', () async {
      final op = {'id': 'ruleSets-1', 'kind': 'ruleSets'};
      final a = failedEvent('set-mine', op: op);
      await svc.retryRuleSets(a);
      final updated = events('ruleSetUpdated');
      expect(updated, isNotEmpty);
      for (final e in updated) {
        final o = e['op'] as Map;
        expect(o['kind'], 'ruleSets');
        expect(o['id'], isNot('ruleSets-1'));
      }
    });

    test('no such event, or an event that is not rules/ruleSetFailed: FormatException (400)', () async {
      await expectLater(svc.retryRuleSets(987654), throwsA(isA<FormatException>()));
      final other = svc.eventBook.add('rules', 'ruleSetUpdated', 'info', data: {'tag': 'set-mine'}, link: false);
      final conn = svc.eventBook.add('conn', 'lost', 'warn', link: false);
      await expectLater(svc.retryRuleSets(other), throwsA(isA<FormatException>()));
      await expectLater(svc.retryRuleSets(conn), throwsA(isA<FormatException>()));
      expect(hits, isEmpty);
    });
  });
}
