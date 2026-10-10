import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

// The envelope of the support report (docs/logs.md -> Отправка -> Конверт): the gzipped report
// is encrypted on the device with the developers' public key, so the receiving Worker (and
// whoever can read its storage) holds bytes only the private key opens. The device half
// ([encryptReport]) is used by `HttpReportUploader`; the key pair and the opening
// ([generateReportKeys], [decryptReport]) are the developer's half, used by
// tool/report_keys.dart and tool/decrypt_report.dart and by the tests.
//
//   envelope = "JRP1" (4) | ephemeral X25519 public key (32) | nonce (12) | AES-256-GCM(ciphertext || tag(16))
//   key      = HKDF-SHA256(ikm = X25519(ephemeral private, recipient public),
//                          salt = ephemeral public || recipient public, info = "jormungand-report-v1", L = 32)
//   aad      = the 4 magic bytes

/// The first four bytes of an envelope (`JRP1`): format and version in one.
const reportEnvelopeMagic = <int>[0x4A, 0x52, 0x50, 0x31];

const _pubLen = 32;
const _nonceLen = 12;
const _tagLen = 16;

/// What an envelope adds to the gzipped report: magic, ephemeral key, nonce, GCM tag.
const reportEnvelopeOverhead = 4 + _pubLen + _nonceLen + _tagLen;

const _hkdfInfo = 'jormungand-report-v1';

/// An envelope that cannot be made or opened. [message] says why in words a developer can act on.
class ReportCryptoException implements Exception {
  const ReportCryptoException(this.message);

  final String message;

  @override
  String toString() => 'ReportCryptoException: $message';
}

/// The recipient's key pair. [privateKey] is the X25519 private key (32 bytes); whoever has it
/// reads every report. It never goes into the repository.
class ReportKeys {
  ReportKeys(this.privateKey, this.publicKey);

  final Uint8List privateKey;
  final Uint8List publicKey;

  String get privateBase64 => base64.encode(privateKey);
  String get publicBase64 => base64.encode(publicKey);
}

/// The key pair of a private key given as 32 bytes.
Future<ReportKeys> reportKeysFromPrivate(List<int> privateKey) async {
  if (privateKey.length != 32) throw ArgumentError('An X25519 private key is 32 bytes, got ${privateKey.length}');
  final pub = await (await X25519().newKeyPairFromSeed(privateKey)).extractPublicKey();
  return ReportKeys(Uint8List.fromList(privateKey), Uint8List.fromList(pub.bytes));
}

Future<ReportKeys> generateReportKeys() {
  final r = Random.secure();
  return reportKeysFromPrivate(Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]));
}

/// Where the developer's private key lives by default: `<home>/.jormungand/report_private.key`.
String defaultReportKeyPath() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) throw StateError('Neither USERPROFILE nor HOME is set: cannot place the report key');
  return p.join(home, '.jormungand', 'report_private.key');
}

/// Reads a key file written by tool/report_keys.dart (base64 of the 32 private bytes).
Uint8List readReportKeyFile(File f) {
  final String raw;
  try {
    raw = f.readAsStringSync().trim();
  } on FileSystemException catch (e) {
    throw ReportCryptoException('Cannot read the key file ${f.path}: ${e.message}');
  }
  try {
    final key = base64.decode(raw);
    if (key.length == 32) return Uint8List.fromList(key);
  } on FormatException {
    // falls through
  }
  throw ReportCryptoException('${f.path} is not a report key file (base64 of 32 bytes)');
}

SimplePublicKey _pub(List<int> bytes) => SimplePublicKey(bytes, type: KeyPairType.x25519);

Future<SecretKey> _key(SecretKey shared, List<int> ephemeralPub, List<int> recipientPub) => Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, nonce: [...ephemeralPub, ...recipientPub], info: utf8.encode(_hkdfInfo));

/// [gzipped] (the report) as an envelope for the holder of the private key of [recipientPublicKey]
/// (32 bytes). A fresh ephemeral key and nonce every time, so two envelopes of one report differ.
Future<Uint8List> encryptReport(List<int> gzipped, {required List<int> recipientPublicKey}) async {
  if (recipientPublicKey.length != _pubLen) {
    throw ReportCryptoException('The recipient key is ${recipientPublicKey.length} bytes, an X25519 public key is $_pubLen');
  }
  final x = X25519();
  final eph = await x.newKeyPair();
  final ephPub = (await eph.extractPublicKey()).bytes;
  final shared = await x.sharedSecretKey(keyPair: eph, remotePublicKey: _pub(recipientPublicKey));
  final key = await _key(shared, ephPub, recipientPublicKey);
  final aes = AesGcm.with256bits();
  final nonce = aes.newNonce();
  final box = await aes.encrypt(gzipped, secretKey: key, nonce: nonce, aad: reportEnvelopeMagic);
  return (BytesBuilder(copy: false)
        ..add(reportEnvelopeMagic)
        ..add(ephPub)
        ..add(nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .takeBytes();
}

/// The report (JSON map) inside [envelope]: [decryptReport], gunzip, decode. Throws a
/// [ReportCryptoException] also when what opened is not a gzipped JSON object.
Future<Map<String, dynamic>> openReport(List<int> envelope, {required List<int> privateKey}) async {
  final gz = await decryptReport(envelope, privateKey: privateKey);
  try {
    final v = jsonDecode(utf8.decode(gzip.decode(gz)));
    if (v is Map) return v.cast<String, dynamic>();
  } on FormatException {
    // falls through
  }
  throw const ReportCryptoException('The envelope opened, but what is inside is not a gzipped JSON report');
}

/// The gzipped report inside [envelope], opened with [privateKey] (32 bytes). Throws a
/// [ReportCryptoException]: not an envelope (too short, wrong magic), or it does not open (the
/// bytes were changed, or the envelope is for another key).
Future<Uint8List> decryptReport(List<int> envelope, {required List<int> privateKey}) async {
  if (envelope.length < reportEnvelopeOverhead) {
    throw ReportCryptoException('Not a report envelope: ${envelope.length} bytes, the shortest is $reportEnvelopeOverhead');
  }
  for (var i = 0; i < reportEnvelopeMagic.length; i++) {
    if (envelope[i] != reportEnvelopeMagic[i]) {
      throw const ReportCryptoException('Not a report envelope: the magic is not JRP1 (wrong file, or a newer format)');
    }
  }
  if (privateKey.length != 32) throw ReportCryptoException('The private key is ${privateKey.length} bytes, expected 32');
  final ephPub = envelope.sublist(4, 4 + _pubLen);
  final nonce = envelope.sublist(4 + _pubLen, 4 + _pubLen + _nonceLen);
  final body = envelope.sublist(4 + _pubLen + _nonceLen);
  final cipher = body.sublist(0, body.length - _tagLen);
  final tag = body.sublist(body.length - _tagLen);
  final x = X25519();
  final pair = await x.newKeyPairFromSeed(privateKey);
  final recipientPub = (await pair.extractPublicKey()).bytes;
  final shared = await x.sharedSecretKey(keyPair: pair, remotePublicKey: _pub(ephPub));
  final key = await _key(shared, ephPub, recipientPub);
  try {
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
      aad: reportEnvelopeMagic,
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const ReportCryptoException(
        'The envelope does not open: it is for another key or its bytes were changed (authentication failed)');
  }
}
