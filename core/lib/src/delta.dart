import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// Binary delta between two files (docs/updates.md -> "Дельта-обновления"): the generator (CI,
// tool/make_delta.dart) and the applier (the app's updater) live here so both ends agree.
//
// rsync style. The OLD file is cut into fixed blocks (4 KiB), each with a weak rolling hash
// (Adler-like) and a strong one (64 bits of MD5). The NEW file is scanned with a rolling window:
// where a window equals an old block the patch says COPY(oldOffset, len) (neighbouring copies
// are merged, a match is extended backwards over the pending literal and forwards past the last
// block), the rest is LITERAL bytes. Whatever the patch claims, the applier checks the result
// against the sha256 in the header (and the caller against the manifest's), so a collision or a
// corrupt patch can only make the update fall back to the full file.
//
// File: header (raw) + gzip stream of ops.
//   header  "JDLT" | version u8 | oldSize u64 | oldSha256 32 | newSize u64 | newSha256 32  (little endian)
//   op      0x00 END | 0x01 COPY varint(oldOffset) varint(len) | 0x02 LITERAL varint(len) bytes
// Both directions stream: memory is a window buffer (1 MiB) plus the block index of the old file
// (generator) or one decompressed chunk (applier); no file is ever loaded whole.

const _magic = [0x4A, 0x44, 0x4C, 0x54]; // JDLT
const deltaFormatVersion = 1;
const deltaHeaderSize = 4 + 1 + 8 + 32 + 8 + 32;

const _opEnd = 0, _opCopy = 1, _opLiteral = 2;

class DeltaException implements Exception {
  DeltaException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DeltaHeader {
  const DeltaHeader({required this.oldSize, required this.oldSha256, required this.newSize, required this.newSha256});

  final int oldSize;

  /// Lower-case hex of the file the patch is made against.
  final String oldSha256;
  final int newSize;

  /// Lower-case hex of the file the patch produces.
  final String newSha256;

  Uint8List toBytes() {
    final b = Uint8List(deltaHeaderSize);
    final d = ByteData.sublistView(b);
    b.setRange(0, 4, _magic);
    b[4] = deltaFormatVersion;
    d.setUint64(5, oldSize, Endian.little);
    b.setRange(13, 45, _unhex(oldSha256));
    d.setUint64(45, newSize, Endian.little);
    b.setRange(53, 85, _unhex(newSha256));
    return b;
  }

  static DeltaHeader parse(Uint8List b) {
    if (b.length < deltaHeaderSize) throw DeltaException('The patch is too short');
    for (var i = 0; i < 4; i++) {
      if (b[i] != _magic[i]) throw DeltaException('Not a delta patch');
    }
    if (b[4] != deltaFormatVersion) throw DeltaException('Unknown patch format ${b[4]}');
    final d = ByteData.sublistView(b);
    final oldSize = d.getInt64(5, Endian.little), newSize = d.getInt64(45, Endian.little);
    if (oldSize < 0 || newSize < 0) throw DeltaException('Bad sizes in the patch header');
    return DeltaHeader(oldSize: oldSize, oldSha256: _hex(b.sublist(13, 45)), newSize: newSize, newSha256: _hex(b.sublist(53, 85)));
  }
}

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List _unhex(String s) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(s)) throw ArgumentError('not a sha256: $s');
  return Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}

/// Reads the header of a patch file.
Future<DeltaHeader> readDeltaHeader(String patchPath) async {
  final f = await File(patchPath).open();
  try {
    final b = Uint8List(deltaHeaderSize);
    final n = await f.readInto(b);
    if (n < deltaHeaderSize) throw DeltaException('The patch is too short');
    return DeltaHeader.parse(b);
  } finally {
    await f.close();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _HexHasher {
  _HexHasher() : _in = null {
    _in = sha256.startChunkedConversion(_out);
  }
  final _out = _DigestSink();
  ByteConversionSink? _in;

  void add(List<int> data) => _in!.add(data);

  String close() {
    _in!.close();
    return _out.value.toString();
  }
}

/// Writes the compressed stream into the patch file after the header.
class _FileSink implements Sink<List<int>> {
  _FileSink(this.f);
  final RandomAccessFile f;
  int written = 0;
  @override
  void add(List<int> data) {
    f.writeFromSync(data);
    written += data.length;
  }

  @override
  void close() {}
}

// ───────────────────────────── generator ─────────────────────────────

/// What a generated patch is made of.
class DeltaStats {
  const DeltaStats({required this.oldSize, required this.newSize, required this.patchSize, required this.copyBytes, required this.literalBytes, required this.copyOps, required this.literalOps, required this.oldSha256, required this.newSha256});
  final int oldSize, newSize, patchSize;

  /// Bytes of the new file taken from the old one / carried in the patch (before compression).
  final int copyBytes, literalBytes;
  final int copyOps, literalOps;
  final String oldSha256, newSha256;

  @override
  String toString() => 'old $oldSize B, new $newSize B, patch $patchSize B '
      '(copy $copyBytes B in $copyOps ops, literal $literalBytes B in $literalOps ops)';
}

class _OpWriter {
  _OpWriter(this._out);
  final Sink<List<int>> _out;
  int _copyOff = -1, _copyLen = 0;
  int copyBytes = 0, literalBytes = 0, copyOps = 0, literalOps = 0;

  /// Where the pending copy ends in the old file (-1: no pending copy).
  int get copyEnd => _copyOff < 0 ? -1 : _copyOff + _copyLen;

  void _varint(BytesBuilder b, int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7F) | 0x80);
      v >>>= 7;
    }
    b.addByte(v);
  }

  void copy(int off, int len) {
    if (len <= 0) return;
    if (_copyOff >= 0 && _copyOff + _copyLen == off) {
      _copyLen += len; // contiguous with the pending copy: one op
      return;
    }
    flushCopy();
    _copyOff = off;
    _copyLen = len;
  }

  void flushCopy() {
    if (_copyOff < 0) return;
    final b = BytesBuilder(copy: false)..addByte(_opCopy);
    _varint(b, _copyOff);
    _varint(b, _copyLen);
    _out.add(b.takeBytes());
    copyBytes += _copyLen;
    copyOps++;
    _copyOff = -1;
    _copyLen = 0;
  }

  void literal(Uint8List buf, int from, int to) {
    if (to <= from) return;
    flushCopy();
    final b = BytesBuilder(copy: false)..addByte(_opLiteral);
    _varint(b, to - from);
    _out.add(b.takeBytes());
    _out.add(Uint8List.sublistView(buf, from, to));
    literalBytes += to - from;
    literalOps++;
  }

  void end() {
    flushCopy();
    _out.add(Uint8List.fromList([_opEnd]));
  }
}

/// Makes the patch that turns [oldPath] into [newPath], written to [outPath]. [blockSize]: the
/// matching granularity (smaller finds finer changes, costs more index). Memory: the index of the
/// old file (~16 bytes per block) and a 1 MiB window.
Future<DeltaStats> makeDelta({required String oldPath, required String newPath, required String outPath, int blockSize = 4096}) async {
  final oldF = File(oldPath).openSync();
  final newF = File(newPath).openSync();
  final outF = File(outPath).openSync(mode: FileMode.write);
  try {
    final d = _Differ(oldF, newF, outF, blockSize);
    final stats = d.run();
    return stats;
  } catch (_) {
    try {
      outF.closeSync();
      File(outPath).deleteSync();
    } catch (_) {}
    rethrow;
  } finally {
    try {
      oldF.closeSync();
      newF.closeSync();
      outF.closeSync();
    } catch (_) {}
  }
}

class _Differ {
  _Differ(this.oldF, this.newF, this.outF, this.B)
      : buf = Uint8List(B * 256),
        tmp = Uint8List(B) {
    oldSize = oldF.lengthSync();
    newSize = newF.lengthSync();
  }

  final RandomAccessFile oldF, newF, outF;
  final int B;
  final Uint8List buf, tmp;
  late final int oldSize, newSize;

  // block index of the old file
  late Uint32List weakOf;
  late Int64List strongOf;
  late Int32List next;
  final head = <int, int>{};
  final filter = Uint8List(1 << 20);

  static int _slot(int w) => (w ^ (w >>> 13)) & 0xFFFFF;

  static int _weak(Uint8List b, int from, int n) {
    var a = 0, s = 0;
    for (var i = 0; i < n; i++) {
      final x = b[from + i];
      a += x;
      s += (n - i) * x;
    }
    return ((s & 0xFFFF) << 16) | (a & 0xFFFF);
  }

  static int _strong(Uint8List b, int from, int n) {
    final d = md5.convert(Uint8List.sublistView(b, from, from + n)).bytes;
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | d[i];
    }
    return v;
  }

  late final _HexHasher newHash = _HexHasher();
  late final _OpWriter w;
  int end = 0, pos = 0, litStart = 0;
  bool eof = false;

  /// Hashes the old file and builds the block index; returns the file's sha256.
  String _index() {
    final blocks = oldSize ~/ B;
    weakOf = Uint32List(blocks);
    strongOf = Int64List(blocks);
    next = Int32List(blocks);
    final hasher = _HexHasher();
    final chunk = Uint8List(B * 256);
    var block = 0;
    oldF.setPositionSync(0);
    while (true) {
      final n = oldF.readIntoSync(chunk);
      if (n == 0) break;
      hasher.add(Uint8List.sublistView(chunk, 0, n));
      for (var o = 0; o + B <= n; o += B) {
        final wk = _weak(chunk, o, B), st = _strong(chunk, o, B);
        weakOf[block] = wk;
        strongOf[block] = st;
        // identical blocks (zero runs) are indexed once: the first one
        var j = head[wk] ?? -1;
        var dup = false;
        while (j >= 0) {
          if (strongOf[j] == st) {
            dup = true;
            break;
          }
          j = next[j];
        }
        if (!dup) {
          next[block] = head[wk] ?? -1;
          head[wk] = block;
          filter[_slot(wk)] = 1;
        }
        block++;
      }
    }
    return hasher.close();
  }

  void _refill() {
    if (eof) return;
    // the pending literal is written out, except its last block: a match may extend backwards over it
    if (pos - litStart > B) {
      final upto = pos - B;
      w.literal(buf, litStart, upto);
      litStart = upto;
    }
    final shift = litStart;
    if (shift > 0) {
      buf.setRange(0, end - shift, buf, shift);
      end -= shift;
      pos -= shift;
      litStart = 0;
      _extNew -= shift;
    }
    final n = newF.readIntoSync(buf, end);
    if (n == 0) {
      eof = true;
    } else {
      newHash.add(Uint8List.sublistView(buf, end, end + n));
      end += n;
    }
  }

  int _extNew = -1, _extOld = 0;

  /// The old block equal to the window at [pos] (hashes [wk]); -1 = none.
  int _lookup(int wk, int pos) {
    if (filter[_slot(wk)] == 0) return -1;
    final first = head[wk];
    if (first == null) return -1;
    final st = _strong(buf, pos, B);
    // the block right after the previous copy first: it keeps the copies one op
    final ce = w.copyEnd;
    if (ce >= 0 && ce % B == 0) {
      final e = ce ~/ B;
      if (e < weakOf.length && weakOf[e] == wk && strongOf[e] == st) return e;
    }
    var j = first, guard = 64;
    while (j >= 0 && guard-- > 0) {
      if (strongOf[j] == st) return j;
      j = next[j];
    }
    return -1;
  }

  DeltaStats run() {
    final oldSha = _index();
    final header = Uint8List(deltaHeaderSize); // placeholder: the hashes are known at the end
    outF.writeFromSync(header);
    final fileSink = _FileSink(outF);
    final gz = GZipCodec(level: 9).encoder.startChunkedConversion(fileSink);
    w = _OpWriter(gz);
    newF.setPositionSync(0);

    var valid = false, a = 0, b = 0;
    while (true) {
      while (pos + B > end && !eof) {
        _refill();
      }
      if (pos + B > end) break;
      if (!valid) {
        final h = _weak(buf, pos, B);
        a = h & 0xFFFF;
        b = h >>> 16;
        valid = true;
      }
      final j = _lookup((b << 16) | a, pos);
      if (j >= 0) {
        // backwards over the pending literal
        var back = 0;
        final maxBack = math.min(math.min(pos - litStart, j * B), B);
        if (maxBack > 0) {
          oldF.setPositionSync(j * B - maxBack);
          oldF.readIntoSync(tmp, 0, maxBack);
          while (back < maxBack && buf[pos - 1 - back] == tmp[maxBack - 1 - back]) {
            back++;
          }
        }
        w.literal(buf, litStart, pos - back);
        w.copy(j * B - back, B + back);
        pos += B;
        litStart = pos;
        _extNew = pos;
        _extOld = (j + 1) * B;
        valid = false;
        continue;
      }
      // after a copy the bytes that still agree with the old file go on for less than a block
      if (pos == _extNew) {
        _extNew = -1;
        final lim = math.min(math.min(end - pos, oldSize - _extOld), B - 1);
        if (lim > 0) {
          oldF.setPositionSync(_extOld);
          oldF.readIntoSync(tmp, 0, lim);
          var k = 0;
          while (k < lim && buf[pos + k] == tmp[k]) {
            k++;
          }
          if (k > 0) {
            w.copy(_extOld, k);
            pos += k;
            litStart = pos;
            valid = false;
            continue;
          }
        }
      }
      // roll one byte
      while (pos + B + 1 > end && !eof) {
        _refill();
      }
      if (pos + B + 1 > end) break;
      final out = buf[pos], inn = buf[pos + B];
      a = (a - out + inn) & 0xFFFF;
      b = (b - B * out + a) & 0xFFFF;
      pos++;
    }
    // the tail (less than a window, or after the last match) is literal; the file is fully read
    w.literal(buf, litStart, end);
    w.end();
    gz.close();
    final newSha = newHash.close();
    final hdr = DeltaHeader(oldSize: oldSize, oldSha256: oldSha, newSize: newSize, newSha256: newSha);
    outF.setPositionSync(0);
    outF.writeFromSync(hdr.toBytes());
    outF.flushSync();
    return DeltaStats(
      oldSize: oldSize,
      newSize: newSize,
      patchSize: deltaHeaderSize + fileSink.written,
      copyBytes: w.copyBytes,
      literalBytes: w.literalBytes,
      copyOps: w.copyOps,
      literalOps: w.literalOps,
      oldSha256: oldSha,
      newSha256: newSha,
    );
  }
}

// ───────────────────────────── applier ─────────────────────────────

class _Reader {
  _Reader(Stream<List<int>> s) : _it = StreamIterator(s);
  final StreamIterator<List<int>> _it;
  List<int> _cur = const [];
  int _pos = 0;

  Future<bool> _more() async {
    while (_pos >= _cur.length) {
      if (!await _it.moveNext()) return false;
      _cur = _it.current;
      _pos = 0;
    }
    return true;
  }

  Future<int> byte() async {
    if (!await _more()) throw DeltaException('The patch is cut short');
    return _cur[_pos++];
  }

  Future<int> varint() async {
    var v = 0, shift = 0;
    while (true) {
      final x = await byte();
      v |= (x & 0x7F) << shift;
      if (x < 0x80) return v;
      shift += 7;
      if (shift > 56) throw DeltaException('Bad number in the patch');
    }
  }

  /// Up to [max] bytes of what is buffered (at least one).
  Future<Uint8List> take(int max) async {
    if (!await _more()) throw DeltaException('The patch is cut short');
    final n = math.min(max, _cur.length - _pos);
    final c = _cur;
    final out = c is Uint8List ? Uint8List.sublistView(c, _pos, _pos + n) : Uint8List.fromList(c.sublist(_pos, _pos + n));
    _pos += n;
    return out;
  }

  /// Nothing left after the END op.
  Future<bool> atEnd() async {
    while (true) {
      if (_pos < _cur.length) return false;
      if (!await _it.moveNext()) return true;
      _cur = _it.current;
      _pos = 0;
    }
  }

  Future<void> close() => _it.cancel();
}

/// Applies [patchPath] to [oldPath], writing [outPath]. Throws [DeltaException] when the patch is
/// not for this file / is damaged / does not give the announced result; [outPath] is deleted then.
/// [expectOldSha256] / [expectNewSha256] (hex) must equal the patch header's (the caller knows the
/// base's hash and the target's from the signed manifest); the produced file is hashed as it is
/// written and must equal the header's. Memory is bounded: one decompressed chunk and a 64 KiB
/// copy buffer.
Future<DeltaHeader> applyDelta({required String oldPath, required String patchPath, required String outPath, String? expectOldSha256, String? expectNewSha256}) async {
  final header = await readDeltaHeader(patchPath);
  if (expectOldSha256 != null && header.oldSha256 != expectOldSha256) throw DeltaException('The patch is made for another base file');
  if (expectNewSha256 != null && header.newSha256 != expectNewSha256) throw DeltaException('The patch does not produce the announced file');
  final oldF = await File(oldPath).open();
  RandomAccessFile? outF;
  _Reader? rd;
  var ok = false;
  try {
    if (await oldF.length() != header.oldSize) throw DeltaException('The base file has another size than the patch expects');
    outF = await File(outPath).open(mode: FileMode.write);
    final hasher = _HexHasher();
    rd = _Reader(gzip.decoder.bind(File(patchPath).openRead(deltaHeaderSize)));
    final chunk = Uint8List(64 * 1024);
    var written = 0;
    try {
      ops:
      while (true) {
        switch (await rd.byte()) {
          case _opEnd:
            break ops;
          case _opCopy:
            var off = await rd.varint();
            var len = await rd.varint();
            if (len <= 0 || off < 0 || off + len > header.oldSize || written + len > header.newSize) throw DeltaException('Bad copy in the patch');
            while (len > 0) {
              final n = math.min(len, chunk.length);
              await oldF.setPosition(off);
              if (await oldF.readInto(chunk, 0, n) != n) throw DeltaException('The base file is shorter than expected');
              hasher.add(Uint8List.sublistView(chunk, 0, n));
              await outF.writeFrom(chunk, 0, n);
              off += n;
              len -= n;
              written += n;
            }
          case _opLiteral:
            var len = await rd.varint();
            if (len <= 0 || written + len > header.newSize) throw DeltaException('Bad literal in the patch');
            while (len > 0) {
              final part = await rd.take(len);
              hasher.add(part);
              await outF.writeFrom(part);
              len -= part.length;
              written += part.length;
            }
          default:
            throw DeltaException('Unknown op in the patch');
        }
      }
      if (!await rd.atEnd()) throw DeltaException('Unexpected data after the end of the patch');
    } on DeltaException {
      rethrow;
    } on FileSystemException catch (e) {
      // the patch file or the output failing is not a damaged patch, but the gzip stream's errors are
      if (e.path == patchPath || e.path == outPath || e.path == oldPath) rethrow;
      throw DeltaException('The patch is damaged: ${e.message}');
    } catch (e) {
      throw DeltaException('The patch is damaged: $e');
    }
    if (written != header.newSize) throw DeltaException('The result is $written bytes, ${header.newSize} expected');
    await outF.flush();
    if (hasher.close() != header.newSha256) throw DeltaException('The result does not match its sha256 (wrong base file?)');
    ok = true;
    return header;
  } finally {
    await rd?.close().catchError((_) {});
    await oldF.close();
    await outF?.close();
    if (!ok) {
      try {
        final o = File(outPath);
        if (o.existsSync()) o.deleteSync();
      } catch (_) {}
    }
  }
}
