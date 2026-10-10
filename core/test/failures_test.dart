// ConnOutcome and FailureBook (docs/core.md → «Неудачные соединения»): what a closed connection says
// about itself, and the rolling book of the failed ones with the `conn/failing` event.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

ClosedConnection cc({
  String dest = 'example.org:443',
  int up = 0,
  int down = 0,
  int? ms = 5000,
  String outbound = 'route0/s::a',
  String pkg = 'org.example.app',
  String process = '',
  String network = 'tcp',
  String inbound = 'tun-in',
}) =>
    ClosedConnection(
      outbound: outbound,
      chain: [outbound, 'route0', 'proxy'],
      destination: dest,
      up: up,
      down: down,
      pkg: pkg,
      process: process,
      network: network,
      inbound: inbound,
      durationMs: ms,
    );

class _Rig {
  _Rig({this.ignored = const {}}) {
    book = FailureBook(
      now: () => t,
      ignored: (h) => ignored.contains(h),
      background: () => bg,
      emit: (data, {required bg}) {
        emitted.add((data, bg));
        return emitted.length;
      },
      update: (id, data) => updates.add((id, data)),
    )..start();
  }

  late final FailureBook book;
  final Set<String> ignored;
  DateTime t = DateTime.utc(2026, 10, 10, 12);
  bool bg = false;
  final emitted = <(Map<String, dynamic>, bool)>[];
  final updates = <(int, Map<String, dynamic>)>[];

  void advance(Duration d) => t = t.add(d);

  /// [n] failed requests, [every] apart.
  void fail(int n, {String dest = 'example.org:443', Duration every = const Duration(seconds: 1), String pkg = 'org.example.app', String outbound = 'route0/s::a', String inbound = 'tun-in', String network = 'tcp', int? ms = 5000}) {
    for (var i = 0; i < n; i++) {
      book.onClosed(cc(dest: dest, pkg: pkg, outbound: outbound, inbound: inbound, network: network, ms: ms));
      advance(every);
    }
  }

  void ok({String dest = 'example.org:443', String pkg = 'org.example.app', String outbound = 'route0/s::a'}) {
    book.onClosed(cc(dest: dest, pkg: pkg, outbound: outbound, down: 2000, ms: 300));
    advance(const Duration(seconds: 1));
  }
}

void main() {
  group('ConnOutcome', () {
    test('down > 0 is a success, whatever else; down == 0 is the failure Auto judges by', () {
      expect(ConnOutcome.isFailure(cc(down: 1)), isFalse);
      expect(ConnOutcome.isFailure(cc(down: 0)), isTrue);
      expect(ConnOutcome.of(cc(down: 1, ms: 10), hint: ConnKind.refused).kind, ConnKind.ok);
      expect(ConnOutcome.of(cc(down: 1)).ok, isTrue);
    });

    test('nothing back: instant refusal below 2 s, stalled when bytes went out, timeout when none did', () {
      expect(ConnOutcome.of(cc(up: 0, ms: 300)).kind, ConnKind.instantRefusal);
      expect(ConnOutcome.of(cc(up: 90, ms: 300)).kind, ConnKind.instantRefusal);
      expect(ConnOutcome.of(cc(up: 90, ms: ConnOutcome.instantMs)).kind, ConnKind.stalled);
      expect(ConnOutcome.of(cc(up: 0, ms: ConnOutcome.instantMs)).kind, ConnKind.timeout);
      expect(ConnOutcome.of(cc(up: 0, ms: 30000)).kind, ConnKind.timeout);
      expect(ConnOutcome.of(cc(up: 90, ms: 30000)).failed, isTrue);
    });

    test('a record without a lifetime: bytes sent = stalled, none = an instant refusal', () {
      expect(ConnOutcome.of(cc(up: 90, ms: null)).kind, ConnKind.stalled);
      expect(ConnOutcome.of(cc(up: 0, ms: null)).kind, ConnKind.instantRefusal);
    });

    test('a connection that sat unused for a minute and was closed is idle, not failed', () {
      final o = ConnOutcome.of(cc(up: 0, ms: ConnOutcome.idleMs));
      expect([o.ok, o.idle], [true, true]);
      expect(ConnOutcome.of(cc(up: 10, ms: ConnOutcome.idleMs)).idle, isFalse, reason: 'it sent something: a request that was swallowed');
    });

    test('the log\'s reason wins over the timing guess', () {
      expect(ConnOutcome.of(cc(up: 0, ms: 300), hint: ConnKind.dnsFail).kind, ConnKind.dnsFail);
      expect(ConnOutcome.of(cc(up: 0, ms: 90000), hint: ConnKind.reset).kind, ConnKind.reset);
    });

    test('kindOfError: what a failed dial says', () {
      expect(ConnOutcome.kindOfError('dial tcp 1.2.3.4:443: i/o timeout'), ConnKind.timeout);
      expect(ConnOutcome.kindOfError('context deadline exceeded'), ConnKind.timeout);
      expect(ConnOutcome.kindOfError('read tcp 10.0.0.2:5000->1.2.3.4:443: read: connection reset by peer'), ConnKind.reset);
      expect(ConnOutcome.kindOfError('write: broken pipe'), ConnKind.reset);
      expect(ConnOutcome.kindOfError('EOF'), ConnKind.reset);
      expect(ConnOutcome.kindOfError('dial tcp 1.2.3.4:443: connect: connection refused'), ConnKind.refused);
      expect(ConnOutcome.kindOfError('connect: network is unreachable'), ConnKind.refused);
      expect(ConnOutcome.kindOfError('reality verification failed'), ConnKind.refused);
      expect(ConnOutcome.kindOfError('lookup bad.example: no such host'), ConnKind.dnsFail);
      expect(ConnOutcome.kindOfError('context canceled'), isNull, reason: 'the client gave up: not the route\'s fault');
      expect(ConnOutcome.kindOfError('canceled by local'), isNull);
      expect(ConnOutcome.kindOfError('something nobody has seen'), isNull);
    });
  });

  group('SbLine and splitDest', () {
    test('the id and the body, in every form of the log', () {
      for (final raw in [
        '+0300 2026-10-10 14:51:33 INFO [3977205611 73ms] outbound/vless[a]: outbound connection to x:443',
        'INFO[0003] [3977205611 73ms] outbound/vless[a]: outbound connection to x:443',
        '2026-10-10T10:51:33.165Z INFO  [3977205611 73ms] outbound/vless[a]: outbound connection to x:443',
        '\x1B[36mINFO\x1B[0m[0003] \x1B[38;5;1m[3977205611 73ms]\x1B[0m outbound/vless[a]: outbound connection to x:443',
      ]) {
        final l = SbLine.parse(raw);
        expect(l.id, '3977205611', reason: raw);
        expect(l.body, 'outbound/vless[a]: outbound connection to x:443', reason: raw);
      }
      expect(SbLine.parse('INFO  outbound/direct[direct]: outbound connection to x:443').id, isNull);
    });

    test('host and port of a destination', () {
      expect(splitDest('example.org:443'), ('example.org', 443));
      expect(splitDest('[2001:db8::1]:443'), ('[2001:db8::1]', 443));
      expect(splitDest('example.org'), ('example.org', 0));
      expect(splitDest('[2001:db8::1]'), ('[2001:db8::1]', 0));
    });
  });

  group('conn/failing', () {
    test('three failures of one destination within a minute with no success between: one event', () {
      final r = _Rig();
      r.fail(2);
      expect(r.emitted, isEmpty);
      r.fail(1);
      expect(r.emitted.length, 1);
      final (data, bg) = r.emitted.single;
      expect(bg, isFalse);
      expect(data, {
        'app': 'org.example.app',
        'host': 'example.org',
        'port': 443,
        'outbound': 'route0/s::a',
        'route': 'route0',
        'kind': 'timeout',
        'count': 3,
        'windowMs': 60000,
        'source': 'closed',
      });
      // it stays one while the failures go on
      r.fail(10);
      expect(r.emitted.length, 1);
    });

    test('failures spread over more than a minute are not a streak', () {
      final r = _Rig();
      r.fail(5, every: const Duration(seconds: 40));
      expect(r.emitted, isEmpty);
    });

    test('a success in between resets it; after the success three more failures are a new event', () {
      final r = _Rig();
      r.fail(2);
      r.ok();
      r.fail(2);
      expect(r.emitted, isEmpty);
      r.fail(1);
      expect(r.emitted.length, 1);
      r.ok();
      r.advance(const Duration(seconds: 5));
      r.fail(3);
      expect(r.emitted.length, 2, reason: 'the same destination failing again after it worked: a second outage');
    });

    test('the kind is the one most of the streak had; a log reason decides a single record', () {
      final r = _Rig();
      r.fail(1, ms: 300); // instant refusal
      r.fail(2, ms: 30000); // timeouts
      expect(r.emitted.single.$1['kind'], 'timeout');
    });

    test('a destination of the same app through the same outbound joins the event (more), a different outbound is its own', () {
      final r = _Rig();
      r.fail(3, dest: 'a.example:443');
      expect(r.emitted.length, 1);
      r.fail(3, dest: 'b.example:443');
      r.fail(3, dest: 'c.example:5222');
      expect(r.emitted.length, 1);
      expect(r.updates.map((u) => [u.$1, u.$2]).toList(), [
        [1, {'more': 1}],
        [1, {'more': 2}],
      ]);
      r.fail(3, dest: 'a.example:443', outbound: 'route1/s::b');
      expect(r.emitted.length, 2);
      r.fail(3, dest: 'd.example:443', pkg: 'org.other.app');
      expect(r.emitted.length, 3);
      expect(r.emitted.last.$1['app'], 'org.other.app');
    });

    test('a group that is older than its window is a new event', () {
      final r = _Rig();
      r.fail(3, dest: 'a.example:443');
      r.advance(FailureBook.groupWindow + const Duration(seconds: 1));
      r.fail(3, dest: 'b.example:443');
      expect(r.emitted.length, 2);
    });

    test('at most maxEvents per 10 minutes; the numbers keep counting', () {
      final r = _Rig();
      for (var i = 0; i < FailureBook.maxEvents + 4; i++) {
        r.fail(3, dest: 'h$i.example:443', pkg: 'org.app.n$i');
      }
      expect(r.emitted.length, FailureBook.maxEvents);
      expect(r.book.toJson()['failed'], 3 * (FailureBook.maxEvents + 4));
      r.advance(FailureBook.window + const Duration(seconds: 1));
      r.fail(3, dest: 'late.example:443', pkg: 'org.app.late');
      expect(r.emitted.length, FailureBook.maxEvents + 1);
    });

    test('UDP, the tunnel\'s own requests and the probe inbound make no event; the probe is not even counted', () {
      final r = _Rig();
      r.fail(5, network: 'udp');
      r.fail(5, dest: 'b.example:443', inbound: 'tunnel-in');
      r.fail(5, dest: 'c.example:443', inbound: 'probe-in');
      expect(r.emitted, isEmpty);
      final j = r.book.toJson();
      expect(j['failed'], 10, reason: 'UDP and tunnel-in are counted, probe-in is not');
    });

    test('an ignored site is not counted at all', () {
      final r = _Rig(ignored: {'noisy.example'});
      r.fail(6, dest: 'noisy.example:443');
      expect(r.emitted, isEmpty);
      expect(r.book.toJson()['failed'], 0);
      expect(r.book.toJson()['entries'], 0);
    });

    test('a site Auto already reported (noteSite) gets no second event, its subdomains too; the numbers still count', () {
      final r = _Rig();
      r.book.noteSite('Blocked.Example');
      r.fail(4, dest: 'blocked.example:443');
      r.fail(4, dest: 'cdn.blocked.example:443');
      expect(r.emitted, isEmpty);
      expect(r.book.toJson()['failed'], 8);
      r.advance(FailureBook.coveredFor + const Duration(seconds: 1));
      r.fail(3, dest: 'blocked.example:443');
      expect(r.emitted.length, 1);
    });

    test('background: the event carries the flag and the book counts them apart', () {
      final r = _Rig()..bg = true;
      r.fail(3);
      expect(r.emitted.single.$2, isTrue);
      final j = r.book.toJson();
      expect([j['failed'], j['bgFailed']], [3, 3]);
      expect(((j['top'] as List).single as Map)['bgSince'], 3);
    });

    test('the process name instead of a package on the desktop', () {
      final r = _Rig();
      for (var i = 0; i < 3; i++) {
        r.book.onClosed(cc(pkg: '', process: r'C:\Program Files\App\app.exe', ms: 30000));
      }
      final d = r.emitted.single.$1;
      expect(d.containsKey('app'), isFalse);
      expect(d['process'], {'name': 'app.exe', 'path': r'C:\Program Files\App\app.exe'});
    });

    test('an emit that wrote nothing (null) is no event and no group', () {
      final book = FailureBook(now: () => DateTime.utc(2026), emit: (d, {required bg}) => null)..start();
      for (var i = 0; i < 5; i++) {
        book.onClosed(cc());
      }
      expect(book.toJson()['events'], 0);
    });
  });

  group('the log\'s reasons', () {
    test('a dial error line names the kind of the closed record that follows it', () {
      final r = _Rig();
      r.book.onLog('ERROR[0003] [123 4ms] connection: open connection to example.org:443 using outbound/vless[route0/s::a]: read tcp 10.0.0.2:5000->1.2.3.4:443: connection reset by peer');
      r.fail(1, ms: 300);
      final e = (r.book.toJson()['top'] as List).single as Map;
      expect(e['lastKind'], 'reset');
    });

    test('a reason of another outbound, or an old one, is not used', () {
      final r = _Rig();
      r.book.onLog('ERROR [1 0ms] connection: open connection to example.org:443 using outbound/vless[route9/other]: connection refused');
      r.fail(1, ms: 300);
      expect(((r.book.toJson()['top'] as List).single as Map)['lastKind'], 'instantRefusal');
      r.book.onLog('ERROR [2 0ms] connection: open connection to example.org:443 using outbound/vless[route0/s::a]: connection refused');
      r.advance(FailureBook.hintTtl + const Duration(seconds: 1));
      r.fail(1, ms: 300);
      expect(((r.book.toJson()['top'] as List).single as Map)['lastKind'], 'instantRefusal');
    });

    test('a request the client gave up is not marked by the log (timing decides)', () {
      final r = _Rig();
      r.book.onLog('ERROR [1 0ms] connection: open connection to example.org:443 using outbound/vless[route0/s::a]: context canceled');
      r.fail(1, ms: 30000);
      expect(((r.book.toJson()['top'] as List).single as Map)['lastKind'], 'timeout');
    });

    test('names that did not resolve are kept, counted, bounded', () {
      final r = _Rig();
      r.book.onLog('ERROR [1 0ms] dns: exchange failed for Bad.Example. IN A: no such host');
      r.book.onLog('ERROR [2 0ms] dns: exchange failed for bad.example. IN AAAA: no such host');
      for (var i = 0; i < FailureBook.maxDns + 10; i++) {
        r.book.onLog('ERROR [3 0ms] dns: exchange failed for h$i.example. IN A: timeout');
      }
      final dns = (r.book.toJson(top: 1000)['dns'] as List).cast<Map>();
      expect(dns.length, FailureBook.maxDns);
      r.book.start();
      r.book.onLog('ERROR [1 0ms] dns: exchange failed for Bad.Example. IN A: no such host');
      r.book.onLog('ERROR [2 0ms] dns: exchange failed for bad.example. IN AAAA: no such host');
      expect((r.book.toJson()['dns'] as List).single, {'host': 'bad.example', 'count': 2, 'lastAt': r.t.millisecondsSinceEpoch});
    });
  });

  group('the numbers', () {
    test('idle connections are not counted either way', () {
      final r = _Rig();
      r.book.onClosed(cc(up: 0, ms: 70000));
      final j = r.book.toJson();
      expect([j['ok'], j['failed'], j['entries']], [0, 0, 0]);
    });

    test('last 10 minutes slide, since-start does not', () {
      final r = _Rig();
      r.fail(2);
      r.ok();
      var j = r.book.toJson();
      expect([j['failed10m'], j['ok10m'], j['failed'], j['ok']], [2, 1, 2, 1]);
      r.advance(const Duration(minutes: 11));
      j = r.book.toJson();
      expect([j['failed10m'], j['ok10m'], j['failed'], j['ok']], [0, 0, 2, 1]);
    });

    test('per destination: kinds, counts, who and through what; worst first', () {
      final r = _Rig();
      r.fail(2, dest: 'a.example:443');
      r.fail(5, dest: 'b.example:443', pkg: 'org.other.app', outbound: 'route1/s::b');
      r.ok(dest: 'b.example:443', pkg: 'org.other.app', outbound: 'route1/s::b');
      final j = r.book.toJson();
      expect(j['apps'], [
        {'app': 'org.other.app', 'failed10m': 5, 'ok10m': 1, 'failedSince': 5, 'okSince': 1, 'bgSince': 0, 'destinations': 1},
        {'app': 'org.example.app', 'failed10m': 2, 'ok10m': 0, 'failedSince': 2, 'okSince': 0, 'bgSince': 0, 'destinations': 1},
      ]);
      final top = (j['top'] as List).cast<Map>();
      expect(top.map((e) => e['host']), ['b.example', 'a.example']);
      expect(top.first, containsPair('route', 'route1'));
      expect(top.first, containsPair('failed10m', 5));
      expect(top.first, containsPair('ok10m', 1));
      expect(top.first['byKind'], {'timeout': 5});
      expect(top.first.containsKey('failing'), isFalse, reason: 'it worked after the failures');
      expect(top.last.containsKey('failing'), isFalse, reason: 'two failures are not a streak');
      expect(j['byKind'], {'timeout': 7});
    });

    test('`failing` marks the destination whose streak was reported and has not worked since', () {
      final r = _Rig();
      r.fail(3);
      expect(((r.book.toJson()['top'] as List).single as Map)['failing'], isTrue);
      r.ok();
      expect(((r.book.toJson()['top'] as List).single as Map).containsKey('failing'), isFalse);
    });

    test('bounded: the entries and the lists', () {
      final r = _Rig();
      for (var i = 0; i < FailureBook.maxEntries + 150; i++) {
        r.book.onClosed(cc(dest: 'h$i.example:443', pkg: 'org.app.n${i % 7}', ms: 30000));
      }
      final j = r.book.toJson(top: 5);
      expect(j['entries'], lessThanOrEqualTo(FailureBook.maxEntries));
      expect((j['top'] as List).length, 5);
      expect((j['apps'] as List).length, 5);
      expect(j['failed'], FailureBook.maxEntries + 150, reason: 'the totals are not bounded by the entries');
    });

    test('stop keeps what was counted readable and takes nothing more; start begins from nothing', () {
      final r = _Rig();
      r.fail(3);
      r.book.stop();
      r.fail(3);
      var j = r.book.toJson();
      expect([j['active'], j['failed']], [false, 3]);
      r.book.start();
      j = r.book.toJson();
      expect([j['active'], j['failed'], j['entries'], j['events']], [true, 0, 0, 0]);
    });
  });
}
