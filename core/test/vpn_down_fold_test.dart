// «VPN не работает» in the Events list (docs/logs.md → «Свёртки» mechanisms 2 and 5, «VPN не работает»): the crash
// events are poured into the conn/vpnDown row (`joins`), and EventFeed.notify decides the one notification of the
// failure: vpnDown notifies, its pieces never, vpnUp replaces a shown notification whatever its own toggle, once per event.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

const sec = 1000;

EventRecord ev(
  int id,
  String cat,
  String type, {
  int at = 0,
  String level = 'info',
  Map<String, dynamic> data = const {},
  int? cause,
  int? opens,
  List<int>? joins,
  String? verdict,
  int rev = 0,
}) =>
    EventRecord.fromJson({
      'id': id,
      'at': at,
      'cat': cat,
      'type': type,
      'level': level,
      'own': false,
      'data': data,
      'cause': ?cause,
      'opens': ?opens,
      'joins': ?joins,
      'verdict': ?verdict,
      if (rev > 0) 'rev': rev,
    });

EventRecord crashed() => ev(1, 'core', 'crashed', level: 'error', verdict: 'confirmed');
EventRecord failed(int id, int at) => ev(id, 'core', 'restartFailed', at: at, level: 'error', cause: 1, verdict: 'consequence');
EventRecord vpnDown({int id = 10, List<int>? joins = const [1], int rev = 0}) =>
    ev(id, 'conn', 'vpnDown', at: 30 * sec, level: 'error', verdict: 'confirmed', joins: joins, rev: rev, data: {'causes': ['core'], 'proxy': 'kept'});
EventRecord restarted() => ev(12, 'core', 'restarted', at: 60 * sec, opens: 1, cause: 1);
EventRecord vpnUp({int id = 13, int opens = 10}) => ev(id, 'conn', 'vpnUp', at: 70 * sec, opens: opens, data: {'downMs': 40 * sec, 'causes': ['core']});

List<int> ids(EventGroup g) => [for (final e in g.items) e.id];

void main() {
  test('EventRecord reads joins as a list of ids; absent = null', () {
    expect(vpnDown().joins, [1]);
    expect(ev(2, 'conn', 'vpnDown', joins: [3, 4]).joins, [3, 4]);
    expect(crashed().joins, isNull);
  });

  group('foldEvents: joins (mechanism 5)', () {
    final journal = <EventRecord>[
      crashed(),
      failed(2, 1 * sec),
      failed(3, 5 * sec),
      vpnDown(),
      ev(11, 'sub', 'failed', at: 40 * sec, level: 'warn', cause: 10, verdict: 'consequence'),
      failed(14, 45 * sec), // a late try, still a consequence of the (merged) crash
      restarted(),
      ev(15, 'site', 'unreachable', at: 65 * sec, level: 'warn', cause: 10, verdict: 'consequence'),
    ];

    test('crashed + restartFailed + vpnDown + restarted and the consequences are ONE row; restarted is a step, not the close', () {
      final rows = foldEvents(journal);
      expect(rows, hasLength(1), reason: 'the crash row is gone from rows');
      final g = rows.single;
      expect(g.head!.id, 10);
      expect(ids(g), unorderedEquals([1, 2, 3, 10, 11, 14, 12, 15]));
      expect(g.closed, isFalse, reason: 'core/restarted of the merged crash does not close the failure');
      expect(g.closer, isNull);
      expect(g.level, 'error');
    });

    test('only conn/vpnUp closes the row; it is the closer of the joining event', () {
      final g = foldEvents([...journal, vpnUp()]).single;
      expect(g.closed, isTrue);
      expect(g.closer!.id, 13);
      expect(g.head!.id, 10);
      expect(ids(g), unorderedEquals([1, 2, 3, 10, 11, 14, 12, 15, 13]));
      expect(g.closedAfter, 40 * sec);
    });

    test('the row stands where the joining event stands; other rows keep their places', () {
      final rows = foldEvents([
        ev(0, 'sub', 'updated', at: 0, data: {'source': 's'}),
        crashed(),
        ev(2, 'site', 'blocked', at: 2 * sec, data: {'host': 'a.example', 'entry': 'e'}),
        failed(3, 5 * sec),
        vpnDown(),
        vpnUp(),
      ]);
      expect([for (final g in rows) g.head!.id], [0, 2, 10]);
    });

    test('later pieces of the merged crash (a repeat, a closer) land in the same row', () {
      final g = foldEvents([
        crashed(),
        vpnDown(),
        restarted(),
        ev(20, 'core', 'restartFailed', at: 61 * sec, level: 'error', cause: 1, verdict: 'consequence'),
      ]);
      expect(g, hasLength(1));
      expect(ids(g.single), containsAll([1, 10, 12, 20]));
    });

    test('a joins id that is not in the journal is ignored: the event is a row of its own, nothing throws', () {
      final rows = foldEvents([vpnDown(joins: [99, 98]), vpnUp()]);
      expect(rows, hasLength(1));
      expect(ids(rows.single), [10, 13]);
      expect(rows.single.closed, isTrue);
    });

    test('a partly known list joins what is there', () {
      final rows = foldEvents([crashed(), vpnDown(joins: [1, 99])]);
      expect(rows, hasLength(1));
      expect(ids(rows.single), unorderedEquals([1, 10]));
    });

    test('without joins an old-journal crash keeps its own row (core/down as before)', () {
      final rows = foldEvents([
        crashed(),
        ev(2, 'core', 'down', at: 30 * sec, level: 'error', cause: 1),
        ev(3, 'core', 'restarted', at: 60 * sec, opens: 1, cause: 1),
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.head!.id, 1);
      expect(rows.single.closed, isTrue);
    });

    test('folding twice gives the same rows; the input is not changed', () {
      final all = [...journal, vpnUp()];
      String sig(List<EventGroup> r) => [for (final g in r) '${g.head?.id}:${ids(g)}:${g.level}:${g.closed}'].join(';');
      expect(sig(foldEvents(all)), sig(foldEvents(all)));
      expect(all, hasLength(9));
    });
  });

  group('EventFeed.notify', () {
    test('vpnDown notifies under connLost, once per event even when it is changed in place', () {
      final feed = EventFeed();
      expect(feed.notify(null, vpnDown()), isTrue);
      expect(feed.notify(null, vpnDown()), isFalse);
      expect(feed.notify(null, vpnDown(rev: 1)), isFalse, reason: 'the causes changed in place: the text changes, no new signal');
    });

    test('connLost off or the master switch off: vpnDown does not notify', () {
      expect(EventFeed().notify({'connLost': false}, vpnDown()), isFalse);
      expect(EventFeed().notify({'enabled': false}, vpnDown()), isFalse);
    });

    test('the pieces never notify: crashed, restartFailed, restarted, consequences, old core/down', () {
      final feed = EventFeed();
      for (final e in [
        crashed(),
        failed(2, 1000),
        restarted(),
        ev(11, 'sub', 'failed', level: 'warn', cause: 10, verdict: 'consequence'),
        ev(16, 'site', 'unreachable', level: 'warn', cause: 10, verdict: 'consequence'),
        ev(17, 'core', 'down', level: 'error'),
        ev(18, 'conn', 'offline', level: 'warn'),
      ]) {
        expect(feed.notify(null, e), isFalse, reason: '${e.key} #${e.id}');
      }
    });

    for (final cfg in <Map<String, dynamic>?>[null, {'connLost': false}]) {
      test('vpnUp replaces a shown vpnDown whatever its own toggle (config $cfg at the close)', () {
        final feed = EventFeed();
        expect(feed.notify(null, vpnDown()), isTrue);
        expect(feed.notify(cfg, vpnUp()), isTrue, reason: 'no «VPN не работает» is left in the shade');
        expect(feed.notify(cfg, vpnUp()), isFalse, reason: 'once per event');
      });
    }

    test('vpnUp whose vpnDown was not shown follows its own toggle', () {
      final off = EventFeed();
      expect(off.notify({'connLost': false}, vpnDown()), isFalse);
      expect(off.notify({'connLost': false}, vpnUp()), isFalse);
      final on = EventFeed();
      expect(on.notify({'connLost': false}, vpnDown()), isFalse);
      expect(on.notify(null, vpnUp()), isTrue, reason: 'toggled on by the close: its own toggle decides');
    });

    test('a closer of another pair follows the same rule (conn/lost -> conn/restored)', () {
      EventRecord lost() => ev(30, 'conn', 'lost', level: 'warn', verdict: 'confirmed');
      EventRecord restored() => ev(31, 'conn', 'restored', opens: 30);
      final shown = EventFeed();
      expect(shown.notify(null, lost()), isTrue);
      expect(shown.notify({'connLost': false}, restored()), isTrue);
      final unshown = EventFeed();
      expect(unshown.notify({'connLost': false}, lost()), isFalse);
      expect(unshown.notify({'connLost': false}, restored()), isFalse);
    });

    test('a vpnUp for a different vpnDown does not ride on another failure\'s notification', () {
      final feed = EventFeed();
      expect(feed.notify(null, vpnDown(id: 10)), isTrue);
      expect(feed.notify({'connLost': false}, vpnUp(id: 41, opens: 40)), isFalse, reason: 'vpnDown 40 was never shown');
    });

    test('markNotified stays: true once per id', () {
      final feed = EventFeed();
      expect(feed.markNotified(7), isTrue);
      expect(feed.markNotified(7), isFalse);
    });
  });
}
