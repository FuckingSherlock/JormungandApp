// Builds and signs a release manifest (docs/updates.md -> "Публикация").
//
//   dart run tool/release_manifest.dart --key <private-key-file> --version 0.2.0 --build 12 \
//     --channel stable --out dist/ \
//     --asset android-arm64-v8a=build/app-arm64-v8a-release.apk \
//     --asset windows-x64=build/jormungand-0.2.0-setup.exe \
//     [--asset ...] [--min-supported 0.1.5] [--notes-en notes.en.txt] [--notes-ru notes.ru.txt] \
//     [--url-base https://host/path/v0.2.0] [--page https://...] [--signer-sha256 <hex>] [--kind <apk|installer|zip>] \
//     [--delta <platform>=<patch file>,<sha256 of the full file it applies to>]...
//
// --delta (repeatable): a patch made by tool/make_delta.dart; listed in that platform's asset
// (`deltas`), its urls get the same --url-base rules as the asset's.
//
// --asset: <platform>=<file> (platforms: android-arm64-v8a, android-armeabi-v7a, android-x86_64,
// windows-x64). --url-base (repeatable): where the files will be uploaded; each gives
// `<base>/<file>` in the asset's `urls`. No --url-base: the files are looked for under every
// feed. --signer-sha256 (repeatable): SHA-256 of the Android signing certificate.
//
// Writes <out>/manifest-<channel>.json and .json.sig, then verifies its own signature with
// the public key of the key file. Uploading is by hand (or CI later): the files named in the
// output go to the feeds, the installers to the places in `urls`.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/appupdate_release.dart';
import 'package:path/path.dart' as p;

Never _die(String msg, [int code = 64]) {
  stderr.writeln(msg);
  exit(code);
}

Future<void> main(List<String> args) async {
  final one = <String, String>{};
  final many = <String, List<String>>{};
  const multi = {'--asset', '--url-base', '--signer-sha256', '--delta'};
  const single = {'--key', '--version', '--build', '--channel', '--out', '--min-supported', '--notes-en', '--notes-ru', '--page', '--kind'};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!multi.contains(a) && !single.contains(a)) _die('Unknown argument: $a (see the header of tool/release_manifest.dart)');
    if (i + 1 >= args.length) _die('$a needs a value');
    final v = args[++i];
    if (multi.contains(a)) {
      (many[a] ??= []).add(v);
    } else {
      one[a] = v;
    }
  }
  for (final r in ['--key', '--version', '--build', '--out']) {
    if (!one.containsKey(r)) _die('$r is required');
  }
  if (many['--asset'] == null) _die('At least one --asset <platform>=<file> is required');

  final channel = one['--channel'] ?? 'stable';
  if (channel != 'stable' && channel != 'beta') _die('--channel is stable or beta');
  final build = int.tryParse(one['--build']!);
  if (build == null || build < 1) _die('--build is a positive integer (Android versionCode)');
  final AppVersion version;
  AppVersion? min;
  try {
    version = AppVersion.parse(one['--version']!, build: build);
    if (one['--version']!.contains('+')) _die('--version has no +build part: --build is its own field');
    if (one['--min-supported'] != null) min = AppVersion.parse(one['--min-supported']!);
  } on FormatException catch (e) {
    _die(e.message);
  }
  final keyFile = File(one['--key']!);
  if (!keyFile.existsSync()) _die('Key file not found: ${keyFile.path}');
  if (insideGitTree(keyFile.path)) _die('Refusing: the key file is inside a git working tree', 1);
  final seed = readSeedFile(keyFile);
  final keys = await keysFromSeed(seed);

  final notes = <String, String>{};
  for (final (flag, lang) in [('--notes-en', 'en'), ('--notes-ru', 'ru')]) {
    final f = one[flag];
    if (f != null) notes[lang] = File(f).readAsStringSync().trim();
  }

  // --delta <platform>=<patch file>,<sha256 of the full file it applies to>
  final deltas = <String, List<UpdateDelta>>{};
  for (final spec in many['--delta'] ?? const <String>[]) {
    final eq = spec.indexOf('='), comma = spec.lastIndexOf(',');
    if (eq < 0 || comma < eq) _die('--delta $spec: expected <platform>=<patch file>,<from sha256>');
    final platform = spec.substring(0, eq), file = File(spec.substring(eq + 1, comma)), from = spec.substring(comma + 1).trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(from)) _die('--delta $spec: the part after the comma is not a sha256');
    if (!file.existsSync()) _die('Delta file not found: ${file.path}');
    (deltas[platform] ??= []).add(await deltaFromFile(file, from, urlBases: many['--url-base'] ?? const []));
  }
  final assets = <String, UpdateAsset>{};
  for (final spec in many['--asset']!) {
    final eq = spec.indexOf('=');
    if (eq < 0) _die('--asset $spec: expected <platform>=<file>');
    final platform = spec.substring(0, eq), file = File(spec.substring(eq + 1));
    if (!file.existsSync()) _die('Asset file not found: ${file.path}');
    if (assets.containsKey(platform)) _die('Two assets for $platform');
    assets[platform] = await assetFromFile(platform, file, urlBases: many['--url-base'] ?? const [], kind: one['--kind'], deltas: deltas[platform] ?? const []);
  }
  for (final platform in deltas.keys) {
    if (!assets.containsKey(platform)) _die('--delta for $platform, which has no --asset');
  }

  final m = UpdateManifest(
    channel: UpdateChannel.of(channel),
    version: version,
    minSupported: min,
    publishedAt: DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000, isUtc: true),
    page: one['--page'],
    notes: notes,
    androidSigners: [for (final s in many['--signer-sha256'] ?? const <String>[]) s.toLowerCase()],
    assets: assets,
  );
  final bytes = manifestBytes(m);
  // the same checks the app does, on exactly the bytes that will be uploaded
  try {
    UpdateManifest.parse(bytes, expectChannel: m.channel);
  } on UpdateException catch (e) {
    _die('The manifest would be refused by the app: ${e.message}', 1);
  }
  final sig = await signatureFile(bytes, seed);
  if (!await verifyManifestSignature(bytes, sig, [keys.publicBase64])) _die('Self-check of the signature failed', 1);

  final out = Directory(one['--out']!)..createSync(recursive: true);
  final name = 'manifest-$channel.json';
  File(p.join(out.path, name)).writeAsBytesSync(bytes, flush: true);
  File(p.join(out.path, '$name.sig')).writeAsStringSync(sig, flush: true);
  stdout.writeln('Signed ${version.semver}+$build ($channel) with key ${keys.publicBase64}');
  stdout.writeln('  ${p.join(out.path, name)}');
  stdout.writeln('  ${p.join(out.path, '$name.sig')}');
  stdout.writeln('Upload both to every feed, and the installers:');
  for (final a in assets.values) {
    stdout.writeln('  ${a.platform}: ${a.file} (${a.size} bytes, sha256 ${a.sha256.substring(0, 12)}…)${a.urls.isEmpty ? '' : ' -> ${a.urls.join(', ')}'}');
    for (final d in a.deltas) {
      stdout.writeln('    delta from ${d.from.substring(0, 12)}…: ${d.file} (${d.size} bytes)${d.urls.isEmpty ? '' : ' -> ${d.urls.join(', ')}'}');
    }
  }
  if (!utf8.decode(bytes).contains('"urls"')) stdout.writeln('No --url-base: the installers must sit next to the manifest on each feed.');
}
