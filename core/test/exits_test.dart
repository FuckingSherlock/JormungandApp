// The exit book (exits.dart): what the exit check found per node, kept across a restart.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/src/exits.dart';
import 'package:test/test.dart';

void main() {
  test('flagOfCountry: an ISO code becomes the regional-indicator pair, anything else is empty', () {
    expect(flagOfCountry('de'), '\u{1F1E9}\u{1F1EA}');
    expect(flagOfCountry('XX1'), '');
    expect(flagOfCountry(''), '');
  });

  test('record: the IP is always the fresh one; a check that names no country keeps the last named', () {
    final b = ExitBook();
    b.record('n1', ip: '1.1.1.1', country: 'de', at: 10);
    b.record('n1', ip: '2.2.2.2', at: 20);
    expect([b['n1']!.ip, b['n1']!.country, b['n1']!.at], ['2.2.2.2', 'DE', 20]);
    b.record('n1', ip: '3.3.3.3', country: 'FR', at: 30);
    expect(b.countryOf('n1'), 'FR');
    expect(b.countryOf('none'), '');
  });

  test('refresh mark: set on a checked node only, taken once, kept by a new answer set meanwhile, saved in the file', () async {
    final b = ExitBook();
    b.markRefresh('none'); // never checked: no entry, due anyway
    expect(b.takeRefresh('none'), isFalse);
    b.record('n1', ip: '1.1.1.1', country: 'DE', at: 10);
    expect(b.takeRefresh('n1'), isFalse);
    b.markRefresh('n1');
    expect(b.toJson().single, containsPair('refresh', true));
    expect(b['n1']!.toJson().containsKey('refresh'), isFalse, reason: 'not a part of the status view');

    final dir = Directory('.data-dev/exits_test')..createSync(recursive: true);
    final file = File('${dir.path}/exit-nodes-refresh.json');
    if (file.existsSync()) file.deleteSync();
    final now = 20;
    final store = ExitBookStore(file, b, clock: () => now, debounce: Duration.zero);
    b.markRefresh('n1'); // already marked: nothing changes
    b.record('n2', ip: '2.2.2.2', at: 15);
    await store.close();
    final again = ExitBook();
    expect(ExitBookStore(file, again, clock: () => now).load(), 2);
    expect(again['n1']!.refresh, isTrue);
    expect(again['n2']!.refresh, isFalse);

    expect(again.takeRefresh('n1'), isTrue);
    expect(again.takeRefresh('n1'), isFalse, reason: 'once');
    expect(again['n1']!.ip, '1.1.1.1');
  });

  test('store: written after a change, read back by a new book; stale and damaged entries are left out', () async {
    final dir = Directory('.data-dev/exits_test')..createSync(recursive: true);
    final file = File('${dir.path}/exit-nodes.json');
    if (file.existsSync()) file.deleteSync();
    final day = const Duration(days: 1).inMilliseconds;
    var now = 100 * day;
    final book = ExitBook();
    final store = ExitBookStore(file, book, clock: () => now, debounce: Duration.zero);
    book.record('fresh', ip: '1.1.1.1', country: 'DE', at: now - day);
    book.record('stale', ip: '2.2.2.2', country: 'FR', at: now - 91 * day);
    await store.close();

    final j = jsonDecode(file.readAsStringSync()) as Map;
    expect((j['nodes'] as List).map((e) => (e as Map)['id']), ['fresh'], reason: 'the stale one is pruned at the write');

    final again = ExitBook();
    expect(ExitBookStore(file, again, clock: () => now).load(), 1);
    expect([again['fresh']!.ip, again['fresh']!.country, again['fresh']!.at], ['1.1.1.1', 'DE', now - day]);

    file.writeAsStringSync('{broken');
    expect(ExitBookStore(file, ExitBook(), clock: () => now).load(), 0);
    expect(ExitBook().load([{'id': 'x'}, 5, {'id': 'y', 'ip': '1.1.1.1', 'at': now, 'country': 'zz9'}], now), 1);
  });
}
