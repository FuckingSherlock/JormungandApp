// The event model's Sentinel fields (eventbook.dart): verdict / why / trail / cause survive the file and
// the API JSON, an old event without them loads as before, and `isQuiet` tells what must not notify.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-sev');
    file = File(p.join(tmp.path, 'events.jsonl'));
  });

  tearDown(() => tmp.delete(recursive: true));

  const trail = [
    {'code': 'suspect', 'params': {'kind': 'conn.failing'}, 'outcome': 'info', 'at': 1000},
    {'code': 'persist.window', 'params': {'ms': 20000}, 'outcome': 'fail', 'at': 21000},
  ];

  test('the fields are stored, written to the file, read back and shown by since()', () async {
    final book = EventBook(file, flushEvery: Duration.zero);
    final id = book.add('conn', 'failing', 'warn',
        verdict: 'confirmed', why: {'code': 'conn.timeout', 'params': {}}, trail: [...trail], cause: 3, data: {'host': 'a.com'});
    await book.flush();

    final back = EventBook(file);
    final e = (back.since(null)['events'] as List).single as Map<String, dynamic>;
    expect(e['id'], id);
    expect(e['verdict'], 'confirmed');
    expect(e['why'], {'code': 'conn.timeout', 'params': {}});
    expect(e['trail'], trail);
    expect(e['cause'], 3);
    expect(e['data'], {'host': 'a.com'});
    // and as JSON, the way the API sends it
    expect(jsonDecode(jsonEncode(back.since(null)))['events'][0]['trail'], trail);
  });

  test('an event nobody judged has none of the fields', () {
    final book = EventBook(null);
    book.add('conn', 'connected', 'info');
    final e = book.byId(0)!;
    for (final k in ['verdict', 'why', 'trail', 'cause']) {
      expect(e.containsKey(k), isFalse, reason: k);
    }
    expect(EventBook.isQuiet(e), isFalse);
  });

  test('an old journal (events written before the fields) still loads', () {
    file.writeAsStringSync([
      jsonEncode({'seq': 5}),
      jsonEncode({'id': 3, 'at': DateTime.now().millisecondsSinceEpoch, 'cat': 'conn', 'type': 'failing', 'level': 'warn', 'own': false, 'data': {'host': 'x'}}),
      jsonEncode({'id': 4, 'at': DateTime.now().millisecondsSinceEpoch, 'cat': 'conn', 'type': 'connected', 'level': 'info', 'own': true, 'data': {}}),
      '',
    ].join('\n'));
    final book = EventBook(file);
    final es = (book.since(null)['events'] as List).cast<Map<String, dynamic>>();
    expect(es.map((e) => e['id']), [3, 4]);
    expect(es.every((e) => !e.containsKey('verdict')), isTrue);
    expect(es.every((e) => !EventBook.isQuiet(e)), isTrue);
    // the new fields can be put on an old event
    expect(book.update(3, verdict: 'consequence', cause: 1, why: {'code': 'net.offline', 'params': {}}, appendTrail: [...trail]), isTrue);
    final e = book.byId(3)!;
    expect((e['verdict'], e['cause'], e['rev']), ('consequence', 1, 1));
    expect(e['trail'], trail);
  });

  test('update: the trail is appended, a verdict / why / cause replace, data is laid over', () {
    final book = EventBook(null);
    final id = book.add('conn', 'failing', 'warn', verdict: 'confirmed', trail: [trail[0]], data: {'a': 1});
    book.update(id, appendTrail: [trail[1]], data: {'b': 2});
    var e = book.byId(id)!;
    expect(e['trail'], trail);
    expect(e['data'], {'a': 1, 'b': 2});
    expect(e['verdict'], 'confirmed', reason: 'not given: kept');
    book.update(id, verdict: 'consequence', cause: 9, level: 'info');
    e = book.byId(id)!;
    expect((e['verdict'], e['cause'], e['level'], e['rev']), ('consequence', 9, 'info', 2));
    expect(book.since(null)['updated'], isNotEmpty);
  });

  test('isQuiet: only a confirmed event with no cause notifies', () {
    bool quiet(String? v, {int? cause}) => EventBook.isQuiet({'verdict': ?v, 'cause': ?cause});
    expect(quiet(null), isFalse, reason: 'not judged: the type\'s own rules decide');
    expect(quiet('confirmed'), isFalse);
    expect(quiet('confirmed', cause: 4), isTrue, reason: 'linked to a root afterwards');
    for (final v in ['blip', 'consequence', 'workaround', 'unexplained']) {
      expect(quiet(v), isTrue, reason: v);
      expect(EventBook.verdicts, contains(v));
    }
    expect(EventBook.verdicts, contains('confirmed'));
  });
}
