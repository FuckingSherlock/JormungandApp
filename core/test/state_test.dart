// The UI snapshot on disk (ui-state.json): durable writes with .bak rotation, and recovery from
// a damaged file (a power cut left it full of NUL bytes). docs/core.md → "Состояние UI".
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _NoSysProxy extends SystemProxy {
  _NoSysProxy() : super(File('never-written'));

  @override
  bool get isSet => false;

  @override
  Future<void> restore() async {}
}

void main() {
  late Directory dir;
  late File file;
  late List<(String, String, Map<String, dynamic>, String)> told;

  SnapshotStore open({Duration bak2Every = Duration.zero}) =>
      SnapshotStore(file, bak2Every: bak2Every, onRecovery: (type, level, data, note) => told.add((type, level, data, note)));
  File side(String ext) => File('${file.path}$ext');
  List<String> corrupt() => [for (final e in dir.listSync()) if (e.path.contains('.corrupt-')) p.basename(e.path)];
  String text(File f) => f.readAsStringSync();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jorm-state');
    file = File(p.join(dir.path, 'ui-state.json'));
    told = [];
  });
  tearDown(() => dir.delete(recursive: true));

  group('writes', () {
    test('the previous good snapshot stays in .bak, the one before it in .bak2', () async {
      final s = open();
      await s.save({'n': 1});
      expect(side('.bak').existsSync(), isFalse); // nothing to keep yet
      await s.save({'n': 2});
      expect(jsonDecode(text(file)), {'n': 2});
      expect(jsonDecode(text(side('.bak'))), {'n': 1});
      await s.save({'n': 3});
      expect(jsonDecode(text(file)), {'n': 3});
      expect(jsonDecode(text(side('.bak'))), {'n': 2});
      expect(jsonDecode(text(side('.bak2'))), {'n': 1});
      expect(side('.tmp').existsSync(), isFalse);
      expect(told, isEmpty);
    });

    test('.bak2 moves on only when .bak is old enough', () async {
      final s = open(bak2Every: const Duration(hours: 1));
      for (var i = 1; i <= 4; i++) {
        await s.save({'n': i});
      }
      expect(jsonDecode(text(side('.bak'))), {'n': 3});
      expect(side('.bak2').existsSync(), isFalse); // every .bak was young: replaced, not kept
    });

    test('a store started on a good file keeps it as .bak at the first save', () async {
      file.writeAsStringSync(jsonEncode({'n': 1}));
      final s = open();
      expect(await s.read(), {'n': 1});
      await s.save({'n': 2});
      expect(jsonDecode(text(side('.bak'))), {'n': 1});
      expect(told, isEmpty);
    });
  });

  group('recovery', () {
    test('a NUL-filled file: the .bak is loaded, the file is rewritten and kept aside, an event goes out, saves work', () async {
      file.writeAsBytesSync(List.filled(354 * 1024, 0));
      side('.bak').writeAsStringSync(jsonEncode({'n': 7}));
      final s = open();
      expect(await s.read(), {'n': 7});
      expect(told, hasLength(1));
      final (type, level, data, note) = told.single;
      expect([type, level], ['stateRestored', 'warn']);
      expect(data['from'], 'bak');
      expect(data['reason'], 'nul');
      expect(data['savedAt'], isA<int>());
      expect(data['kept'], startsWith('ui-state.json.corrupt-'));
      expect(note, contains('nul'));
      expect(corrupt(), hasLength(1));
      expect(File(p.join(dir.path, corrupt().single)).lengthSync(), 354 * 1024); // kept as it was
      expect(jsonDecode(text(file)), {'n': 7}); // the copy is the file again

      await s.save({'n': 8});
      expect(jsonDecode(text(file)), {'n': 8});
      expect(await open().read(), {'n': 8});
      expect(told, hasLength(1)); // the next start is quiet
    });

    test('a damaged .bak is skipped for the .bak2', () async {
      file.writeAsStringSync('{"n": ');
      side('.bak').writeAsBytesSync([0, 0, 0]);
      side('.bak2').writeAsStringSync(jsonEncode({'n': 5}));
      final s = open();
      expect(await s.read(), {'n': 5});
      expect(told.single.$3['from'], 'bak2');
      expect(corrupt(), hasLength(2)); // the file and the .bak, both kept
      expect(side('.bak').existsSync(), isFalse);
    });

    test('garbage and no backup: starts empty, the file is kept aside, stateLost, saves work', () async {
      file.writeAsStringSync('not json at all');
      final s = open();
      expect(await s.read(), isNull);
      final (type, level, data, _) = told.single;
      expect([type, level], ['stateLost', 'error']);
      expect(data['reason'], 'invalid');
      expect(corrupt(), hasLength(1));
      expect(text(File(p.join(dir.path, corrupt().single))), 'not json at all');
      expect(file.existsSync(), isFalse);

      await s.save({'n': 1});
      expect(jsonDecode(text(file)), {'n': 1});
      expect(await open().read(), {'n': 1});
    });

    test('every kind of damage: empty, a JSON list, unreadable bytes', () async {
      for (final (bytes, why) in [
        (<int>[], 'empty'),
        (utf8.encode('[1, 2]'), 'notObject'),
        (<int>[0xff, 0xfe, 0x7b], 'invalid'),
      ]) {
        told.clear();
        for (final e in dir.listSync()) {
          e.deleteSync();
        }
        file.writeAsBytesSync(bytes);
        expect(await open().read(), isNull, reason: why);
        expect(told.single.$3['reason'], why);
        expect(told.single.$1, 'stateLost');
      }
    });

    test('a missing file with a .bak (a crash between the two renames): the copy is restored', () async {
      side('.bak').writeAsStringSync(jsonEncode({'n': 3}));
      final s = open();
      expect(await s.read(), {'n': 3});
      expect(told.single.$1, 'stateRestored');
      expect(told.single.$3['reason'], 'missing');
      expect(told.single.$3.containsKey('kept'), isFalse);
      expect(jsonDecode(text(file)), {'n': 3});
    });

    test('no file and no backup is a fresh start, quietly', () async {
      expect(await open().read(), isNull);
      expect(told, isEmpty);
    });

    test('a saved "no state" (null) is not damage', () async {
      file.writeAsStringSync('null');
      expect(await open().read(), isNull);
      expect(told, isEmpty);
      expect(corrupt(), isEmpty);
    });

    test('only the newest damaged files are kept', () async {
      for (var i = 0; i < 4; i++) {
        file.writeAsBytesSync([0, 0]);
        final s = SnapshotStore(file, keepCorrupt: 2);
        await s.read();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(corrupt(), hasLength(2));
    });

    test('every read and save works after a damaged load (no throw on either)', () async {
      file.writeAsBytesSync(List.filled(64, 0));
      final s = open();
      await s.read();
      await s.read();
      expect(await s.source('x'), isNull);
      expect(await s.patchSource('x', {}, {}), isFalse);
      await s.save({'n': 1});
    });
  });

  group('daemon', () {
    test('a damaged snapshot at start: the journal and the raw log tell, the UI gets the backup', () async {
      final data = p.join(dir.path, 'data');
      Directory(data).createSync(recursive: true);
      File(p.join(data, 'ui-state.json')).writeAsBytesSync(List.filled(4096, 0));
      File(p.join(data, 'ui-state.json.bak')).writeAsStringSync(jsonEncode({'sourceOrder': ['a']}));
      final d = Daemon(
        singBox: 'no-sing-box',
        dataDir: data,
        uiFile: 'none',
        exitCheck: (_) async => {'ip': '127.0.0.1'},
        sysProxy: _NoSysProxy(),
      );
      await d.init();
      try {
        final ev = (d.events.since(null)['events'] as List).cast<Map>();
        final e = ev.singleWhere((e) => e['type'] == 'stateRestored');
        expect([e['cat'], e['level']], ['core', 'warn']);
        expect((e['data'] as Map)['from'], 'bak');
        expect(e['log'], isA<int>()); // linked to its raw line
        expect(((d.log.since(null)['lines'] as List).cast<Map>()).any((l) => '${l['msg']}'.contains('restored the bak copy')), isTrue);
        expect(await d.store.read(), {'sourceOrder': ['a']});
      } finally {
        await d.shutdown();
      }
    });
  });
}
