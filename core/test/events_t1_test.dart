// Events t1, core stage (docs/logs.md → Каталог типов, Событие в приложении): the `op` / `opens` fields of the
// journal (written, read back from the disk, kept by update / repeated), and the notification rules of the
// new kinds (`appData`, `dnsFailed`, `connLost` for the connection failures).
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('op / opens in the journal', () {
    late Directory tmp;
    late File file;
    final books = <EventBook>[];
    var now = DateTime(2026, 10, 17, 12);

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jorm-t1');
      file = File(p.join(tmp.path, 'events.jsonl'));
    });
    tearDown(() async {
      await Future.wait(books.map((b) => b.flush()));
      books.clear();
      await tmp.delete(recursive: true);
    });

    EventBook book() {
      final b = EventBook(file, clock: () => now);
      books.add(b);
      return b;
    }

    Map<String, dynamic> get(EventBook b, int id) => b.byId(id)!;

    test('add: op and opens ride on the event top level, next to cause; absent = not written', () {
      final b = book();
      final a = b.add('conn', 'lost', 'warn');
      final c = b.add('conn', 'restored', 'info', opens: a, op: {'id': 'reconnect-1', 'kind': 'reconnect'});
      final plain = get(b, a);
      expect(plain.containsKey('op'), isFalse);
      expect(plain.containsKey('opens'), isFalse);
      expect(get(b, c)['opens'], a);
      expect(get(b, c)['op'], {'id': 'reconnect-1', 'kind': 'reconnect'});
      expect((get(b, c)['data'] as Map).containsKey('op'), isFalse, reason: 'not inside data');
      final viaApi = (b.since(null)['events'] as List).cast<Map>().last;
      expect([viaApi['op'], viaApi['opens']], [get(b, c)['op'], a], reason: '/api/events hands them out');
    });

    test('they survive a flush and a reload from the file; the line holds them', () async {
      final b = book();
      final a = b.add('core', 'crashed', 'error');
      final r = b.add('core', 'restarted', 'info', opens: a, op: {'id': 'x-7', 'kind': 'reconnect'}, cause: a);
      await b.flush();
      final line = jsonDecode(file.readAsLinesSync().last) as Map;
      expect([line['op'], line['opens'], line['cause']], [
        {'id': 'x-7', 'kind': 'reconnect'},
        a,
        a,
      ]);
      final again = book();
      expect(again.byId(r)!['op'], {'id': 'x-7', 'kind': 'reconnect'});
      expect(again.byId(r)!['opens'], a);
      expect(again.byId(a)!.containsKey('opens'), isFalse);
      final rec = EventRecord.fromJson(again.byId(r)!);
      expect(rec.opens, a);
      expect(rec.op, {'id': 'x-7', 'kind': 'reconnect'});
      expect(EventRecord.fromJson(again.byId(a)!).op, isNull);
      expect(EventRecord.fromJson(again.byId(a)!).opens, isNull);
    });

    test('update keeps op and opens (and the rewrite to the file keeps them too)', () async {
      final b = book();
      final a = b.add('sub', 'failed', 'warn', data: {'n': 1});
      final id = b.add('sub', 'back', 'info', opens: a, op: {'id': 'subUpdate-1', 'kind': 'subUpdate'});
      expect(b.update(id, data: {'n': 2}), isTrue);
      expect(get(b, id)['op'], {'id': 'subUpdate-1', 'kind': 'subUpdate'});
      expect(get(b, id)['opens'], a);
      await b.flush();
      final again = book();
      expect(again.byId(id)!['op'], {'id': 'subUpdate-1', 'kind': 'subUpdate'});
      expect(again.byId(id)!['opens'], a);
    });

    test('repeated keeps op and opens (it drops only the findings: verdict, why, trail, cause), also across repeats', () {
      final b = book();
      final root = b.add('core', 'crashed', 'error');
      final id = b.add('core', 'restartFailed', 'error', cause: root, op: {'id': 'reconnect-2', 'kind': 'reconnect'}, opens: root);
      expect(b.repeated(id, level: 'error'), 2);
      expect(b.repeated(id, level: 'error'), 3);
      expect(get(b, id)['op'], {'id': 'reconnect-2', 'kind': 'reconnect'});
      expect(get(b, id)['opens'], root);
      expect((get(b, id)['data'] as Map)['repeat']['count'], 3);
    });

    test('an old journal line without op / opens loads and reads as null', () {
      file.writeAsStringSync('${jsonEncode({'id': 0, 'at': now.millisecondsSinceEpoch, 'cat': 'conn', 'type': 'lost', 'level': 'warn', 'own': false, 'data': {}})}\n');
      final e = EventRecord.fromJson(book().byId(0)!);
      expect([e.op, e.opens], [null, null]);
    });
  });

  group('notification rules of t1', () {
    EventRecord ev(String cat, String type, {String level = 'info', Map<String, dynamic> data = const {}, bool bg = false}) =>
        EventRecord.fromJson({'id': 1, 'at': 1, 'cat': cat, 'type': type, 'level': level, 'own': false, 'bg': bg, 'data': data});

    test('kinds: the connection failures are connLost, the app data is appData, a DNS server is dnsFailed', () {
      for (final k in ['conn/connectFailed', 'conn/disconnected', 'core/tunNeedsAdmin', 'core/sysProxy']) {
        expect(eventNotifKind[k], 'connLost', reason: k);
      }
      expect(eventNotifKind['core/stateLost'], 'appData');
      expect(eventNotifKind['core/stateRestored'], 'appData');
      expect(eventNotifKind['dns/failed'], 'dnsFailed');
      expect(eventNotifKind.containsKey('dns/failedOnNode'), isFalse, reason: 'a consequence: the journal only');
      expect(eventNotifKind.containsKey('net/switched'), isFalse);
    });

    test('«VPN не работает»: vpnDown / vpnUp are connLost; the crash events, offline / online and core/down are not kinds any more', () {
      expect(eventNotifKind['conn/vpnDown'], 'connLost');
      expect(eventNotifKind['conn/vpnUp'], 'connLost');
      for (final k in ['core/crashed', 'core/restarted', 'core/restartFailed', 'conn/offline', 'conn/online', 'core/down']) {
        expect(eventNotifKind.containsKey(k), isFalse, reason: k);
      }
      for (final k in ['core/crashed', 'core/restartFailed', 'core/down']) {
        expect(journalOnly[k], isNotNull, reason: '$k: an error with a reason, journal only');
        expect(journalOnly[k]!.trim(), isNotEmpty);
      }
      expect(journalOnly['core/down'], contains('conn/vpnDown'));
      expect(eventCats.firstWhere((c) => c.$1 == 'conn').$2, containsAll(['vpnDown', 'vpnUp']));
      expect(eventCats.firstWhere((c) => c.$1 == 'core').$2, contains('down'), reason: 'old journals keep core/down');
      expect(notifDefaults.containsKey('coreCrash'), isFalse);
      expect(notifDefaults['connLost'], isTrue);
      expect(eventNotifies(null, ev('conn', 'vpnDown', level: 'error', data: {'causes': ['core']})), isTrue);
      expect(eventNotifies({'connLost': false}, ev('conn', 'vpnDown', level: 'error')), isFalse);
      expect(eventNotifies(null, ev('core', 'crashed', level: 'error')), isFalse);
      expect(eventNotifies(null, ev('core', 'restartFailed', level: 'error')), isFalse);
      expect(eventNotifies(null, ev('core', 'down', level: 'error')), isFalse);
    });

    test('defaults: appData and dnsFailed are on', () {
      expect(notifDefaults['appData'], isTrue);
      expect(notifDefaults['dnsFailed'], isTrue);
      expect(eventNotifies(null, ev('core', 'stateLost', level: 'warn')), isTrue);
      expect(eventNotifies(null, ev('dns', 'failed', level: 'warn')), isTrue);
    });

    test('the toggles of the new kinds and the master switch decide', () {
      expect(eventNotifies({'appData': false}, ev('core', 'stateLost', level: 'warn')), isFalse);
      expect(eventNotifies({'dnsFailed': false}, ev('dns', 'failed', level: 'warn')), isFalse);
      expect(eventNotifies({'dnsFailed': false}, ev('core', 'stateLost', level: 'warn')), isTrue, reason: 'another kind');
      expect(eventNotifies({'enabled': false}, ev('dns', 'failed', level: 'warn')), isFalse);
    });

    test('conn/disconnected notifies only by: error', () {
      expect(eventNotifies(null, ev('conn', 'disconnected', data: {'by': 'error', 'reason': 'down'})), isTrue);
      expect(eventNotifies(null, ev('conn', 'disconnected', level: 'error', data: {'by': 'error', 'reason': 'pinLost'})), isTrue);
      expect(eventNotifies(null, ev('conn', 'disconnected', data: {'by': 'user'})), isFalse);
      expect(eventNotifies({'connLost': false}, ev('conn', 'disconnected', data: {'by': 'error'})), isFalse);
    });

    test('core/sysProxy notifies only with an error', () {
      expect(eventNotifies(null, ev('core', 'sysProxy', level: 'warn', data: {'on': true, 'error': 'denied'})), isTrue);
      expect(eventNotifies(null, ev('core', 'sysProxy', data: {'on': true})), isFalse);
      expect(eventNotifies(null, ev('core', 'sysProxy', data: {'on': false, 'by': 'user'})), isFalse);
    });

    test('a confirmed root still needs no cause: a consequence of net/switched stays quiet', () {
      final e = EventRecord.fromJson({
        'id': 2, 'at': 1, 'cat': 'conn', 'type': 'lost', 'level': 'warn', 'own': false, 'verdict': 'confirmed', 'cause': 1, 'data': {}
      });
      expect(eventNotifies(null, e), isFalse);
    });

    test('journalOnly types never notify, whatever the config', () {
      for (final k in journalOnly.keys) {
        final parts = k.split('/');
        expect(eventNotifies({'bgErrors': true}, ev(parts[0], parts[1], level: 'warn')), isFalse, reason: k);
      }
    });
  });
}
