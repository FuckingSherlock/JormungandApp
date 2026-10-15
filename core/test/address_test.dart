// Node / DoH address pre-resolve (docs/rules.md §6 → «Адреса серверов»): the DNS wire codec, the address book,
// the resolver against a mock DoH on loopback (no real DNS server is asked), and the pins put into a config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A DoH server on loopback: `answers[name]` = the IPs (v4 and v6 mixed) it answers with; a name not in the map
/// is NXDOMAIN. Every question is counted by `name/type`.
class MockDoh {
  MockDoh(this.answers, {this.ttl = 300, this.delay = Duration.zero});
  final Map<String, List<String>> answers;
  final int ttl;

  /// How long the server takes to answer.
  final Duration delay;

  /// A different delay for some names.
  final delays = <String, Duration>{};

  /// Names it answers with SERVFAIL (rcode 2) instead of their addresses.
  final servfail = <String>{};
  final asked = <String>[];
  late HttpServer server;

  Future<MockDoh> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final q = base64Url.decode(base64Url.normalize(req.uri.queryParameters['dns']!));
      var i = 12;
      final labels = <String>[];
      while (q[i] != 0) {
        labels.add(utf8.decode(q.sublist(i + 1, i + 1 + q[i])));
        i += 1 + q[i];
      }
      final type = q[i + 1] << 8 | q[i + 2];
      final name = labels.join('.');
      asked.add('$name/$type');
      final wait = delays[name] ?? delay;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      final ips = answers[name];
      final rr = <int>[];
      var count = 0;
      for (final ip in ips ?? const <String>[]) {
        final a = InternetAddress(ip);
        if ((a.type == InternetAddressType.IPv4 ? 1 : 28) != type) continue;
        count++;
        rr.addAll([0xC0, 0x0C, 0, type, 0, 1, ttl >> 24 & 255, ttl >> 16 & 255, ttl >> 8 & 255, ttl & 255, 0, a.rawAddress.length, ...a.rawAddress]);
      }
      final question = q.sublist(12, i + 5);
      final head = [q[0], q[1], 0x81, ips == null ? 0x83 : (servfail.contains(name) ? 0x82 : 0x80), 0, 1, count >> 8, count & 255, 0, 0, 0, 0];
      req.response
        ..headers.contentType = ContentType('application', 'dns-message')
        ..headers.set('connection', 'close')
        ..add([...head, ...question, ...rr]);
      req.response.close();
    });
    return this;
  }

  String get url => 'http://127.0.0.1:${server.port}/dns-query';
  int count(String name, int type) => asked.where((a) => a == '$name/$type').length;
  Future<void> stop() => server.close(force: true);
}

final _sf = ServiceFetch(endpoint: () => null);

DnsCandidate doh(String id, String url, {String side = 'direct'}) => DnsCandidate(
    side: side, provider: id, kind: 'doh', n: 1, tag: 'dns-$id', addr: url, flagTag: 'f-$id', flagPath: 'f-$id', inUse: true);

DnsCandidate localC({String side = 'direct'}) =>
    DnsCandidate(side: side, provider: 'local', kind: 'system', n: 0, tag: 'dns-local', addr: 'system', flagTag: 'f-local', flagPath: 'f-local', inUse: true);

DnsCandidate udp(String id, String addr) =>
    DnsCandidate(side: 'direct', provider: id, kind: 'udp', n: 1, tag: 'dns-$id', addr: addr, flagTag: 'f-$id', flagPath: 'f-$id', inUse: true);

/// A port nothing listens on (a server that does not answer).
Future<String> deadDohUrl() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final url = 'http://127.0.0.1:${s.port}/dns-query';
  await s.close();
  return url;
}

void main() {
  late Directory tmp;
  late AddressBook book;
  var clock = DateTime(2026, 10, 12, 12);
  final log = <String>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-addr');
    clock = DateTime(2026, 10, 12, 12);
    log.clear();
    book = AddressBook(File(p.join(tmp.path, 'addresses.json')), now: () => clock);
  });
  tearDown(() {
    if (log.isNotEmpty) print(log.join('\n'));
    return tmp.delete(recursive: true);
  });

  AddressResolver resolver(List<DnsCandidate> cs,
          {bool ipv6 = false, DnsVerdictBook? verdicts, List<DnsCandidate> disabled = const [], Duration? attempt, void Function(DnsCandidate)? onNoAnswer, void Function(String)? onNameMissing}) =>
      AddressResolver(
        book: book,
        fetch: () => _sf,
        settings: () async => AddressSettings(candidates: cs, disabled: disabled, ipv6: ipv6),
        verdicts: verdicts,
        onNoAnswer: onNoAnswer,
        onNameMissing: onNameMissing,
        log: (l, t) => log.add('$l $t'),
        attempt: attempt ?? const Duration(seconds: 2),
        budget: const Duration(seconds: 6),
        now: () => clock,
      );

  group('dns_wire', () {
    test('query: header, labels, type, id; a bad name is null', () {
      final q = dnsQueryOf('Example.com', dnsTypeA, 0x1234)!;
      expect(q.sublist(0, 2), [0x12, 0x34]);
      expect(q[5], 1); // one question
      expect(q.sublist(12, 20), [7, ...'Example'.codeUnits]); // the case is kept
      expect(q.sublist(q.length - 4), [0, 1, 0, 1]);
      expect(dnsQueryOf('${'a' * 64}.com', dnsTypeA, 1), isNull);
      expect(dnsQueryOf('', dnsTypeA, 1), isNull);
    });

    test('answer: A with a compression pointer, AAAA text, smallest TTL, rcode and a wrong id', () {
      final q = dnsQueryOf('x.test', dnsTypeAaaa, 7)!;
      final v6 = InternetAddress('2001:db8::1').rawAddress;
      final v4 = InternetAddress('10.1.2.3').rawAddress;
      Uint8List reply(int id, int rcode) => Uint8List.fromList([
            id >> 8, id & 255, 0x81, 0x80 | rcode, 0, 1, 0, 2, 0, 0, 0, 0, ...q.sublist(12),
            0xC0, 0x0C, 0, 28, 0, 1, 0, 0, 1, 0x2C, 0, 16, ...v6,
            0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, ...v4,
          ]);
      final a = parseDnsAnswer(reply(7, 0), 7)!;
      expect(a.v6, ['2001:db8::1']);
      expect(a.v4, ['10.1.2.3']);
      expect(a.ttl, 60);
      expect(a.rcode, 0);
      expect(parseDnsAnswer(reply(7, 3), 7)!.rcode, 3);
      expect(parseDnsAnswer(reply(8, 0), 7), isNull);
      expect(parseDnsAnswer([1, 2, 3], 7), isNull);
    });
  });

  group('AddressBook', () {
    AddressEntry entry({int at = 0, int ttl = 300}) => AddressEntry(v4: ['1.1.1.1', '2.2.2.2'], v6: ['::1'], at: at, ttl: ttl, via: 'x', with6: true);

    test('persists to addresses.json and reloads, cursor included', () {
      book.put('Node.Example', entry(at: clock.millisecondsSinceEpoch));
      book.setCursor('node.example', 1);
      final again = AddressBook(File(p.join(tmp.path, 'addresses.json')), now: () => clock);
      expect(again.get('NODE.example')!.pick(false), '2.2.2.2');
      expect(again.get('node.example')!.pick(true), '2.2.2.2');
      expect(again.get('node.example')!.ips(true), ['1.1.1.1', '2.2.2.2', '::1']);
    });

    test('fresh = TTL clamped to 10 min .. 6 h; older than 30 days is forgotten', () {
      book.put('a', entry(at: clock.millisecondsSinceEpoch, ttl: 1));
      book.put('b', entry(at: clock.millisecondsSinceEpoch, ttl: 999999));
      clock = clock.add(const Duration(minutes: 9));
      expect(book.fresh('a'), isTrue); // 1 s counts as 10 min
      clock = clock.add(const Duration(minutes: 2));
      expect(book.fresh('a'), isFalse);
      expect(book.get('a'), isNotNull); // stale is still used
      expect(book.fresh('b'), isTrue);
      clock = clock.add(const Duration(hours: 6));
      expect(book.fresh('b'), isFalse); // 6 h cap
      clock = clock.add(const Duration(days: 31));
      expect(book.get('a'), isNull);
    });

    test('sameSet ignores the order; a damaged file starts empty', () {
      final a = entry(), b = AddressEntry(v4: ['2.2.2.2', '1.1.1.1'], v6: ['::1'], at: 0, ttl: 0, via: 'y');
      expect(a.sameSet(b), isTrue);
      expect(a.sameSet(AddressEntry(v4: ['1.1.1.1'], v6: const [], at: 0, ttl: 0, via: 'y')), isFalse);
      File(p.join(tmp.path, 'bad.json')).writeAsStringSync('{nope');
      expect(AddressBook(File(p.join(tmp.path, 'bad.json'))).length, 0);
    });
  });

  group('AddressResolver', () {
    late MockDoh good;
    setUp(() async => good = await MockDoh({'node.example': ['203.0.113.7', '203.0.113.8', '2001:db8::7']}).start());
    tearDown(() => good.stop());

    test('DoH: A stored with via / TTL; IPv6 off asks no AAAA, on asks it and stores v6', () async {
      final r = resolver([doh('g', good.url)]);
      final e = (await r.lookup('node.example', why: 'test'))!;
      expect(e.v4, ['203.0.113.7', '203.0.113.8']);
      expect(e.v6, isEmpty);
      expect(e.via, 'g');
      expect(e.ttl, 300);
      expect(good.count('node.example', 28), 0);
      expect(book.get('node.example'), isNotNull);

      final r6 = resolver([doh('g', good.url)], ipv6: true);
      final e6 = (await r6.lookup('node.example', why: 'test'))!;
      expect(good.count('node.example', 28), 1);
      expect(e6.v6, ['2001:db8::7']);
      expect(e6.with6, isTrue);
      expect(e6.ips(true), ['203.0.113.7', '203.0.113.8', '2001:db8::7']);
    });

    test('order: a dead DoH, then the next; a server judged dead is not asked; the OS resolver is last', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadUrl = 'http://127.0.0.1:${dead.port}/dns-query';
      await dead.close();
      final r = resolver([doh('dead', deadUrl), doh('g', good.url)]);
      expect((await r.lookup('node.example', why: 'test'))!.via, 'g');
      expect(log.any((l) => l.contains('via dead') && l.contains('failed')), isTrue);

      final vb = DnsVerdictBook()..record(dnsVerdictKey(doh('g', good.url), null), dead: true, at: 1);
      final skip = resolver([doh('g', good.url), doh('g2', '${good.url}?b=1')], verdicts: vb);
      good.asked.clear();
      expect((await skip.lookup('node.example', why: 'test'))!.via, 'g2');
      expect(log.any((l) => l.contains('g skipped (stored verdict: dead)')), isTrue);

      // nobody answers: the OS resolver (localhost is always known)
      final sys = resolver([doh('dead', deadUrl)]);
      expect((await sys.lookup('localhost', why: 'test'))!.via, 'system');
      // the vpn side is never used for a lookup
      good.asked.clear();
      final vpn = resolver([doh('v', good.url, side: 'vpn')]);
      await vpn.lookup('node.example', why: 'test');
      expect(good.asked, isEmpty);
    });

    test('no direct server on (every provider off, Local too): the OS resolver still answers', () async {
      expect((await resolver(const []).lookup('localhost', why: 'test'))!.via, 'system');
    });

    group('system work: the ladder, verdicts, evidence (docs/rules.md §6)', () {
      late MockDoh nx; // knows no name: NXDOMAIN to everything
      late String deadUrl;
      final missed = <String>[], missing = <String>[];
      setUp(() async {
        nx = await MockDoh({}).start();
        deadUrl = await deadDohUrl();
        missed.clear();
        missing.clear();
      });
      tearDown(() => nx.stop());

      AddressResolver res(List<DnsCandidate> cs, {List<DnsCandidate> disabled = const [], DnsVerdictBook? verdicts}) =>
          resolver(cs,
              disabled: disabled,
              verdicts: verdicts,
              attempt: const Duration(milliseconds: 400),
              onNoAnswer: (c) => missed.add(c.id),
              onNameMissing: missing.add);

      test('order: encrypted before plain, the OS resolver last whatever place the list gives it', () async {
        good.answers['order.example'] = ['203.0.113.9'];
        // Local first and a plain server (nothing listens there) before the DoH one: the DoH one answers first
        final r = res([localC(), udp('plain', '127.0.0.1:9'), doh('g', good.url)]);
        expect((await r.lookup('order.example', why: 'test'))!.via, 'g');
        expect(log.any((l) => l.contains('via plain')), isFalse, reason: 'the plain server was never asked');
        // a name only the OS resolver knows: the DoH server is asked (NXDOMAIN), then Local answers
        expect((await r.lookup('localhost', why: 'test'))!.via, 'local');
        expect(good.count('localhost', 1), 1);
        expect(missing, isEmpty);
      });

      test('a server judged dead is skipped, an alive or unknown one is asked, nothing is recorded for the skipped', () async {
        final vb = DnsVerdictBook()..record(dnsVerdictKey(doh('d', deadUrl), null), dead: true, at: 1);
        final r = res([doh('d', deadUrl), doh('g', good.url)], verdicts: vb);
        expect((await r.lookup('node.example', why: 'test'))!.via, 'g');
        expect(log.any((l) => l.contains('d skipped (stored verdict: dead)')), isTrue);
        expect(missed, isEmpty, reason: 'a skipped server is not asked, so it cannot miss');
        expect(vb.deadOf(dnsVerdictKey(doh('d', deadUrl), null)), isTrue);
      });

      test('every enabled server failed: the disabled ones, in order, Local last; an answer is their verdict (alive)', () async {
        final off = await MockDoh({'node.example': ['203.0.113.77']}).start();
        addTearDown(off.stop);
        final vb = DnsVerdictBook();
        final r = res([doh('d', deadUrl)], disabled: [localC(), doh('off', off.url)], verdicts: vb);
        final e = (await r.lookup('node.example', why: 'test'))!;
        expect(e.via, 'off', reason: 'Local is the last of the disabled ones');
        expect(e.v4, ['203.0.113.77']);
        expect(vb.deadOf(dnsVerdictKey(doh('off', off.url), null)), isFalse);
        expect(log.any((l) => l.contains('no enabled server gave an address, trying the disabled')), isTrue);

        // the OS resolver among the disabled ones answers a name only it knows
        final r2 = res([doh('d', deadUrl)], disabled: [doh('off', off.url), localC()], verdicts: vb);
        expect((await r2.lookup('localhost', why: 'test'))!.via, 'local');
        expect(vb.deadOf('system|system|direct'), isFalse);
        expect(vb.deadOf(dnsVerdictKey(doh('d', deadUrl), null)), isNull, reason: 'the enabled one that missed got no verdict');

        // an enabled server that answers: the disabled ones are not asked at all
        off.asked.clear();
        expect((await res([doh('g', good.url)], disabled: [doh('off', off.url)], verdicts: vb).lookup('node.example', why: 'test'))!.via, 'g');
        expect(off.asked, isEmpty);
      });

      test('no answer is evidence for the server\'s own check (onNoAnswer), never a verdict; the same racing', () async {
        final vb = DnsVerdictBook();
        final r = res([doh('d', deadUrl), doh('g', good.url)], verdicts: vb);
        expect((await r.lookup('node.example', why: 'test'))!.via, 'g');
        expect(missed, ['d']);
        expect(vb.length, 0);
        missed.clear();
        expect((await r.lookup('node.example', why: 'test', race: const Duration(milliseconds: 500)))!.via, 'g');
        await Future<void>.delayed(const Duration(milliseconds: 800)); // the dead server's miss lands after the winner
        expect(missed, ['d']);
        expect(vb.length, 0);
        // a disabled server that does not answer: evidence too, and still no verdict (only an answer is one)
        missed.clear();
        final off = await MockDoh({'node.example': ['203.0.113.77']}).start();
        addTearDown(off.stop);
        final r2 = res([], disabled: [doh('d2', deadUrl), doh('off', off.url), localC()], verdicts: vb);
        expect((await r2.lookup('node.example', why: 'test'))!.via, 'off');
        expect(missed, ['d2']);
        expect(vb.deadOf(dnsVerdictKey(doh('d2', deadUrl), null)), isNull);
        expect(vb.deadOf(dnsVerdictKey(doh('off', off.url), null)), isFalse);
      });

      test('NXDOMAIN or an empty answer is "the server works": the next server is asked, onNoAnswer and onNameMissing stay quiet', () async {
        final empty = await MockDoh({'node.example': <String>[]}).start();
        addTearDown(empty.stop);
        final r = res([doh('n', nx.url), doh('e', empty.url), doh('g', good.url)]);
        expect((await r.lookup('node.example', why: 'test'))!.via, 'g');
        expect(nx.count('node.example', 1), 1);
        expect(empty.count('node.example', 1), 1);
        expect(missed, isEmpty);
        expect(missing, isEmpty);
      });

      test('onNameMissing: every server that answered said the name does not exist (NXDOMAIN / empty), and only then', () async {
        final empty = await MockDoh({'gone.invalid': <String>[]}).start();
        addTearDown(empty.stop);
        expect(await res([doh('n', nx.url), doh('e', empty.url)]).lookup('gone.invalid', why: 'test'), isNull);
        expect(missing, ['gone.invalid']);
        expect(missed, isEmpty);

        // a server that does not answer is not an answer: the ones that did still say so
        missing.clear();
        expect(await res([doh('d', deadUrl), doh('n', nx.url)]).lookup('gone.invalid', why: 'test'), isNull);
        expect(missing, ['gone.invalid']);
        expect(missed, ['d']);

        // SERVFAIL is an answer, but not "no such name": the name may exist
        missing.clear();
        final sf = await MockDoh({'gone.invalid': <String>[]}).start();
        sf.servfail.add('gone.invalid');
        addTearDown(sf.stop);
        expect(await res([doh('n', nx.url), doh('sf', sf.url)]).lookup('gone.invalid', why: 'test'), isNull);
        expect(missing, isEmpty);

        // nobody answered at all: a DNS problem, not the node's name
        expect(await res([doh('d', deadUrl)]).lookup('gone.invalid', why: 'test'), isNull);
        expect(missing, isEmpty);
      });
    });

    test('ensure: cache first, missing waited for, stale refreshed in the background, a failed name left alone for a while', () async {
      final r = resolver([doh('g', good.url)]);
      book.put('cached.example', AddressEntry(v4: ['198.51.100.1'], v6: const [], at: clock.millisecondsSinceEpoch, ttl: 300, via: 'old'));
      book.put('stale.example', AddressEntry(v4: ['198.51.100.2'], v6: const [], at: clock.millisecondsSinceEpoch - 3600 * 1000, ttl: 300, via: 'old'));
      good.answers['stale.example'] = ['198.51.100.9'];
      await r.ensure(['cached.example', 'node.example', 'stale.example', 'gone.invalid'], why: 'connect');
      expect(good.count('cached.example', 1), 0);
      expect(book.get('node.example')!.v4, ['203.0.113.7', '203.0.113.8']); // waited for
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(book.get('gone.invalid'), isNull);
      final before = good.count('gone.invalid', 1);
      await r.ensure(['gone.invalid'], why: 'connect');
      expect(good.count('gone.invalid', 1), before); // negative cache (2 min)
      clock = clock.add(const Duration(minutes: 3));
      await r.ensure(['gone.invalid'], why: 'connect');
      expect(good.count('gone.invalid', 1), greaterThan(before));
    });

    test('ensure: a failed name is left alone for the 2 min also after a restart (addresses.json); later or after an answer it is asked again', () async {
      final file = File(p.join(tmp.path, 'addresses.json'));
      await resolver([doh('g', good.url)]).ensure(['gone.invalid'], why: 'connect');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(book.failedAt('gone.invalid'), clock.millisecondsSinceEpoch);
      final before = good.count('gone.invalid', 1);
      expect(before, greaterThan(0));

      // the app is closed and started again a minute later: a new book on the same file, a new resolver
      clock = clock.add(const Duration(minutes: 1));
      book = AddressBook(file, now: () => clock);
      expect(book.failedAt('gone.invalid'), isNotNull);
      await resolver([doh('g', good.url)]).ensure(['gone.invalid'], why: 'connect');
      expect(good.count('gone.invalid', 1), before, reason: 'a minute after the failure: not asked');

      clock = clock.add(const Duration(minutes: 2));
      book = AddressBook(file, now: () => clock);
      good.answers['gone.invalid'] = ['198.51.100.5'];
      await resolver([doh('g', good.url)]).ensure(['gone.invalid'], why: 'connect');
      expect(good.count('gone.invalid', 1), greaterThan(before), reason: 'three minutes after: asked again');
      expect(book.get('gone.invalid')!.v4, ['198.51.100.5']);
      expect(book.failedAt('gone.invalid'), isNull, reason: 'an answer ends the failure');
      expect(AddressBook(file, now: () => clock).failedAt('gone.invalid'), isNull, reason: 'also in the file');
    });

    test('a failure older than a day is forgotten at load', () {
      final file = File(p.join(tmp.path, 'addresses.json'));
      book.markFailed('old.example', clock.millisecondsSinceEpoch - const Duration(days: 2).inMilliseconds);
      book.markFailed('new.example', clock.millisecondsSinceEpoch - const Duration(hours: 2).inMilliseconds);
      final again = AddressBook(file, now: () => clock);
      expect(again.failedAt('old.example'), isNull);
      expect(again.failedAt('new.example'), isNotNull);
    });

    group('race (the connect wait)', () {
      late MockDoh slow, fast;
      setUp(() async {
        slow = await MockDoh({'node.example': ['203.0.113.1']}, delay: const Duration(milliseconds: 400)).start();
        fast = await MockDoh({'node.example': ['203.0.113.2']}).start();
      });
      tearDown(() async {
        await slow.stop();
        await fast.stop();
      });

      test('all servers are asked at once; the higher-priority one answering within the window wins over a faster one', () async {
        final r = resolver([doh('slow', slow.url), doh('fast', fast.url)]);
        final sw = Stopwatch()..start();
        final e = (await r.lookup('node.example', why: 'test', race: const Duration(milliseconds: 1500)))!;
        expect(e.via, 'slow');
        expect(e.v4, ['203.0.113.1']);
        expect(sw.elapsedMilliseconds, lessThan(1200)); // parallel, and no waiting out the window
        expect(fast.count('node.example', 1), 1, reason: 'the second server was asked without waiting for the first');
        expect(book.get('node.example')!.via, 'slow');
      });

      test('a higher-priority server too slow for the window: the answer that came in time is used', () async {
        final r = resolver([doh('slow', slow.url), doh('fast', fast.url)]);
        final sw = Stopwatch()..start();
        final e = (await r.lookup('node.example', why: 'test', race: const Duration(milliseconds: 150)))!;
        expect(e.via, 'fast');
        expect(sw.elapsedMilliseconds, inInclusiveRange(100, 350));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(book.get('node.example')!.via, 'fast', reason: 'a late answer does not replace it');
        expect(log.any((l) => l.contains('via slow') && l.contains('answered late')), isTrue);
      });

      test('nobody in time: the first answer wins, whenever it comes; every server failing falls to the next try', () async {
        final r = resolver([doh('slow', slow.url)]);
        final e = (await r.lookup('node.example', why: 'test', race: const Duration(milliseconds: 50)))!;
        expect(e.via, 'slow');

        final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final deadUrl = 'http://127.0.0.1:${dead.port}/dns-query';
        await dead.close();
        final none = resolver([doh('d1', deadUrl), doh('d2', deadUrl)]);
        expect(await none.lookup('nope.invalid', why: 'test', race: const Duration(milliseconds: 500)), isNull);
        expect((await none.lookup('localhost', why: 'test', race: const Duration(milliseconds: 500)))!.via, 'system'); // the OS resolver, last
      });

      test('ensure(need, race): the missing hosts of the needed ones are waited for, the others resolve in the background', () async {
        final r = resolver([doh('slow', slow.url)]);
        slow.answers['other.example'] = ['203.0.113.3'];
        await r.ensure(['node.example', 'other.example'], why: 'connect', need: ['node.example'], wait: const Duration(milliseconds: 1500), race: true);
        expect(book.get('node.example'), isNotNull);
        expect(log.any((l) => l.contains('1 to resolve') && l.contains('1 more in the background')), isTrue, reason: 'only the needed one is waited for');
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(book.get('other.example')!.v4, ['203.0.113.3'], reason: 'resolved in the background');
        expect(log.any((l) => l.contains('other.example') && l.contains('background]')), isTrue);
      });

      test('ensure: the wait is capped; the hosts not done keep going and land in the book', () async {
        final r = resolver([doh('slow', slow.url)]);
        final sw = Stopwatch()..start();
        await r.ensure(['node.example'], why: 'connect', wait: const Duration(milliseconds: 100), race: true);
        expect(sw.elapsedMilliseconds, lessThan(350));
        expect(book.get('node.example'), isNull);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(book.get('node.example')!.via, 'slow');
      });
    });

    test('simultaneous lookups of one name share one query; the same set keeps the cursor', () async {
      final r = resolver([doh('g', good.url)]);
      await Future.wait([r.lookup('node.example', why: 'a'), r.lookup('Node.Example', why: 'b')]);
      expect(good.count('node.example', 1), 1);
      book.setCursor('node.example', 1);
      final again = (await r.lookup('node.example', why: 'c'))!;
      expect(again.cursor, 1);
      good.answers['node.example'] = ['203.0.113.50'];
      expect((await r.lookup('node.example', why: 'd'))!.cursor, 0); // a different set starts over
    });
  });

  group('dnsDisabledOf', () {
    Map<String, dynamic> prov(String id, bool on, List<String> sides, List<Map<String, String>> transports, List<String> use) =>
        {'id': id, 'on': on, 'sides': sides, 'use': use, 'transports': transports};
    final dns = {
      'servers': [
        prov('cloudflare', true, ['direct', 'vpn'], [
          {'kind': 'doh', 'addr': 'https://1.1.1.1/dns-query'},
          {'kind': 'udp', 'addr': '1.1.1.1'},
        ], ['doh']),
        prov('google', false, ['direct'], [{'kind': 'doh', 'addr': 'https://8.8.8.8/dns-query'}], ['doh']),
        prov('adguard', true, ['vpn'], [{'kind': 'doh', 'addr': 'https://unfiltered.adguard-dns.com/dns-query'}], ['doh']),
        prov('mine', false, ['direct'], [{'kind': 'doh', 'addr': 'https://dns.mine.test/dns-query'}], ['doh']),
        prov('local', false, ['direct'], [{'kind': 'system', 'addr': 'system'}], ['system']),
      ],
    };

    test('built-in providers that are off, a kind not in use, or without the direct side; never a custom one, never an enabled one', () {
      expect([for (final c in dnsSidesOf(dns)['direct']!) c.id], ['cloudflare-doh1']);
      final off = dnsDisabledOf(dns, {'cloudflare', 'google', 'adguard', 'local'});
      expect([for (final c in off) c.id], ['cloudflare-udp1', 'google-doh1', 'adguard-doh1', 'local']);
      expect(off.every((c) => c.side == 'direct' && !c.inUse), isTrue);
      expect(off.last.kind, 'system');
      expect(off.first.addr, '1.1.1.1');
    });

    test('Local on: it is enabled, not disabled; nothing built-in left off: empty', () {
      final on = {
        'servers': [prov('local', true, ['direct'], [{'kind': 'system', 'addr': 'system'}], ['system'])]
      };
      expect(dnsDisabledOf(on, {'local'}), isEmpty);
      expect(dnsDisabledOf(dns, <String>{}), isEmpty);
    });
  });

  group('pins', () {
    const pins = {'node.example': '203.0.113.7'};
    Map<String, dynamic> ob(String type, {Map<String, dynamic>? extra}) => {'type': type, 'tag': 't', 'server': 'Node.Example', 'server_port': 8443, ...?extra};

    test('server becomes the IP; TLS keeps the name as SNI; an own server_name (Reality) is never touched', () {
      final tls = pinOutbound(ob('vless', extra: {'tls': {'enabled': true}}), pins);
      expect(tls['server'], '203.0.113.7');
      expect((tls['tls'] as Map)['server_name'], 'Node.Example');
      final own = pinOutbound(ob('vless', extra: {'tls': {'enabled': true, 'server_name': 'front.test', 'reality': {'enabled': true}}}), pins);
      expect((own['tls'] as Map)['server_name'], 'front.test');
      expect((own['tls'] as Map)['reality'], {'enabled': true});
      final noSni = pinOutbound(ob('trojan', extra: {'tls': {'enabled': true, 'disable_sni': true}}), pins);
      expect((noSni['tls'] as Map).containsKey('server_name'), isFalse);
      final plain = pinOutbound(ob('shadowsocks'), pins);
      expect(plain['server'], '203.0.113.7');
      expect(plain.containsKey('tls'), isFalse);
    });

    test('transports: ws Host name:port (case-insensitive existing Host kept), httpupgrade host, http host only without TLS, grpc plain not pinned', () {
      final ws = pinOutbound(ob('vless', extra: {'transport': {'type': 'ws', 'path': '/'}}), pins);
      expect((ws['transport'] as Map)['headers'], {'Host': 'Node.Example:8443'});
      final wsOwn = pinOutbound(ob('vless', extra: {'transport': {'type': 'ws', 'headers': {'host': 'cdn.test'}}}), pins);
      expect((wsOwn['transport'] as Map)['headers'], {'host': 'cdn.test'});
      final hu = pinOutbound(ob('vless', extra: {'transport': {'type': 'httpupgrade'}}), pins);
      expect((hu['transport'] as Map)['host'], 'Node.Example:8443');
      expect((pinOutbound(ob('vless', extra: {'transport': {'type': 'httpupgrade', 'host': 'h.test'}}), pins)['transport'] as Map)['host'], 'h.test');
      // h2 over TLS: sing-box sends :authority www.example.com whatever the server (measured), nothing to keep
      final h2 = pinOutbound(ob('vless', extra: {'tls': {'enabled': true}, 'transport': {'type': 'http'}}), pins);
      expect((h2['transport'] as Map).containsKey('host'), isFalse);
      final h1 = pinOutbound(ob('vless', extra: {'transport': {'type': 'http'}}), pins);
      expect((h1['transport'] as Map)['host'], ['Node.Example']);
      final grpcPlain = ob('vless', extra: {'transport': {'type': 'grpc'}});
      expect(pinOutbound(grpcPlain, pins), same(grpcPlain));
      final grpcTls = pinOutbound(ob('vless', extra: {'tls': {'enabled': true}, 'transport': {'type': 'grpc'}}), pins);
      expect(grpcTls['server'], '203.0.113.7');
    });

    test('left as they are: no pin (uncached), an IP, a chain exit (detour), Shadowsocks with a plugin, groups', () {
      final plain = ob('vless');
      expect(pinOutbound(plain, const {}), same(plain));
      expect(pinOutbound(plain, {'other.example': '1.1.1.1'}), same(plain));
      final ip = {...plain, 'server': '192.0.2.1'};
      expect(pinOutbound(ip, pins), same(ip));
      final exit = ob('vless', extra: {'detour': 'route0-entry'});
      expect(pinOutbound(exit, pins), same(exit));
      final plugin = ob('shadowsocks', extra: {'plugin': 'obfs-local'});
      expect(pinOutbound(plugin, pins), same(plugin));
      final sel = {'type': 'selector', 'tag': 's', 'outbounds': ['a']};
      expect(pinOutbound(sel, pins), same(sel));
    });

    test('DNS servers: https gets Host and server_name, tls server_name, udp the IP only; domain_resolver goes', () {
      final https = pinDnsServer({'type': 'https', 'tag': 'a', 'server': 'dns.example', 'domain_resolver': 'local'}, {'dns.example': '9.9.9.9'});
      expect(https['server'], '9.9.9.9');
      expect((https['tls'] as Map)['server_name'], 'dns.example');
      expect((https['headers'] as Map)['Host'], 'dns.example');
      expect(https.containsKey('domain_resolver'), isFalse);
      final tls = pinDnsServer({'type': 'tls', 'tag': 'b', 'server': 'dns.example'}, {'dns.example': '9.9.9.9'});
      expect((tls['tls'] as Map)['server_name'], 'dns.example');
      final udp = pinDnsServer({'type': 'udp', 'tag': 'c', 'server': 'dns.example'}, {'dns.example': '9.9.9.9'});
      expect(udp['server'], '9.9.9.9');
      expect(udp.containsKey('tls'), isFalse);
      final unpinned = {'type': 'https', 'tag': 'a', 'server': 'dns.example', 'domain_resolver': 'local'};
      expect(pinDnsServer(unpinned, const {}), same(unpinned));
    });

    Map<String, dynamic> node(String key, String server, {Map<String, dynamic>? extra}) => {
          'key': key,
          'outbound': {'type': 'vless', 'server': server, 'server_port': 443, ...?extra},
        };
    Map<String, dynamic> group(List<Map<String, dynamic>> nodes) => {'pick': 'fastest', 'nodes': nodes};
    final plan = <String, dynamic>{
      'routes': [
        {'kind': 'unit', 'main': group([node('a', 'one.example'), node('ip', '192.0.2.5')])},
        {'kind': 'chain', 'entry': group([node('e', 'entry.example')]), 'main': group([node('x', 'exit.example', extra: {'detour': 'route1-entry'})])},
      ],
      'routing': {
        'targets': {
          't1': {'kind': 'unit', 'main': group([node('tn', 'target.example')])},
          't2': {'kind': 'chain', 'entry': group([node('te', 'tentry.example')]), 'main': group([node('tx', 'texit.example')])},
        },
      },
    };

    test('planHostnames / memberHostname: routes, rule targets, chains (entry only), pinsFor from the book', () {
      expect(planHostnames(plan), {'one.example', 'entry.example', 'target.example', 'tentry.example'});
      expect(memberHostname(plan, 'route0', 'a'), 'one.example');
      expect(memberHostname(plan, 'route0', 'ip'), isNull);
      expect(memberHostname(plan, 'route1-entry', 'e'), 'entry.example');
      expect(memberHostname(plan, 'route1', 'x'), isNull); // the exit dials through its entry
      expect(memberHostname(plan, 't1', 'tn'), 'target.example');
      expect(memberHostname(plan, 't2>entry', 'te'), 'tentry.example');
      expect(memberHostname(plan, 't2', 'tx'), isNull);
      expect(memberHostname(plan, 't9', 'tn'), isNull);
      expect(memberHostname(plan, 't1', 'nope'), isNull);

      book.put('One.Example', AddressEntry(v4: ['203.0.113.1'], v6: ['2001:db8::1'], at: clock.millisecondsSinceEpoch, ttl: 0, via: 'x'));
      expect(pinsFor(['one.example', 'entry.example'], book, ipv6: false), {'one.example': '203.0.113.1'});
      book.setCursor('one.example', 1);
      expect(pinsFor(['one.example'], book, ipv6: true), {'one.example': '2001:db8::1'});
      expect(pinsFor(['one.example'], book, ipv6: false), {'one.example': '203.0.113.1'}); // the cursor is clamped to the IPv4 list
    });

    test('buildConfig and buildTesterConfig pin the nodes; an exit and a name without an address stay', () {
      final cfg = buildConfig(plan, pins: {'one.example': '203.0.113.1', 'target.example': '203.0.113.2'});
      final byTag = {for (final o in cfg['outbounds'] as List) (o as Map)['tag']: o};
      expect(byTag['route0/a']!['server'], '203.0.113.1');
      expect(byTag['route1-entry/e']!['server'], 'entry.example'); // no pin: the name
      final tester = buildTesterConfig(nodes: [node('a', 'one.example')], pairs: [
        {'key': 'p', 'entry': node('e', 'one.example'), 'exit': node('x', 'one.example')},
      ], pins: {'one.example': '203.0.113.1'});
      final t = {for (final o in tester['outbounds'] as List) (o as Map)['tag']: o};
      expect(t['t/a']!['server'], '203.0.113.1');
      expect(t['pe/p']!['server'], '203.0.113.1');
      expect(t['p/p']!['server'], 'one.example'); // the exit is reached through its entry
      expect(buildTesterConfig(nodes: [node('a', 'one.example')])['outbounds'][1]['server'], 'one.example');
    });

    test('buildTesterConfig: the resolver of node names is the top of the system chain; none for a pinned server and a pair exit', () {
      final top = doh('cf', 'https://cloudflare-dns.com/dns-query');
      Map<String, Map> byTag(Map<String, dynamic> cfg) => {for (final o in cfg['outbounds'] as List) (o as Map)['tag'] as String: o};
      List<String> dnsTags(Map<String, dynamic> cfg) => [for (final s in (cfg['dns'] as Map)['servers'] as List) (s as Map)['tag'] as String];

      // an unpinned name: its outbound resolves through the server, which is one of the tester's DNS servers
      final plain = buildTesterConfig(nodes: [node('a', 'one.example')], nodeResolver: top);
      expect(byTag(plain)['t/a']!['domain_resolver'], 'dns-cf');
      expect(dnsTags(plain), ['local', 'dns-cf']);
      // a pinned one has an address: nothing to resolve, and the server is not added when nothing uses it
      final pinned = buildTesterConfig(nodes: [node('a', 'one.example')], pins: {'one.example': '203.0.113.1'}, nodeResolver: top);
      expect(byTag(pinned)['t/a']!.containsKey('domain_resolver'), isFalse);
      expect(dnsTags(pinned), ['local']);
      // a pair: the entry by name resolves like a node, the exit is reached through the entry
      final pair = buildTesterConfig(nodes: const [], pairs: [
        {'key': 'p', 'entry': node('e', 'entry.example'), 'exit': node('x', 'exit.example')},
      ], nodeResolver: top);
      expect(byTag(pair)['pe/p']!['domain_resolver'], 'dns-cf');
      expect(byTag(pair)['p/p']!.containsKey('domain_resolver'), isFalse);
      // no resolver given: the OS one, as before
      final none = buildTesterConfig(nodes: [node('a', 'one.example')]);
      expect(byTag(none)['t/a']!.containsKey('domain_resolver'), isFalse);
      expect(dnsTags(none), ['local']);
      // the choice itself: encrypted first, the OS resolver and DoQ never, an unusable one skipped
      expect(nodeResolverCandidate([localC(), udp('q9', '9.9.9.9'), top], (_) => true)!.tag, 'dns-cf');
      expect(nodeResolverCandidate([localC(), udp('q9', '9.9.9.9')], (c) => c.provider != 'cf')!.tag, 'dns-q9');
      expect(nodeResolverCandidate([localC()], (_) => true), isNull);
    });
  });
}
