import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'appupdate.dart';

// The publisher's half of the update feed (docs/updates.md -> "Публикация"): keys, the
// manifest, its signature. Used by tool/release_keys.dart and tool/release_manifest.dart,
// not exported by the package barrel: the app only verifies.

class ReleaseKeys {
  ReleaseKeys(this.seed, this.publicKey);

  /// The private key: 32 bytes. Whoever has it can ship code to every user.
  final Uint8List seed;
  final Uint8List publicKey;

  String get seedBase64 => base64.encode(seed);
  String get publicBase64 => base64.encode(publicKey);
}

Future<ReleaseKeys> keysFromSeed(List<int> seed) async {
  if (seed.length != 32) throw ArgumentError('An Ed25519 seed is 32 bytes, got ${seed.length}');
  final pub = await (await Ed25519().newKeyPairFromSeed(seed)).extractPublicKey();
  return ReleaseKeys(Uint8List.fromList(seed), Uint8List.fromList(pub.bytes));
}

Future<ReleaseKeys> generateReleaseKeys() {
  final r = Random.secure();
  return keysFromSeed(Uint8List.fromList([for (var i = 0; i < 32; i++) r.nextInt(256)]));
}

/// The signature (64 bytes) of [message] by the key with [seed].
Future<Uint8List> signEd25519(List<int> message, List<int> seed) async {
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  return Uint8List.fromList((await Ed25519().sign(message, keyPair: kp)).bytes);
}

/// Reads a private key file written by `release_keys.dart` (base64 of the seed).
Uint8List readSeedFile(File f) {
  final raw = f.readAsStringSync().trim();
  try {
    final seed = base64.decode(raw);
    if (seed.length == 32) return Uint8List.fromList(seed);
  } on FormatException {
    // falls through
  }
  throw FormatException('${f.path} is not a release key file (base64 of 32 bytes)');
}

/// A file as the manifest describes it. [urlBases]: where it will be uploaded; each gives
/// `<base>/<file name>` in `urls` (none: relative, the feeds are asked for it).
Future<UpdateAsset> assetFromFile(String platform, File f, {List<String> urlBases = const [], String? kind, List<UpdateDelta> deltas = const []}) async {
  if (!updatePlatformIds.contains(platform)) throw ArgumentError('Unknown platform "$platform" (${updatePlatformIds.join(', ')})');
  final name = p.basename(f.path);
  final hash = (await sha256.bind(f.openRead()).first).toString();
  final ext = p.extension(name).toLowerCase();
  return UpdateAsset(
    platform: platform,
    file: name,
    size: f.lengthSync(),
    sha256: hash,
    urls: [for (final b in urlBases) '${b.endsWith('/') ? b : '$b/'}$name'],
    kind: kind ?? (ext == '.apk' ? 'apk' : ext == '.zip' ? 'zip' : ext == '.exe' || ext == '.msi' ? 'installer' : null),
    deltas: deltas,
  );
}

/// A patch file ([makeDelta]) as the manifest describes it: it applies to the full file whose
/// sha256 is [from]. [urlBases] as in [assetFromFile].
Future<UpdateDelta> deltaFromFile(File f, String from, {List<String> urlBases = const []}) async {
  final name = p.basename(f.path);
  return UpdateDelta(
    from: from.toLowerCase(),
    file: name,
    size: f.lengthSync(),
    sha256: (await sha256.bind(f.openRead()).first).toString(),
    urls: [for (final b in urlBases) '${b.endsWith('/') ? b : '$b/'}$name'],
  );
}

/// The manifest bytes exactly as they are signed and uploaded.
Uint8List manifestBytes(UpdateManifest m) => Uint8List.fromList(utf8.encode('${const JsonEncoder.withIndent('  ').convert(m.toJson())}\n'));

/// Signs [bytes]; the result is the content of `manifest-<channel>.json.sig`.
Future<String> signatureFile(List<int> bytes, List<int> seed) async => '${base64.encode(await signEd25519(bytes, seed))}\n';

/// Is [dir] (or a parent) a git working tree? The release key must not live in one.
bool insideGitTree(String path) {
  var d = Directory(p.dirname(p.absolute(path)));
  while (true) {
    if (Directory(p.join(d.path, '.git')).existsSync() || File(p.join(d.path, '.git')).existsSync()) return true;
    final up = d.parent;
    if (up.path == d.path) return false;
    d = up;
  }
}
