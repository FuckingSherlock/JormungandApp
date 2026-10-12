// TunIngressDetector (docs/core.md → «Неудачные соединения» → «TCP из TUN не доходит»): the silent
// outage of 2026-10-10 — on the Android system / mixed stacks sing-box saw the first packet of every
// TCP connection (`router: found package name`) and never accepted it. The replay feeds the real
// log exports through the detector with their own timestamps; the fixtures are cut from them
// (core/test/fixtures/tun_ingress: lines nothing reads are `other`, addresses are dropped).
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

class _Ev {
  _Ev(this.kind, this.at, this.data);
  final String kind; // dead | back
  final DateTime at;
  final Map<String, dynamic> data;
}

class _Rig {
  _Rig() {
    d = TunIngressDetector(
      now: () => t,
      onDead: (m) => events.add(_Ev('dead', t, m)),
      onBack: (m) => events.add(_Ev('back', t, m)),
    );
  }

  late final TunIngressDetector d;
  DateTime t = DateTime.utc(2026, 10, 10, 12);
  final events = <_Ev>[];
  int _id = 1000;

  /// A line of the export: `2026-10-10T10:51:33.165Z INFO  body`.
  void line(String exported) {
    final m = RegExp(r'^(\S+Z) (.*)$').firstMatch(exported)!;
    t = DateTime.parse(m[1]!);
    d.onLine(m[2]!);
  }

  void advance(Duration by) => t = t.add(by);

  int nextId() => _id++;

  // the look-up that precedes a connection (and is all there is of a connection that never arrives)
  void found(String app, {int? id}) => d.onLine('INFO  [${id ?? nextId()} 0ms] router: found package name: $app');

  void other([int n = 1]) {
    for (var i = 0; i < n; i++) {
      d.onLine('INFO  outbound/direct[direct]: other');
    }
  }

  // a TCP connection of the tunnel: the look-up, then the inbound's two lines
  void tcp(String app) {
    found(app);
    final id = nextId();
    d.onLine('INFO  [$id 0ms] inbound/tun[tun-in]: inbound connection from 172.19.0.1:50000');
    d.onLine('INFO  [$id 0ms] inbound/tun[tun-in]: inbound connection to 1.1.1.1:443');
  }

  void dns() {
    final id = nextId();
    d.onLine('INFO  [$id 0ms] inbound/tun[tun-in]: inbound DNS packet from 172.19.0.1:40000');
    d.onLine('INFO  [$id 1ms] router: found package name: com.example.app');
  }

  /// [n] look-ups that end in one of our reject rules (the debug-level `pre-match … => reject` line of the same id).
  void rejected(int n, {String app = 'org.telegram.messenger.web', int gap = 8}) {
    for (var i = 0; i < n; i++) {
      final id = nextId();
      found(app, id: id);
      d.onLine('DEBUG [$id 0ms] router: pre-match[0] inbound=tun-in ip_version=6 => reject(no_drop)');
      other(gap);
    }
  }

  /// [n] look-ups that no connection follows, [gap] other lines after each so none can be paired late.
  void orphans(int n, {String app = 'org.telegram.messenger.web', int gap = 8}) {
    for (var i = 0; i < n; i++) {
      found(app);
      other(gap);
    }
  }
}

/// The fixture through a detector started at its first line.
({_Rig rig, DateTime start}) _replay(String name, String stack) {
  final rig = _Rig();
  final lines = File('test/fixtures/tun_ingress/$name.log').readAsLinesSync().where((l) => !l.startsWith('#')).toList();
  final first = RegExp(r'^(\S+Z) ').firstMatch(lines.first)![1]!;
  rig.t = DateTime.parse(first);
  final start = rig.t;
  rig.d.start(stack);
  for (final l in lines) {
    rig.line(l);
  }
  return (rig: rig, start: start);
}

void main() {
  group('replay of the recorded sessions', () {
    for (final (file, stack) in [('mixed_dead', 'mixed'), ('system_dead', 'system')]) {
      test('$stack: dead within seconds of the start, once, with the apps that were looked at', () {
        final r = _replay(file, stack);
        expect(r.rig.events.map((e) => e.kind), ['dead']);
        final e = r.rig.events.single;
        expect(e.at.difference(r.start), lessThan(const Duration(seconds: 10)));
        expect(e.data['stack'], stack);
        expect(e.data['synSeen'], greaterThanOrEqualTo(TunIngressDetector.minUnpaired));
        expect(e.data['accepted'], 0);
        expect(e.data['windowMs'], TunIngressDetector.window.inMilliseconds);
        expect(e.data['apps'], contains('org.telegram.messenger.web'));
        expect((e.data['apps'] as List).length, lessThanOrEqualTo(TunIngressDetector.maxApps));
        final j = r.rig.d.toJson();
        expect([j['state'], j['tcp'], j['deadEvents']], ['dead', 0, 1]);
        expect(j['deadForMs'], isA<int>());
      });
    }

    for (final file in ['gvisor_ok_a', 'gvisor_ok_b']) {
      test('gvisor, working ($file): nothing is said', () {
        final r = _replay(file, 'gvisor');
        expect(r.rig.events, isEmpty);
        final j = r.rig.d.toJson();
        expect(j['state'], 'ok');
        expect(j['tcp'], greaterThan(10));
        expect(j['deadEvents'], 0);
        // looked-at connections that nothing took are there on a healthy stack too (that is why it is a count over a window)
        expect(j['lookedAt'], greaterThan(0));
      });
    }
  });

  group('the rule', () {
    test('nothing is judged in the first seconds after start (grace), then a dead stack is said once', () {
      final r = _Rig()..d.start('system');
      r.orphans(10);
      r.advance(TunIngressDetector.grace - const Duration(seconds: 1));
      r.other();
      expect(r.events, isEmpty);
      r.advance(const Duration(seconds: 2));
      r.other();
      expect(r.events.map((e) => e.kind), ['dead']);
      expect(r.events.single.data['synSeen'], 10);
      // silence does not repeat it
      r.advance(const Duration(seconds: 10));
      r.orphans(10);
      expect(r.events.length, 1);
    });

    test('one look-up too few is not enough; the one that makes N is', () {
      final r = _Rig()..d.start('mixed');
      r.advance(TunIngressDetector.grace + const Duration(seconds: 1));
      r.orphans(TunIngressDetector.minUnpaired - 1);
      expect(r.events, isEmpty);
      r.orphans(1);
      r.other(TunIngressDetector.pairLines + 1); // the last one has aged out of reach
      expect(r.events.map((e) => e.kind), ['dead']);
    });

    test('look-ups next to real lines are paired: a busy healthy stack stays silent', () {
      final r = _Rig()..d.start('gvisor');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < 200; i++) {
        r.tcp('com.example.app');
        r.dns();
        r.other(3);
        r.advance(const Duration(milliseconds: 200));
      }
      expect(r.events, isEmpty);
      expect(r.d.toJson()['unpaired'], 0);
    });

    test('a TCP connection in the window keeps it quiet however many look-ups there are', () {
      final r = _Rig()..d.start('gvisor');
      r.advance(const Duration(seconds: 6));
      r.tcp('com.example.app');
      r.orphans(30);
      expect(r.events, isEmpty);
      // ...and once it is older than the window, the same silence is dead
      r.advance(TunIngressDetector.window + const Duration(seconds: 1));
      r.orphans(TunIngressDetector.minUnpaired + 1);
      r.other(TunIngressDetector.pairLines + 1);
      expect(r.events.map((e) => e.kind), ['dead']);
    });

    test('UDP and DNS alive, TCP silent: dead (the outage itself)', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < 12; i++) {
        r.dns();
        r.other(TunIngressDetector.pairLines + 1); // the DNS packet takes the look-ups next to it, not the ones after
        r.orphans(1);
        r.advance(const Duration(seconds: 1));
      }
      expect(r.events.map((e) => e.kind), ['dead']);
    });

    test('the first TCP connection after it says back, with how long it was dead; a second outage is a second event', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      r.orphans(10);
      expect(r.events.map((e) => e.kind), ['dead']);
      r.advance(const Duration(seconds: 20));
      r.tcp('org.telegram.messenger.web');
      expect(r.events.map((e) => e.kind), ['dead', 'back']);
      final back = r.events.last;
      expect(back.data['stack'], 'system');
      expect(back.data['accepted'], 1);
      expect(back.data['deadMs'], 20000);
      expect(r.d.dead, isFalse);
      expect(r.d.toJson()['state'], 'ok');
      // later it stops again
      r.advance(TunIngressDetector.window + const Duration(seconds: 1));
      r.orphans(10);
      r.other(TunIngressDetector.pairLines + 1);
      expect(r.events.map((e) => e.kind), ['dead', 'back', 'dead']);
      expect(r.d.toJson()['deadEvents'], 2);
    });

    test('a connection of the proxy inbound is a real connection, not a look-up and not the tunnel\'s TCP', () {
      final r = _Rig()..d.start('mixed');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < 12; i++) {
        final id = r.nextId();
        r.d.onLine('INFO  [$id 0ms] inbound/mixed[mixed-in]: inbound connection to example.org:443');
        r.found('org.telegram.messenger.web', id: id);
        r.other(8);
      }
      expect(r.events, isEmpty, reason: 'the look-up of a connection that arrived is not an orphan');
      expect(r.d.toJson()['lookedAt'], 0);
      r.orphans(10);
      expect(r.events.map((e) => e.kind), ['dead'], reason: 'the proxy inbound\'s connections are no proof that the TUN carries TCP');
    });

    test('desktop: `found process path` lines count the same', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < 10; i++) {
        r.d.onLine(r'INFO  [' '${r.nextId()}' r' 0ms] router: found process path: C:\Program Files\App\app.exe');
        r.other(8);
      }
      expect(r.events.map((e) => e.kind), ['dead']);
      expect(r.events.single.data['apps'], [r'C:\Program Files\App\app.exe']);
    });

    test('coloured lines and the bare `INFO[0003]` form are read the same', () {
      final r = _Rig()..d.start('mixed');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < 10; i++) {
        r.d.onLine('\x1B[36mINFO\x1B[0m[0003] [${r.nextId()} 0ms] router: found package name: com.example.app');
        r.other(8);
      }
      expect(r.events.map((e) => e.kind), ['dead']);
    });

    test('stopped: lines are ignored, nothing is said; start counts from nothing', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      r.orphans(10);
      expect(r.d.dead, isTrue);
      r.d.stop();
      expect(r.d.toJson()['state'], 'off');
      r.orphans(20);
      expect(r.events.length, 1);
      r.d.start('system');
      expect(r.d.dead, isFalse);
      final j = r.d.toJson();
      expect([j['state'], j['tcp'], j['lookedAt'], j['deadEvents']], ['ok', 0, 0, 0]);
    });

    test('look-ups our own reject rules took are not a dead stack: said once as ownReject, the state stays ok', () {
      final r = _Rig()..d.start('system', ownRejects: ['ipv6Off']);
      r.advance(const Duration(seconds: 6));
      r.rejected(TunIngressDetector.minUnpaired + 4);
      expect(r.events.map((e) => e.kind), ['dead']);
      final e = r.events.single;
      expect(e.data['ownReject'], isTrue);
      expect(e.data['ownRejects'], ['ipv6Off']);
      expect(e.data['ownRejected'], greaterThanOrEqualTo(TunIngressDetector.minUnpaired));
      expect(r.d.dead, isFalse);
      expect(r.d.toJson()['state'], 'ok');
      expect(r.d.toJson()['deadEvents'], 0);
      r.rejected(10);
      expect(r.events.length, 1, reason: 'latched while the own rejects alone fill the window');
    });

    test('own rejects do not hide a stack that also ignores the rest: the other look-ups still make it dead', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      r.rejected(TunIngressDetector.minUnpaired);
      r.orphans(TunIngressDetector.minUnpaired - 1);
      r.other(TunIngressDetector.pairLines + 1);
      expect(r.events.every((e) => e.data['ownReject'] == true), isTrue, reason: 'seven of the others are not enough');
      expect(r.d.dead, isFalse);
      r.orphans(2);
      r.other(TunIngressDetector.pairLines + 1);
      expect(r.d.dead, isTrue);
      final last = r.events.last;
      expect(last.data.containsKey('ownReject'), isFalse);
      expect(last.data['ownRejected'], TunIngressDetector.minUnpaired);
    });

    test('look-ups that sing-box logs as forwarded ICMP / UDP flows (same id, info level) are explained: not a dead stack', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < TunIngressDetector.minUnpaired + 4; i++) {
        final id = r.nextId();
        r.found('com.example.app', id: id);
        r.d.onLine('INFO  [$id 0ms] router: pre-match: forward ${i.isEven ? 'icmp' : 'udp'} connection from 172.19.0.1 to 77.88.44.55 via outbound/direct[direct]');
        r.other(8);
      }
      r.other(TunIngressDetector.pairLines + 1);
      expect(r.events, isEmpty);
      expect(r.d.dead, isFalse);
      expect(r.d.toJson()['unpairedInWindow'], 0);
    });

    test('a reject line of an id that was never looked at is ignored', () {
      final r = _Rig()..d.start('system');
      r.advance(const Duration(seconds: 6));
      r.d.onLine('DEBUG [999999 0ms] router: pre-match[0] inbound=tun-in => reject(no_drop)');
      r.orphans(TunIngressDetector.minUnpaired);
      r.other(TunIngressDetector.pairLines + 1);
      expect(r.events.map((e) => e.kind), ['dead']);
      expect(r.events.single.data.containsKey('ownReject'), isFalse);
    });

    test('its memory is bounded: a long flood of unique ids does not grow it', () {
      final r = _Rig()..d.start('gvisor');
      r.advance(const Duration(seconds: 6));
      for (var i = 0; i < 20000; i++) {
        r.tcp('com.example.app');
        if (i % 50 == 0) r.advance(const Duration(milliseconds: 100));
      }
      expect(r.events, isEmpty);
      expect(r.d.toJson()['tcp'], 20000);
    });
  });
}
