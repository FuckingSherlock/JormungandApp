// Quick start on the last servers (docs/core.md «Быстрый старт на последнем сервере», docs/logs.md conn/connected
// `quick`) with the real sing-box on loopback only: shadowsocks "servers" (sing-box processes, or a dead port, or a
// port that accepts and never answers, or a delaying relay) in front of a local HTTP target, the core's own connect,
// the record of the last disconnect in the data dir (a second CoreService on the same dir = a dead process).
// Skipped when the binary is missing.
//
// Server states by name: `alive` (answers), `dead` (nothing listens: refused at once), `hole` (accepts and says
// nothing: a check of it ends by its 5 s timeout), `slow` (answers, every chunk delayed).
import 'dart:async';
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
      'dns': {
        'servers': [
          {'type': 'hosts', 'tag': 'hosts', 'predefined': {'target.test': '127.0.0.1'}},
        ],
      },
      'route': {'default_domain_resolver': 'hosts'},
    };

class _FakeSysProxy extends SystemProxy {
  _FakeSysProxy() : super(File('never-written'));
  @override
  bool get isSet => false;
  @override
  Future<String?> enable(int port) async => null;
  @override
  Future<void> restore() async {}
}

/// The client sing-box: keeps the configs it was started with; [block] makes every further start fail (a crash that
/// cannot be healed).
class _Spy extends SingBoxProcess {
  _Spy(super.binary, super.workDir);
  final configs = <Map<String, dynamic>>[];
  bool block = false;

  @override
  Future<void> start(Map<String, dynamic> config) {
    if (block) throw SingBoxError('blocked by the test');
    configs.add(config);
    return super.start(config);
  }

  String? defaultOf(String tag) {
    for (final o in (configs.last['outbounds'] as List).cast<Map>()) {
      if (o['tag'] == tag) return o['default'] as String?;
    }
    return null;
  }
}

/// One server name on a fixed port in one of the states.
class _Srv {
  _Srv(this.dir, this.port, this.inner);
  final String dir;
  final int port, inner;
  String mode = 'dead';
  SingBoxProcess? _box;
  ServerSocket? _front;
  final _held = <Socket>[];

  Future<void> set(String m) async {
    await _off();
    mode = m;
    switch (m) {
      case 'alive':
        await _on(port);
      case 'slow':
        await _on(inner);
        _front = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        _front!.listen(_relay);
      case 'hole':
        _front = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        _front!.listen(_held.add);
    }
  }

  Future<void> _on(int at) async {
    final b = _box = SingBoxProcess(_bin, p.join(dir, 'srv$at'));
    await b.start(_ssServer(at));
  }

  Future<void> _relay(Socket c) async {
    final Socket up;
    try {
      up = await Socket.connect(InternetAddress.loopbackIPv4, inner);
    } catch (_) {
      c.destroy();
      return;
    }
    const lag = Duration(milliseconds: 120);
    void pipe(Socket from, Socket to) => from.listen((d) => Future<void>.delayed(lag, () {
          try {
            to.add(d);
          } catch (_) {}
        }), onDone: () => Future<void>.delayed(lag * 2, () => to.destroy()), onError: (_) => to.destroy());
    pipe(c, up);
    pipe(up, c);
  }

  Future<void> _off() async {
    for (final s in _held) {
      s.destroy();
    }
    _held.clear();
    await _front?.close();
    _front = null;
    await _box?.stop();
    _box = null;
  }

  Future<void> close() => _off();
}

Future<_Srv> _srv(String dir) async => _Srv(dir, await freePort(), await freePort());

void main() {
  late Directory tmp;
  late HttpServer target;
  late Map<String, _Srv> srv;
  late int mixed;
  _Spy? spy;
  final all = <CoreService>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-quick');
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((r) => r.response
      ..write('hello')
      ..close());
    srv = {for (final n in ['a', 'b', 'c', 'e1', 'e2']) n: await _srv(p.join(tmp.path, 'servers'))};
    mixed = await freePort();
  });

  tearDown(() async {
    for (final s in all) {
      await s.dispose();
    }
    all.clear();
    for (final s in srv.values) {
      await s.close();
    }
    await target.close(force: true);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// A core over the shared data dir ([offset]: its clock runs that far ahead).
  Future<CoreService> boot({Duration offset = Duration.zero}) async {
    final sp = spy = _Spy(_bin, p.join(tmp.path, 'client${all.length}'));
    final s = CoreService(
      singBox: _bin,
      dataDir: p.join(tmp.path, 'data'),
      runner: sp,
      sysProxy: _FakeSysProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      now: () => DateTime.now().add(offset),
    );
    all.add(s);
    await s.init();
    return s;
  }

  Map<String, dynamic> node(String key, _Srv s) => {
        'key': key,
        'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': s.port, 'method': 'aes-128-gcm', 'password': 'loopback'},
      };

  Map<String, dynamic> grp(List<String> names, {String pick = 'priority', String? chosen, bool pinned = false, String prefix = 'k'}) => {
        'pick': pick,
        'chosen': chosen ?? '$prefix::${names.first}',
        'pinned': pinned,
        'nodes': [for (final n in names) node('$prefix::$n', srv[n]!)],
      };

  /// [fast]: Auto checks and moves at once (failAfter 1); else it stays out of the way of a quick start check.
  Map<String, dynamic> body({List<String> names = const ['a', 'b', 'c'], String pick = 'priority', bool pinned = false, String? chosen, bool chain = false, bool fast = false}) => {
        'plan': {
          'routes': [
            {
              'id': 'A',
              'kind': chain ? 'chain' : 'unit',
              if (chain) 'entry': grp(['e1', 'e2'], prefix: 'e'),
              'main': grp(names, pick: pick, pinned: pinned, chosen: chosen),
            },
          ],
          'mixedPort': mixed,
          'urlTest': {'url': 'http://127.0.0.1:${target.port}/'},
          'auto': {'checkers': <String>[], 'flapGuard': false, if (fast) ...{'failAfter': 1, 'retryPause': 0.1} else 'checkEvery': 3600},
        },
        'systemProxy': false,
      };

  Future<void> net(CoreService s, String? id) async {
    s.setNetwork({'connected': true, 'validated': true, 'type': 'wifi', 'id': ?id, 'at': DateTime.now().millisecondsSinceEpoch});
  }

  Future<void> until(bool Function() ok, {int seconds = 20}) async {
    for (var i = 0; i < seconds * 20 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Auto has a verdict on the route's own server (not a member's: the record is made of the route's health): [word]
  /// `oks` (answered) or `fails`.
  Future<void> autoSaid(CoreService s, String word) async {
    var seen = false;
    for (var i = 0; i < 400 && !seen; i++) {
      final routes = ((await s.status())['auto'] as Map?)?['routes'] as List? ?? const [];
      seen = routes.any((r) => r is Map && r[word] is num && (r[word] as num) > 0);
      if (!seen) await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(seen, isTrue, reason: 'Auto never reported $word');
  }

  /// The last conn/connected | conn/reconnected event (a copy).
  Map<String, dynamic>? connEvent(CoreService s) {
    Map<String, dynamic>? last;
    for (final e in (s.eventBook.since(0)['events'] as List).cast<Map>()) {
      if (e['cat'] == 'conn' && (e['type'] == 'connected' || e['type'] == 'reconnected')) last = e.cast<String, dynamic>();
    }
    return last;
  }

  Map<String, dynamic>? quickOf(CoreService s) => ((connEvent(s)?['data'] as Map?)?['quick'] as Map?)?.cast<String, dynamic>();

  Future<Map<String, dynamic>> waitQuick(CoreService s, {int seconds = 20}) async {
    await until(() => quickOf(s) != null, seconds: seconds);
    final q = quickOf(s);
    expect(q, isNotNull, reason: 'no quick in ${connEvent(s)}');
    return q!;
  }

  List<String> raw(CoreService s) => [for (final l in s.log(since: null)['lines'] as List) '${(l as Map)['msg']}'];
  Map<String, dynamic> groupOf(Map<String, dynamic> q, String tag) => ((q['groups'] as List).cast<Map>().firstWhere((g) => g['group'] == tag)).cast<String, dynamic>();
  String? selected(String tag) => spy!.api?.selected[tag];

  /// The first run: [states] set, a connect (the old path), Auto has answered for the chosen server, a disconnect.
  /// [dispose] ends that core (a dead process: only the file is left).
  Future<CoreService> prime(Map<String, String> states, Map<String, dynamic> plan, {String? network = 'net1', bool dispose = true, String word = 'oks'}) async {
    for (final e in states.entries) {
      await srv[e.key]!.set(e.value);
    }
    final s = await boot();
    await net(s, network);
    final res = await s.connect(plan);
    expect(res['connected'], isTrue, reason: '$res');
    await autoSaid(s, word);
    await s.disconnect();
    if (dispose) {
      await s.dispose();
      all.remove(s);
    }
    return s;
  }

  Future<void> states(Map<String, String> m) async {
    for (final e in m.entries) {
      await srv[e.key]!.set(e.value);
    }
  }

  group('used', () {
    test('same network: starts on the recorded server at once, the check ends with «same» in the connected event, in place', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      final s = await boot(); // a new process: the record is the file's
      await net(s, 'net1');
      final res = await s.connect(body());
      expect(res['connected'], isTrue, reason: '$res');
      expect(spy!.defaultOf('route0'), 'route0/k::b', reason: 'started on the record, not on the app\'s hint a');
      final ev = connEvent(s)!;
      expect(ev['type'], 'connected');
      final events = (s.eventBook.since(0)['events'] as List).length;
      final q = await waitQuick(s);
      final g = groupOf(q, 'route0');
      expect([g['started'], g['result']], ['k::b', 'same']);
      expect(q['tookMs'], isA<num>());
      final after = connEvent(s)!;
      expect(after['id'], ev['id'], reason: 'the same event, updated in place');
      // (the book hands out its own maps, so `ev` is the same live map as `after`: the proof of an in-place update is
      // the id, one update, and no new event; the check may end before connect returns, so no earlier rev to compare)
      expect(after['rev'], 1, reason: 'updated once, in place');
      expect((s.eventBook.since(0)['events'] as List), hasLength(events), reason: 'no new event');
      expect(raw(s), contains('connect: route0 quick start on k::b; check: same'));
      expect(spy!.configs, hasLength(1), reason: 'no restart');
      await until(() => selected('route0') != null, seconds: 5); // (the API's group stream may not have said yet)
      expect(selected('route0'), 'route0/k::b');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('no time limit: a month after the disconnect the record still holds', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      final s = await boot(offset: const Duration(days: 30));
      await net(s, 'net1');
      await s.connect(body());
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      expect(groupOf(await waitQuick(s), 'route0')['started'], 'k::b');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('the user\'s reconnect (disconnect, connect within seconds, same core): conn/reconnected gets quick', () async {
      final s = await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body(), dispose: false);
      final res = await s.connect(body());
      expect(res['connected'], isTrue, reason: '$res');
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      expect(connEvent(s)!['type'], 'reconnected');
      expect(groupOf(await waitQuick(s), 'route0')['result'], 'same');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('a chain: the entry group starts from the record too', () async {
      await prime({'e1': 'dead', 'e2': 'alive', 'a': 'dead', 'b': 'alive', 'c': 'alive'}, body(chain: true));
      final s = await boot();
      await net(s, 'net1');
      await s.connect(body(chain: true));
      expect(spy!.defaultOf('route0-entry'), 'route0-entry/e::e2');
      final q = await waitQuick(s);
      expect([groupOf(q, 'route0-entry')['started'], groupOf(q, 'route0-entry')['result']], ['e::e2', 'same']);
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('the start does not wait for the check: a slow server above ours (5 s timeout) costs the connect nothing', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      await states({'a': 'hole'});
      final s = await boot();
      await net(s, 'net1');
      final sw = Stopwatch()..start();
      final res = await s.connect(body());
      final took = sw.elapsedMilliseconds;
      expect(res['connected'], isTrue, reason: '$res');
      expect(took, lessThan(3500), reason: 'the old path waits for a (about 5 s)');
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      expect(quickOf(s), isNull, reason: 'the check is still running when the connect returned');
      final q = await waitQuick(s);
      expect(groupOf(q, 'route0')['result'], 'same');
      expect(q['tookMs'] as num, greaterThan(3000), reason: 'the check waited for the silent server');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('not used: the old path, no quick', () {
    // each: [what changes before the second connect]; `pick` in the event = the check ran before the start
    Future<void> second({String? network = 'net1', Map<String, dynamic>? plan, bool pre = true, String expectDefault = 'route0/k::a'}) async {
      final s = await boot();
      if (network != null) await net(s, network);
      final res = await s.connect(plan ?? body());
      expect(res['connected'], isTrue, reason: '$res');
      expect(spy!.defaultOf('route0'), expectDefault);
      await Future<void>.delayed(const Duration(seconds: 3)); // a check would have ended
      final data = connEvent(s)!['data'] as Map;
      expect(data['quick'], isNull, reason: '$data');
      if (pre) expect(data['pick'], isNotNull, reason: 'the pre-start check ran: $data');
      expect(raw(s).where((l) => l.contains('quick start')), isEmpty);
    }

    test('another network id', () async {
      await prime({'a': 'alive', 'b': 'alive', 'c': 'alive'}, body(), network: 'net1');
      await second(network: 'net2');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('no network report on the connect', () async {
      await prime({'a': 'alive', 'b': 'alive', 'c': 'alive'}, body(), network: 'net1');
      await second(network: null);
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('no network id at the disconnect (no report then) — not used even with a report now', () async {
      await prime({'a': 'alive', 'b': 'alive', 'c': 'alive'}, body(), network: null);
      await second(network: 'net1');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('the recorded server is not a member of the group any more', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      await states({'a': 'alive'});
      await second(plan: body(names: ['a', 'c']), expectDefault: 'route0/k::a');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('the group is pinned in Manual: its pin stands, no quick', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      await second(plan: body(pinned: true, chosen: 'k::c'), pre: false, expectDefault: 'route0/k::c');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('the server was not alive at the disconnect (Auto\'s last check missed): not in the record', () async {
      await prime({'a': 'dead', 'b': 'dead', 'c': 'dead'}, body(fast: true), word: 'fails');
      await states({'a': 'alive', 'b': 'alive', 'c': 'alive'});
      await second();
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('a sing-box crash writes no record: the earlier one stays', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body()); // record: b
      await states({'a': 'dead', 'b': 'dead', 'c': 'alive'});
      var s = await boot();
      await net(s, 'net1');
      await s.connect(body());
      await waitQuick(s); // started on b, switched to c
      await until(() => selected('route0') == 'route0/k::c', seconds: 5);
      expect(selected('route0'), 'route0/k::c');
      await autoSaid(s, 'oks');
      spy!.block = true; // no heal
      final pid = spy!.pid!;
      Process.killPid(pid);
      await until(() => spy!.running == false, seconds: 10);
      await s.dispose(); // not connected any more: nothing to record
      all.remove(s);
      await states({'a': 'dead', 'b': 'alive', 'c': 'alive'});
      s = await boot();
      await net(s, 'net1');
      await s.connect(body());
      final q = await waitQuick(s);
      expect(groupOf(q, 'route0')['started'], 'k::b', reason: 'the record is still the one of the disconnect, not c from the crashed run');
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('the check\'s result per group', () {
    for (final pick in ['priority', 'fastest']) {
      test('$pick: ours did not answer — switched to the one that did (noAnswer), by SelectOutbound, no restart, no auto event', () async {
        await prime({'a': 'dead', 'b': 'alive', 'c': 'dead'}, body(pick: pick));
        await states({'a': 'dead', 'b': 'dead', 'c': 'alive'});
        final s = await boot();
        await net(s, 'net1');
        final before = (s.eventBook.since(0)['events'] as List).length;
        await s.connect(body(pick: pick));
        expect(spy!.defaultOf('route0'), 'route0/k::b');
        final q = await waitQuick(s);
        final g = groupOf(q, 'route0');
        expect([g['started'], g['result'], g['to'], g['why']], ['k::b', 'switched', 'k::c', 'noAnswer']);
        await until(() => selected('route0') == 'route0/k::c', seconds: 5);
        expect(selected('route0'), 'route0/k::c');
        expect(spy!.configs, hasLength(1), reason: 'sing-box is not restarted');
        final added = (s.eventBook.since(0)['events'] as List).skip(before).cast<Map>().map((e) => '${e['cat']}/${e['type']}');
        expect(added.where((e) => e.startsWith('auto/')), isEmpty, reason: '$added');
        expect(raw(s), contains('connect: route0 quick start on k::b; check: switched to k::c: noAnswer'));
      }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
    }

    test('priority: a higher server is back — switched to it (higherBack)', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      await states({'a': 'alive'});
      final s = await boot();
      await net(s, 'net1');
      await s.connect(body());
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      final g = groupOf(await waitQuick(s), 'route0');
      expect([g['result'], g['to'], g['why']], ['switched', 'k::a', 'higherBack']);
      await until(() => selected('route0') == 'route0/k::a', seconds: 5);
      expect(selected('route0'), 'route0/k::a');
      expect(spy!.configs, hasLength(1));
      expect(raw(s), contains('connect: route0 quick start on k::b; check: switched to k::a: higherBack'));
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('fastest: a faster one exists but ours answered — it stays (no switch)', () async {
      await prime({'a': 'dead', 'b': 'slow', 'c': 'dead'}, body(pick: 'fastest'));
      await states({'a': 'alive'});
      final s = await boot();
      await net(s, 'net1');
      await s.connect(body(pick: 'fastest'));
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      final g = groupOf(await waitQuick(s), 'route0');
      expect(g['result'], 'same', reason: 'the check chose a, but b answered: it stays (spec gap: the result word)');
      expect(g['to'], isNull);
      await until(() => selected('route0') != null, seconds: 5);
      await Future<void>.delayed(const Duration(milliseconds: 500)); // a wrong switch would have gone by now
      expect(selected('route0'), 'route0/k::b');
      expect(raw(s).where((l) => l.contains('check: switched')), isEmpty);
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));

    test('the core moved the group first (before the check ended): the result is dropped, nothing selected by the check', () async {
      // The move is made by the test (SelectOutbound, as Auto's failover does it): Auto cannot beat this check in a
      // real run. Its first round also asks the silent a (an unavailable node from the last run is asked once at the
      // first round) and ends with a's 5 s timeout, the same moment the check ends.
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      await states({'a': 'hole', 'b': 'dead'}); // the check waits for a (5 s) and would switch to c
      final s = await boot();
      await net(s, 'net1');
      await s.connect(body());
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      await until(() => selected('route0') == 'route0/k::b', seconds: 5);
      expect(await spy!.api!.select('route0', 'route0/k::a'), isTrue);
      await until(() => selected('route0') == 'route0/k::a', seconds: 3);
      expect(quickOf(s), isNull, reason: 'the check is still running');
      final g = groupOf(await waitQuick(s), 'route0');
      expect(g['result'], 'dropped');
      // (the group's later moves are Auto's own: it fails over from the silent a at the end of its first round)
      expect(raw(s).where((l) => l.contains('check: switched')), isEmpty, reason: 'the late result did not select');
      expect(raw(s), contains('connect: route0 quick start on k::b; check: dropped: moved by Auto'));
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
  });

  group('cancel', () {
    test('a disconnect during the check: no switch, the event is not updated', () async {
      await prime({'a': 'dead', 'b': 'alive', 'c': 'alive'}, body());
      await states({'a': 'hole', 'b': 'dead'}); // a result would switch to c
      final s = await boot();
      await net(s, 'net1');
      await s.connect(body());
      expect(spy!.defaultOf('route0'), 'route0/k::b');
      final api = spy!.api!;
      await s.disconnect();
      await Future<void>.delayed(const Duration(seconds: 7)); // the check would have ended by now
      expect(connEvent(s)!['data'], isNot(contains('quick')));
      expect(raw(s).where((l) => l.contains('check: switched') || l.contains('check: same') || l.contains('check: dropped')), isEmpty);
      expect(api.selected['route0'], isNot('route0/k::c'));
    }, skip: _skip, timeout: const Timeout(Duration(seconds: 90)));
  });
}
