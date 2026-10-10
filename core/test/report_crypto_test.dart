// The report envelope (report_crypto.dart, docs/logs.md → Отправка → Конверт): the layout as
// written, the round trip with a throw-away key pair, what must fail and how, and the two developer
// tools (tool/report_keys.dart, tool/decrypt_report.dart) run for real against a temporary home.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/report_crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List _gz(Map<String, dynamic> report) => Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(report))));

const _report = <String, dynamic>{
  'format': 1,
  'createdAt': '2026-10-10T10:00:00.000Z',
  'app': {'version': '0.9.0', 'platform': 'android'},
  'note': 'телеграм не грузится',
};

Future<void> _rejects(Future<Object?> f, Matcher message) async {
  await expectLater(f, throwsA(isA<ReportCryptoException>().having((e) => e.message, 'message', message)));
}

void main() {
  late ReportKeys keys;

  setUpAll(() async => keys = await generateReportKeys());

  group('envelope', () {
    test('layout: JRP1 | ephemeral public key | nonce | ciphertext+tag, overhead 64', () async {
      final gz = _gz(_report);
      final env = await encryptReport(gz, recipientPublicKey: keys.publicKey);
      expect(env.sublist(0, 4), utf8.encode('JRP1'));
      expect(env.length, gz.length + 4 + 32 + 12 + 16);
      expect(env.length, gz.length + reportEnvelopeOverhead);
      expect(env.sublist(4, 36), isNot(keys.publicKey), reason: 'the key in the envelope is the ephemeral one');
    });

    test('follows the written spec: X25519 -> HKDF-SHA256(salt = eph || recipient, info) -> AES-256-GCM, aad = magic', () async {
      final gz = _gz(_report);
      final env = await encryptReport(gz, recipientPublicKey: keys.publicKey);
      final eph = env.sublist(4, 36);
      final nonce = env.sublist(36, 48);
      final shared = await X25519().sharedSecretKey(
        keyPair: await X25519().newKeyPairFromSeed(keys.privateKey),
        remotePublicKey: SimplePublicKey(eph, type: KeyPairType.x25519),
      );
      // HKDF by hand (RFC 5869, one block) with package:crypto, independent of the code under test
      final prk = c.Hmac(c.sha256, [...eph, ...keys.publicKey]).convert(await shared.extractBytes()).bytes;
      final okm = c.Hmac(c.sha256, prk).convert([...utf8.encode('jormungand-report-v1'), 1]).bytes;
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(env.sublist(48, env.length - 16), nonce: nonce, mac: Mac(env.sublist(env.length - 16))),
        secretKey: SecretKey(okm),
        aad: [0x4A, 0x52, 0x50, 0x31],
      );
      expect(clear, gz);
    });

    test('round trip with a throw-away key pair; every envelope of one report is different', () async {
      final gz = _gz(_report);
      final a = await encryptReport(gz, recipientPublicKey: keys.publicKey);
      final b = await encryptReport(gz, recipientPublicKey: keys.publicKey);
      expect(a, isNot(b));
      expect(await decryptReport(a, privateKey: keys.privateKey), gz);
      expect(await decryptReport(b, privateKey: keys.privateKey), gz);
      expect(await openReport(a, privateKey: keys.privateKey), _report);
    });

    test('a big report and an empty one', () async {
      final big = Uint8List.fromList(List.generate(300000, (i) => (i * 31) & 0xff));
      expect(await decryptReport(await encryptReport(big, recipientPublicKey: keys.publicKey), privateKey: keys.privateKey), big);
      expect(await decryptReport(await encryptReport(const [], recipientPublicKey: keys.publicKey), privateKey: keys.privateKey), isEmpty);
    });

    test('the key pair: the public key follows from the private one', () async {
      final again = await reportKeysFromPrivate(keys.privateKey);
      expect(again.publicKey, keys.publicKey);
      expect(base64.decode(keys.publicBase64), hasLength(32));
      expect(base64.decode(keys.privateBase64), hasLength(32));
      expect(keys.publicKey, isNot(keys.privateKey));
    });

    test('the key built into the app is a 32-byte base64 X25519 public key', () {
      expect(base64.decode(reportPublicKey), hasLength(32));
    });
  });

  group('what must fail', () {
    late Uint8List env;
    setUp(() async => env = await encryptReport(_gz(_report), recipientPublicKey: keys.publicKey));

    test('another private key', () async {
      final other = await generateReportKeys();
      await _rejects(decryptReport(env, privateKey: other.privateKey), contains('another key'));
    });

    test('a changed byte anywhere after the magic: ephemeral key, nonce, ciphertext, tag', () async {
      for (final i in [4, 20, 35, 36, 47, 48, 60, env.length - 17, env.length - 16, env.length - 1]) {
        final bad = Uint8List.fromList(env)..[i] ^= 0x01;
        await _rejects(decryptReport(bad, privateKey: keys.privateKey), contains('authentication failed'));
      }
    });

    test('wrong magic', () async {
      final bad = Uint8List.fromList(env)..[3] = 0x32; // JRP2
      await _rejects(decryptReport(bad, privateKey: keys.privateKey), contains('magic'));
      await _rejects(decryptReport(utf8.encode('{"not":"an envelope, just a long enough text to pass the length"}'), privateKey: keys.privateKey),
          contains('magic'));
    });

    test('too short, truncated', () async {
      await _rejects(decryptReport(env.sublist(0, 20), privateKey: keys.privateKey), contains('Not a report envelope'));
      await _rejects(decryptReport(env.sublist(0, env.length - 1), privateKey: keys.privateKey), contains('authentication failed'));
      await _rejects(decryptReport(const [], privateKey: keys.privateKey), contains('Not a report envelope'));
    });

    test('a key of the wrong size', () async {
      await _rejects(decryptReport(env, privateKey: const [1, 2, 3]), contains('expected 32'));
      await _rejects(encryptReport(const [1], recipientPublicKey: const [1, 2, 3]), contains('X25519 public key'));
    });

    test('opened, but not a gzipped JSON report', () async {
      final notGzip = await encryptReport(utf8.encode('hello'), recipientPublicKey: keys.publicKey);
      await _rejects(openReport(notGzip, privateKey: keys.privateKey), contains('not a gzipped JSON'));
      final list = await encryptReport(gzip.encode(utf8.encode('[1,2]')), recipientPublicKey: keys.publicKey);
      await _rejects(openReport(list, privateKey: keys.privateKey), contains('not a gzipped JSON'));
    });
  });

  group('key file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('jorm-rkey'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reads base64 of 32 bytes, with a newline; refuses anything else', () {
      final ok = File(p.join(tmp.path, 'k'))..writeAsStringSync('${keys.privateBase64}\n');
      expect(readReportKeyFile(ok), keys.privateKey);
      final bad = File(p.join(tmp.path, 'bad'))..writeAsStringSync('not a key');
      expect(() => readReportKeyFile(bad), throwsA(isA<ReportCryptoException>()));
      final short = File(p.join(tmp.path, 'short'))..writeAsStringSync(base64.encode([1, 2, 3]));
      expect(() => readReportKeyFile(short), throwsA(isA<ReportCryptoException>()));
      expect(() => readReportKeyFile(File(p.join(tmp.path, 'missing'))), throwsA(isA<ReportCryptoException>()));
    });
  });

  group('tools', () {
    late Directory home;
    late Map<String, String> env;

    setUp(() {
      home = Directory.systemTemp.createTempSync('jorm-rhome');
      env = {'USERPROFILE': home.path, 'HOME': home.path};
    });
    tearDown(() => home.deleteSync(recursive: true));

    Future<ProcessResult> dartRun(List<String> args) =>
        Process.run(Platform.resolvedExecutable, ['run', ...args],
            environment: env, workingDirectory: Directory.current.path, stdoutEncoding: utf8, stderrEncoding: utf8);

    test('report_keys writes the private key under the home, prints only the public one, refuses to overwrite; decrypt_report opens an envelope',
        () async {
      final r = await dartRun(['tool/report_keys.dart']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final keyFile = File(p.join(home.path, '.jormungand', 'report_private.key'));
      expect(keyFile.existsSync(), isTrue);
      final priv = readReportKeyFile(keyFile);
      final out = '${r.stdout}';
      expect(out, contains(keyFile.path));
      expect(out, isNot(contains(base64.encode(priv))), reason: 'the private key is never printed');
      final pub = RegExp(r"reportPublicKey = '([^']+)'").firstMatch(out)!.group(1)!;
      expect((await reportKeysFromPrivate(priv)).publicBase64, pub);

      final second = await dartRun(['tool/report_keys.dart']);
      expect(second.exitCode, isNot(0));
      expect('${second.stderr}', contains('Refusing to overwrite'));
      expect(readReportKeyFile(keyFile), priv, reason: 'the file is untouched');

      // an envelope made with the printed public key is opened by the tool: JSON and text
      final envFile = File(p.join(home.path, 'r.bin'))
        ..writeAsBytesSync(await encryptReport(_gz({..._report, 'events': <Object>[], 'raw': <Object>[]}), recipientPublicKey: base64.decode(pub)));
      final json = File(p.join(home.path, 'r.json'));
      final d = await dartRun(['tool/decrypt_report.dart', envFile.path, '--out', json.path]);
      expect(d.exitCode, 0, reason: '${d.stderr}');
      expect((jsonDecode(json.readAsStringSync()) as Map)['note'], 'телеграм не грузится');
      expect(json.readAsStringSync(), contains('\n  "format": 1'), reason: 'pretty');

      final t = await dartRun(['tool/decrypt_report.dart', envFile.path, '--text', '--key', keyFile.path]);
      expect(t.exitCode, 0, reason: '${t.stderr}');
      expect('${t.stdout}', contains('телеграм не грузится'));

      // a changed envelope: a clear error, a non-zero exit, nothing written
      final bytes = envFile.readAsBytesSync()..[60] ^= 1;
      final badFile = File(p.join(home.path, 'bad.bin'))..writeAsBytesSync(bytes);
      final bad = await dartRun(['tool/decrypt_report.dart', badFile.path, '--out', p.join(home.path, 'bad.json')]);
      expect(bad.exitCode, isNot(0));
      expect('${bad.stderr}', contains('authentication failed'));
      expect(File(p.join(home.path, 'bad.json')).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
