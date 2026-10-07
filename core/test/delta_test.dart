// Delta patches (docs/updates.md -> "Дельта-обновления"): the generator and the applier on
// synthetic files in the temp dir. Nothing leaves the machine.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List noise(Random r, int n) {
  final b = Uint8List(n);
  final d = ByteData.sublistView(b);
  var i = 0;
  for (; i + 4 <= n; i += 4) {
    d.setUint32(i, r.nextInt(1 << 32));
  }
  for (; i < n; i++) {
    b[i] = r.nextInt(256);
  }
  return b;
}

Uint8List cat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final x in parts) {
    b.add(x);
  }
  return b.takeBytes();
}

void main() {
  late Directory tmp;
  final r = Random(11);
  var n = 0;

  setUp(() => tmp = Directory.systemTemp.createTempSync('jorm_delta_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File write(String name, List<int> bytes) => File(p.join(tmp.path, name))..writeAsBytesSync(bytes);

  /// Makes the patch old -> neu, applies it, expects the new bytes back. Returns the stats.
  Future<DeltaStats> roundtrip(List<int> old, List<int> neu, {int block = 4096}) async {
    final id = n++;
    final o = write('old$id', old), nw = write('new$id', neu);
    final patch = p.join(tmp.path, 'patch$id'), out = p.join(tmp.path, 'out$id');
    final stats = await makeDelta(oldPath: o.path, newPath: nw.path, outPath: patch, blockSize: block);
    expect(stats.patchSize, File(patch).lengthSync());
    expect(stats.copyBytes + stats.literalBytes, neu.length);
    final h = await readDeltaHeader(patch);
    expect(h.oldSize, old.length);
    expect(h.newSize, neu.length);
    expect(h.oldSha256, sha256.convert(old).toString());
    expect(h.newSha256, sha256.convert(neu).toString());
    await applyDelta(oldPath: o.path, patchPath: patch, outPath: out, expectOldSha256: h.oldSha256, expectNewSha256: h.newSha256);
    expect(File(out).readAsBytesSync(), neu);
    return stats;
  }

  group('roundtrip', () {
    test('identical files: one copy, a patch of a few hundred bytes', () async {
      final old = noise(r, 600000);
      final s = await roundtrip(old, old);
      expect(s.copyOps, 1);
      expect(s.patchSize, lessThan(4096 + 200)); // header + the last partial block (random: it does not compress)
    });

    test('bytes inserted and deleted: everything after still matches (shifted blocks)', () async {
      final old = noise(r, 800000);
      final neu = cat([old.sublist(0, 250000), noise(r, 1111), old.sublist(250000, 500000), old.sublist(500777)]);
      final s = await roundtrip(old, neu);
      // random data does not compress: the patch is the inserted bytes plus the few that straddle blocks
      expect(s.patchSize, lessThan(1111 + 3 * 4096 + 1000));
      expect(s.literalBytes, lessThan(1111 + 4 * 4096));
    });

    test('a changed middle costs about the changed bytes', () async {
      final old = noise(r, 1000000);
      final mid = noise(r, 200000);
      final neu = cat([old.sublist(0, 400000), mid, old.sublist(600000)]);
      final s = await roundtrip(old, neu);
      expect(s.patchSize, greaterThan(190000));
      expect(s.patchSize, lessThan(200000 + 2 * 4096 + 1000));
    });

    test('a small change inside a block is extended around: only the changed bytes are literal', () async {
      final old = noise(r, 500000);
      final neu = Uint8List.fromList(old);
      for (final at in [10000, 123456, 400001]) {
        for (var i = 0; i < 40; i++) {
          neu[at + i] ^= 0xFF;
        }
      }
      final s = await roundtrip(old, neu);
      expect(s.literalBytes, lessThan(3 * 40 + 3 * 200)); // the changed bytes, a few more
    });

    test('appended data', () async {
      final old = noise(r, 300000);
      final s = await roundtrip(old, cat([old, noise(r, 100000)]));
      expect(s.patchSize, greaterThan(100000));
      expect(s.patchSize, lessThan(100000 + 5000));
    });

    test('truncated and prepended data', () async {
      final old = noise(r, 300000);
      await roundtrip(old, old.sublist(0, 123457));
      final s = await roundtrip(old, cat([noise(r, 5000), old]));
      expect(s.patchSize, lessThan(5000 + 3000));
    });

    test('empty old file: all literal; empty new file; both empty', () async {
      final neu = noise(r, 50000);
      final s = await roundtrip(Uint8List(0), neu);
      expect(s.copyBytes, 0);
      await roundtrip(neu, Uint8List(0));
      await roundtrip(Uint8List(0), Uint8List(0));
    });

    test('files shorter than a block', () async {
      await roundtrip(noise(r, 100), noise(r, 300));
      await roundtrip(noise(r, 4095), noise(r, 4097));
      final old = noise(r, 9000);
      await roundtrip(old, old.sublist(0, 4096));
    });

    test('runs of zeros (identical blocks) and repeated content', () async {
      final unit = noise(r, 4096);
      final old = cat([Uint8List(300000), for (var i = 0; i < 50; i++) unit, noise(r, 70000), Uint8List(100000)]);
      final neu = cat([noise(r, 77), Uint8List(150000), for (var i = 0; i < 20; i++) unit, noise(r, 10), old.sublist(250000, 600000)]);
      await roundtrip(old, neu);
      await roundtrip(old, old);
    });

    test('a smaller block size finds finer changes', () async {
      final old = noise(r, 200000);
      final neu = cat([old.sublist(0, 50000), noise(r, 300), old.sublist(50000)]);
      final s = await roundtrip(old, neu, block: 128);
      expect(s.literalBytes, lessThan(300 + 2 * 128));
    });

    test('random edit scripts, several block sizes', () async {
      final rr = Random(5);
      for (var t = 0; t < 12; t++) {
        final old = noise(rr, 20000 + rr.nextInt(80000));
        final parts = <List<int>>[];
        var at = 0;
        while (at < old.length) {
          final take = min(old.length - at, 1 + rr.nextInt(15000));
          switch (rr.nextInt(4)) {
            case 0:
              parts.add(old.sublist(at, at + take));
            case 1:
              parts.add(noise(rr, 1 + rr.nextInt(2000))); // replaced
            case 2:
              parts.add(old.sublist(at, at + take));
              parts.add(noise(rr, 1 + rr.nextInt(500))); // inserted after
            default: // deleted
              break;
          }
          at += take;
        }
        await roundtrip(old, cat(parts), block: [64, 256, 4096][t % 3]);
      }
    });
  });

  group('refusals', () {
    late File old;
    late Uint8List oldBytes, newBytes;
    late String patch;

    setUp(() async {
      oldBytes = noise(r, 300000);
      newBytes = cat([oldBytes.sublist(0, 100000), noise(r, 50000), oldBytes.sublist(100000)]);
      old = write('o', oldBytes);
      write('n', newBytes);
      patch = p.join(tmp.path, 'p');
      await makeDelta(oldPath: old.path, newPath: p.join(tmp.path, 'n'), outPath: patch);
    });

    Future<void> expectRefused(String oldPath, String patchPath, {String? oldSha, String? newSha}) async {
      final out = p.join(tmp.path, 'out');
      await expectLater(applyDelta(oldPath: oldPath, patchPath: patchPath, outPath: out, expectOldSha256: oldSha, expectNewSha256: newSha), throwsA(isA<DeltaException>()));
      expect(File(out).existsSync(), isFalse, reason: 'a failed apply leaves no output');
    }

    test('the good patch applies (control)', () async {
      final out = p.join(tmp.path, 'out');
      await applyDelta(oldPath: old.path, patchPath: patch, outPath: out);
      expect(File(out).readAsBytesSync(), newBytes);
    });

    test('a flipped byte inside the compressed ops', () async {
      final b = File(patch).readAsBytesSync();
      for (final at in [deltaHeaderSize + 30, b.length ~/ 2, b.length - 20]) {
        final bad = Uint8List.fromList(b);
        bad[at] ^= 0x40;
        await expectRefused(old.path, write('bad', bad).path);
      }
    });

    test('a cut patch', () async {
      final b = File(patch).readAsBytesSync();
      await expectRefused(old.path, write('cut', b.sublist(0, b.length - 100)).path);
      await expectRefused(old.path, write('cut2', b.sublist(0, deltaHeaderSize + 10)).path);
      await expectRefused(old.path, write('cut3', b.sublist(0, 40)).path);
      await expectRefused(old.path, write('cut4', b.sublist(0, deltaHeaderSize)).path);
    });

    test('not a patch / unknown version / garbage after the end', () async {
      await expectRefused(old.path, write('junk', noise(r, 1000)).path);
      final b = Uint8List.fromList(File(patch).readAsBytesSync());
      b[4] = 99;
      await expectRefused(old.path, write('v99', b).path);
      // valid gzip, but the ops claim more than the header
      await expectRefused(old.path, write('tail', cat([File(patch).readAsBytesSync(), [1, 2, 3]])).path);
    });

    test('the header lies about the result (hash)', () async {
      final b = Uint8List.fromList(File(patch).readAsBytesSync());
      b[60] ^= 1; // inside newSha256
      await expectRefused(old.path, write('lie', b).path);
    });

    test('another base file: other size, or the same size with other content', () async {
      await expectRefused(write('o2', oldBytes.sublist(0, 299999)).path, patch);
      final same = Uint8List.fromList(oldBytes);
      same[150000] ^= 1;
      await expectRefused(write('o3', same).path, patch);
      final out = p.join(tmp.path, 'out');
      // the hash the caller expects for the base is checked from the header before any work
      await expectLater(applyDelta(oldPath: old.path, patchPath: patch, outPath: out, expectOldSha256: sha256.convert(same).toString()), throwsA(isA<DeltaException>()));
      await expectLater(applyDelta(oldPath: old.path, patchPath: patch, outPath: out, expectNewSha256: sha256.convert(same).toString()), throwsA(isA<DeltaException>()));
    });

    test('the base file is missing: a file error, not a damaged patch', () async {
      await expectLater(applyDelta(oldPath: p.join(tmp.path, 'nope'), patchPath: patch, outPath: p.join(tmp.path, 'out')), throwsA(isA<FileSystemException>()));
    });
  });

  test('50 MB: streams, bounded memory, patch is the changed part', () async {
    final rr = Random(3);
    final old = File(p.join(tmp.path, 'big_old'));
    final neu = File(p.join(tmp.path, 'big_new'));
    final so = old.openWrite(), sn = neu.openWrite();
    final chunk = noise(rr, 1 << 20);
    for (var i = 0; i < 50; i++) {
      final c = Uint8List.fromList(chunk)..[0] = i; // 50 different MB, none repeated
      so.add(c);
      if (i == 20) {
        sn.add(noise(rr, 3 << 20)); // 3 MB changed in the middle, the rest shifted by 3 MB
      }
      sn.add(c);
    }
    await so.close();
    await sn.close();
    final patch = p.join(tmp.path, 'big_patch'), out = p.join(tmp.path, 'big_out');
    final before = ProcessInfo.currentRss;
    final stats = await makeDelta(oldPath: old.path, newPath: neu.path, outPath: patch);
    expect(stats.literalBytes, lessThan((3 << 20) + 20 * 4096));
    expect(stats.patchSize, lessThan((3 << 20) + 200000));
    await applyDelta(oldPath: old.path, patchPath: patch, outPath: out, expectOldSha256: stats.oldSha256, expectNewSha256: stats.newSha256);
    expect((await sha256.bind(File(out).openRead()).first).toString(), stats.newSha256);
    expect(File(out).lengthSync(), neu.lengthSync());
    // never the whole files in memory (they are 50 MB each): the high-water mark of the process
    // stays far below what holding them would take
    expect(ProcessInfo.maxRss - before, lessThan(60 << 20));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
