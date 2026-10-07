import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'delta.dart';
import 'durable.dart';

// The app's self-update, platform-free half (docs/updates.md): the signed manifest, the
// feeds with direct -> tunnel fallback, the version rules, the download with size and
// sha256 checks. Installing (PackageInstaller on Android, the updater on Windows) is the
// platform side and is not here.

/// Ed25519 public keys of the release signature, base64 (32 bytes each). A manifest is
/// accepted when its signature verifies with any of them (more than one only while a key is
/// being replaced, docs/updates.md -> "Смена ключа").
///
/// Key generated 2026-10-03; the private half: the publisher's machine
/// (%USERPROFILE%\.jormungand\release-signing.key), GitHub Actions secret JORM_RELEASE_KEY,
/// backup in secrets-mcp (docs/updates.md -> "Ключ").
const releasePublicKeys = <String>['wNAvpxCr+EQCOFnwSmZtzkPgxLNc4akDBzFhhFBNRo4='];

/// Where the manifests live, in the order tried (docs/updates.md -> "Ленты"). Each is a URL
/// prefix: `<feed>/manifest-<channel>.json` and `.json.sig` are under it.
///
/// The public releases repo (the main repo is private): a release with the fixed tag `feed`
/// holds the manifests; installers sit in the `v…` releases. More feeds (Cloudflare R2…) later.
const releaseFeeds = <String>['https://github.com/FuckingSherlock/jormungand-releases/releases/download/feed'];

const manifestSchema = 1;
const manifestApp = 'jormungand';

/// A manifest is a few KB; anything bigger is not ours.
const maxManifestBytes = 256 * 1024;

/// An installer bigger than this is refused (an APK is ~50-100 MB).
const maxAssetBytes = 600 * 1024 * 1024;

/// The platforms a manifest has assets for.
const updatePlatformIds = [
  'android-arm64-v8a',
  'android-armeabi-v7a',
  'android-x86_64',
  'windows-x64',
];

/// The asset keys for this device, best first: Android's ABIs as the system lists them
/// (`Build.SUPPORTED_ABIS`), Windows is x64 (arm64 Windows runs it emulated).
List<String> updatePlatforms({required String os, List<String> abis = const []}) {
  if (os == 'android') {
    return [for (final a in abis) if (updatePlatformIds.contains('android-$a')) 'android-$a'];
  }
  if (os == 'windows') return ['windows-x64'];
  return const [];
}

// ───────────────────────────── versions ─────────────────────────────

/// `major.minor.patch[-pre][+build]`. Order: semver precedence (a pre-release is below its
/// release: `0.3.0-beta.2` < `0.3.0`), then [build] (the Android versionCode / a CI counter)
/// between equal semver. Build metadata is NOT ignored here, unlike semver.org: two
/// builds of one version are different installs.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, {this.pre = const [], this.build = 0});

  final int major, minor, patch;
  final List<String> pre;
  final int build;

  static final _re = RegExp(r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*))?(?:\+(\d+))?$');

  /// [build] is used when [s] has no `+build` part. Throws a [FormatException].
  factory AppVersion.parse(String s, {int? build}) {
    final m = _re.firstMatch(s.trim());
    if (m == null) throw FormatException('Not a version: "$s"');
    final ids = m.group(4)?.split('.') ?? const <String>[];
    for (final i in ids) {
      if (RegExp(r'^\d+$').hasMatch(i) && i.length > 1 && i.startsWith('0')) throw FormatException('Not a version: "$s"');
    }
    return AppVersion(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!),
        pre: ids, build: m.group(5) != null ? int.parse(m.group(5)!) : (build ?? 0));
  }

  static AppVersion? tryParse(String s, {int? build}) {
    try {
      return AppVersion.parse(s, build: build);
    } on FormatException {
      return null;
    }
  }

  bool get isPrerelease => pre.isNotEmpty;

  /// Same version with another build.
  AppVersion withBuild(int b) => AppVersion(major, minor, patch, pre: pre, build: b);

  @override
  int compareTo(AppVersion o) {
    for (final c in [major.compareTo(o.major), minor.compareTo(o.minor), patch.compareTo(o.patch)]) {
      if (c != 0) return c;
    }
    final c = _comparePre(pre, o.pre);
    return c != 0 ? c : build.compareTo(o.build);
  }

  static int _comparePre(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? 1 : -1);
    for (var i = 0; i < a.length && i < b.length; i++) {
      final x = int.tryParse(a[i]), y = int.tryParse(b[i]);
      final c = x != null && y != null
          ? x.compareTo(y)
          : x != null
              ? -1 // numeric identifiers are below alphanumeric ones
              : y != null
                  ? 1
                  : a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }

  bool operator <(AppVersion o) => compareTo(o) < 0;
  bool operator >(AppVersion o) => compareTo(o) > 0;
  bool operator >=(AppVersion o) => compareTo(o) >= 0;
  bool operator <=(AppVersion o) => compareTo(o) <= 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre.join('.'), build);

  /// The semver part, no build.
  String get semver => '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';

  @override
  String toString() => build > 0 ? '$semver+$build' : semver;
}

// ───────────────────────────── errors ─────────────────────────────

enum UpdateError {
  /// No public key is compiled in ([releasePublicKeys] is empty).
  noKey,

  /// Not one feed answered (or none is configured).
  network,

  /// The signature does not verify with any known key (or is missing / unreadable).
  badSignature,

  /// Signed but not a manifest we understand (shape, values, wrong channel).
  badManifest,

  /// Signed for another app.
  wrongApp,

  /// A newer manifest format: this build cannot read it, update by hand.
  schema,

  /// Newer version, but no file for this device.
  noAsset,

  /// The downloaded file has not the announced size.
  size,

  /// The downloaded file's sha256 is not the one in the manifest.
  hash,

  /// Could not write / read the updates folder.
  disk,

  /// The user cancelled the download.
  cancelled,

  /// download() with nothing offered.
  noOffer,
}

class UpdateException implements Exception {
  UpdateException(this.code, this.message, {this.attempts = const []});
  final UpdateError code;
  final String message;

  /// Every try that failed on the way: `{url, route, code, error}`.
  final List<Map<String, dynamic>> attempts;

  /// When several tries failed, the one that says most is reported: a forged or damaged
  /// answer beats "no network".
  static const _rank = {
    UpdateError.network: 0,
    UpdateError.disk: 1,
    UpdateError.badManifest: 2,
    UpdateError.noAsset: 2,
    UpdateError.schema: 3,
    UpdateError.wrongApp: 3,
    UpdateError.size: 4,
    UpdateError.hash: 4,
    UpdateError.badSignature: 5,
  };

  static UpdateException worst(List<UpdateException> all) =>
      all.reduce((a, b) => (_rank[b.code] ?? 0) > (_rank[a.code] ?? 0) ? b : a);

  @override
  String toString() => message;
}

// ───────────────────────────── manifest ─────────────────────────────

enum UpdateChannel {
  stable,
  beta;

  static UpdateChannel of(String? s) => s == 'beta' ? beta : stable;
}

/// A patch that turns an older full file of the same platform into this release's asset
/// (docs/updates.md -> "Дельта-обновления"): download it instead of the whole installer when the
/// installed file's sha256 is [from]. Made by `tool/make_delta.dart`, applied by [applyDelta].
class UpdateDelta {
  const UpdateDelta({required this.from, required this.file, required this.size, required this.sha256, this.urls = const []});

  /// Lower-case hex sha256 of the full file the patch applies to.
  final String from;

  /// File name only, like [UpdateAsset.file].
  final String file;
  final int size;

  /// Lower-case hex sha256 of the patch file itself.
  final String sha256;

  /// As [UpdateAsset.urls].
  final List<String> urls;

  static final _hexRe = RegExp(r'^[0-9a-f]{64}$');

  static UpdateDelta fromJson(String platform, Object? j) {
    if (j is! Map) throw FormatException('$platform: delta is not an object');
    final from = j['from'], file = j['file'], size = j['size'], hash = j['sha256'], urls = j['urls'];
    if (from is! String || !_hexRe.hasMatch(from)) throw FormatException('$platform: bad delta from');
    if (file is! String || !UpdateAsset._fileRe.hasMatch(file) || file.contains('..')) throw FormatException('$platform: bad delta file name');
    if (size is! int || size <= 0 || size > maxAssetBytes) throw FormatException('$platform: bad delta size');
    if (hash is! String || !_hexRe.hasMatch(hash)) throw FormatException('$platform: bad delta sha256');
    if (urls != null && (urls is! List || urls.any((u) => u is! String || !UpdateAsset._goodUrl(u)))) throw FormatException('$platform: bad delta urls');
    return UpdateDelta(from: from, file: file, size: size, sha256: hash, urls: [for (final u in (urls as List? ?? const [])) u as String]);
  }

  Map<String, dynamic> toJson() => {
        'from': from,
        'file': file,
        'size': size,
        'sha256': sha256,
        if (urls.isNotEmpty) 'urls': urls,
      };
}

/// At most this many deltas per asset are read (a manifest is a few KB).
const maxDeltasPerAsset = 16;

/// One installable file of a release.
class UpdateAsset {
  const UpdateAsset({required this.platform, required this.file, required this.size, required this.sha256, this.urls = const [], this.kind, this.deltas = const []});

  /// One of [updatePlatformIds].
  final String platform;

  /// File name only (`[A-Za-z0-9._-]+`): it is also the name in the updates folder.
  final String file;
  final int size;

  /// Lower-case hex.
  final String sha256;

  /// Absolute URLs, or paths relative to a feed (tried under every feed). None: `<feed>/<file>`.
  final List<String> urls;

  /// `apk` | `installer` | `zip`; the platform side decides what to do with it.
  final String? kind;

  /// Patches from older full files to this one ([UpdateDelta]); a client that does not know the
  /// field ignores it and downloads the whole file.
  final List<UpdateDelta> deltas;

  static final _fileRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

  static UpdateAsset fromJson(String platform, Object? j) {
    if (j is! Map) throw const FormatException('asset is not an object');
    final file = j['file'], size = j['size'], hash = j['sha256'], urls = j['urls'], kind = j['kind'];
    if (file is! String || !_fileRe.hasMatch(file) || file.contains('..')) throw FormatException('$platform: bad file name');
    if (size is! int || size <= 0 || size > maxAssetBytes) throw FormatException('$platform: bad size');
    if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) throw FormatException('$platform: bad sha256');
    if (urls != null && (urls is! List || urls.any((u) => u is! String || !_goodUrl(u)))) throw FormatException('$platform: bad urls');
    if (kind != null && kind is! String) throw FormatException('$platform: bad kind');
    final deltas = j['deltas'];
    if (deltas != null && (deltas is! List || deltas.length > maxDeltasPerAsset)) throw FormatException('$platform: bad deltas');
    return UpdateAsset(
        platform: platform,
        file: file,
        size: size,
        sha256: hash,
        urls: [for (final u in (urls as List? ?? const [])) u as String],
        kind: kind as String?,
        deltas: [for (final d in (deltas as List? ?? const [])) UpdateDelta.fromJson(platform, d)]);
  }

  static bool _goodUrl(String u) {
    final uri = Uri.tryParse(u);
    if (uri == null || u.trim() != u || u.isEmpty) return false;
    return uri.hasScheme ? (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty : !uri.hasAuthority && !u.startsWith('/') && !u.contains('..');
  }

  Map<String, dynamic> toJson() => {
        'file': file,
        'size': size,
        'sha256': sha256,
        if (urls.isNotEmpty) 'urls': urls,
        if (kind != null) 'kind': kind,
        if (deltas.isNotEmpty) 'deltas': [for (final d in deltas) d.toJson()],
      };
}

/// The signed description of one release on one channel (docs/updates.md -> "Манифест").
class UpdateManifest {
  const UpdateManifest({
    required this.channel,
    required this.version,
    required this.assets,
    this.minSupported,
    this.publishedAt,
    this.page,
    this.notes = const {},
    this.androidSigners = const [],
  });

  final UpdateChannel channel;

  /// Semver with the build number (`build` field).
  final AppVersion version;

  /// Versions below this must update (forced update).
  final AppVersion? minSupported;
  final DateTime? publishedAt;

  /// Where a person can get it by hand (shown when an update cannot be installed).
  final String? page;

  /// Release notes by language (`en`, `ru`).
  final Map<String, String> notes;

  /// SHA-256 of the APK signing certificate(s) (hex, lower-case). The Android side compares
  /// the downloaded APK's signer with these AND with the installed app's own.
  final List<String> androidSigners;
  final Map<String, UpdateAsset> assets;

  String notesFor(String lang) => notes[lang] ?? notes['en'] ?? (notes.isEmpty ? '' : notes.values.first);

  /// Parses the manifest bytes. Throws [UpdateException] ([UpdateError.badManifest] /
  /// `wrongApp` / `schema`). [expectChannel]: a manifest of another channel in this slot
  /// is refused (a beta build must not come down the stable file).
  static UpdateManifest parse(List<int> bytes, {UpdateChannel? expectChannel}) {
    Object? j;
    try {
      j = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw UpdateException(UpdateError.badManifest, 'Manifest is not JSON');
    }
    try {
      if (j is! Map) throw const FormatException('not an object');
      final schema = j['schema'];
      if (schema is! int) throw const FormatException('no schema');
      if (schema > manifestSchema) throw UpdateException(UpdateError.schema, 'Manifest format $schema is newer than this app reads');
      if (schema < 1) throw const FormatException('bad schema');
      if (j['app'] != manifestApp) throw UpdateException(UpdateError.wrongApp, 'Manifest is for "${j['app']}"');
      final ch = j['channel'];
      if (ch != 'stable' && ch != 'beta') throw FormatException('unknown channel "$ch"');
      final channel = UpdateChannel.of(ch as String);
      if (expectChannel != null && channel != expectChannel) throw FormatException('channel is $ch, expected ${expectChannel.name}');
      final build = j['build'];
      if (build is! int || build < 1) throw const FormatException('bad build');
      final version = AppVersion.parse(j['version'] as String, build: build);
      if (j['version'].toString().contains('+')) throw const FormatException('version has no +build, build is its own field');
      AppVersion? min;
      if (j['minSupported'] != null) {
        min = AppVersion.parse(j['minSupported'] as String);
        if (min > version) throw const FormatException('minSupported is above the version');
      }
      final notes = <String, String>{};
      final n = j['notes'];
      if (n != null) {
        if (n is! Map) throw const FormatException('bad notes');
        n.forEach((k, v) {
          if (k is! String || v is! String) throw const FormatException('bad notes');
          notes[k] = v;
        });
      }
      final signers = <String>[];
      final android = j['android'];
      if (android != null) {
        if (android is! Map) throw const FormatException('bad android block');
        final s = android['signerSha256'];
        if (s != null) {
          if (s is! List) throw const FormatException('bad signerSha256');
          for (final x in s) {
            if (x is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(x)) throw const FormatException('bad signerSha256');
            signers.add(x);
          }
        }
      }
      final a = j['assets'];
      if (a is! Map || a.isEmpty) throw const FormatException('no assets');
      final assets = <String, UpdateAsset>{};
      a.forEach((k, v) {
        // an asset for a platform this build does not know is skipped, not an error: a
        // newer release may add one
        if (k is String && updatePlatformIds.contains(k)) assets[k] = UpdateAsset.fromJson(k, v);
      });
      final at = j['publishedAt'];
      final page = j['page'];
      if (page != null && (page is! String || !UpdateAsset._goodUrl(page) || !Uri.parse(page).hasScheme)) throw const FormatException('bad page');
      return UpdateManifest(
        channel: channel,
        version: version,
        minSupported: min,
        publishedAt: at is String ? DateTime.tryParse(at) : null,
        page: page as String?,
        notes: notes,
        androidSigners: signers,
        assets: assets,
      );
    } on UpdateException {
      rethrow;
    } on FormatException catch (e) {
      throw UpdateException(UpdateError.badManifest, 'Bad manifest: ${e.message}');
    } on TypeError {
      throw UpdateException(UpdateError.badManifest, 'Bad manifest: wrong field type');
    }
  }

  Map<String, dynamic> toJson() => {
        'schema': manifestSchema,
        'app': manifestApp,
        'channel': channel.name,
        'version': version.semver,
        'build': version.build,
        if (publishedAt != null) 'publishedAt': publishedAt!.toUtc().toIso8601String(),
        if (minSupported != null) 'minSupported': minSupported!.semver,
        if (page != null) 'page': page,
        if (notes.isNotEmpty) 'notes': notes,
        if (androidSigners.isNotEmpty) 'android': {'signerSha256': androidSigners},
        'assets': {for (final e in assets.entries) e.key: e.value.toJson()},
      };
}

/// The file for this device: the first of [platforms] (best first, see [updatePlatforms])
/// the manifest has. Null = none.
UpdateAsset? chooseAsset(UpdateManifest m, List<String> platforms) {
  for (final p in platforms) {
    final a = m.assets[p];
    if (a != null) return a;
  }
  return null;
}

// ───────────────────────────── signature ─────────────────────────────

/// Does [signature] (64 bytes) over [message] verify with [publicKey] (32 bytes)?
Future<bool> verifyEd25519(List<int> message, List<int> signature, List<int> publicKey) async {
  if (signature.length != 64 || publicKey.length != 32) return false;
  try {
    return await Ed25519().verify(message, signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
  } catch (_) {
    return false;
  }
}

/// True when some signature of [sigFile] (base64, one per line / whitespace-separated; more
/// than one only while keys are being replaced) over [manifestBytes] verifies with some of
/// [publicKeys] (base64).
Future<bool> verifyManifestSignature(List<int> manifestBytes, String sigFile, List<String> publicKeys) async {
  final sigs = <List<int>>[];
  for (final w in sigFile.split(RegExp(r'\s+')).where((s) => s.isNotEmpty)) {
    try {
      sigs.add(base64.decode(base64.normalize(w)));
    } on FormatException {
      // not base64: it is no signature
    }
  }
  for (final k in publicKeys) {
    List<int> key;
    try {
      key = base64.decode(base64.normalize(k.trim()));
    } on FormatException {
      continue;
    }
    for (final s in sigs) {
      if (await verifyEd25519(manifestBytes, s, key)) return true;
    }
  }
  return false;
}

// ───────────────────────────── http seam ─────────────────────────────

/// How a request goes: straight, or through the running tunnel (the core's own `tunnel-in`
/// inbound, the same way subscriptions go through the proxy, fetch.dart).
enum UpdateRoute { direct, tunnel }

class UpdateReply {
  UpdateReply(this.status, this.body, {this.length, this.onClose});
  final int status;

  /// Bytes the body will have (of this reply, not the whole file for a 206); null = unknown.
  final int? length;
  final Stream<List<int>> body;

  /// Frees the connection; also cancels a body still coming.
  final void Function()? onClose;
}

/// One GET. Fails (throws) when the host cannot be reached; an HTTP error status is a
/// reply, not an exception. [rangeFrom] > 0 asks for `Range: bytes=N-`. The tests give
/// their own, over loopback.
typedef UpdateGet = Future<UpdateReply> Function(Uri url, UpdateRoute route, {int rangeFrom, Duration timeout});

/// The real [UpdateGet]. [proxyPort] = the tunnel-in port of the running sing-box (null =
/// no tunnel: the `tunnel` route fails at once). `direct` follows the environment's proxy
/// like subscriptions do.
UpdateGet httpUpdateGet({int? Function()? proxyPort}) {
  return (Uri url, UpdateRoute route, {int rangeFrom = 0, Duration timeout = const Duration(seconds: 20)}) async {
    final port = route == UpdateRoute.tunnel ? proxyPort?.call() : null;
    if (route == UpdateRoute.tunnel && port == null) throw const SocketException('No tunnel is up');
    final c = HttpClient()
      ..findProxy = port == null ? HttpClient.findProxyFromEnvironment : ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = timeout
      ..userAgent = 'Jormungand-updater';
    try {
      final req = await c.getUrl(url).timeout(timeout);
      if (rangeFrom > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$rangeFrom-');
      final res = await req.close().timeout(timeout);
      return UpdateReply(res.statusCode, res, length: res.contentLength < 0 ? null : res.contentLength, onClose: () => c.close(force: true));
    } catch (_) {
      c.close(force: true);
      rethrow;
    }
  };
}

// ───────────────────────────── status ─────────────────────────────

enum UpdatePhase { idle, checking, upToDate, available, downloading, ready, failed }

/// What the manifest offers this device.
class UpdateOffer {
  const UpdateOffer({required this.manifest, required this.asset, required this.forced, required this.feed, required this.route, this.delta});
  final UpdateManifest manifest;
  final UpdateAsset asset;

  /// The patch that fits the installed file (its sha256 is the delta's `from`): what a download
  /// fetches first. Null: the whole file.
  final UpdateDelta? delta;

  /// The running version is below `minSupported`: the app must update before use.
  final bool forced;

  /// The feed that gave the manifest, and the way it came; the file is tried that way first.
  final String feed;
  final UpdateRoute route;

  AppVersion get version => manifest.version;

  UpdateOffer withoutDelta() => UpdateOffer(manifest: manifest, asset: asset, forced: forced, feed: feed, route: route);

  Map<String, dynamic> toJson() => {
        'version': manifest.version.semver,
        'build': manifest.version.build,
        'channel': manifest.channel.name,
        'forced': forced,
        'notes': manifest.notes,
        'publishedAt': manifest.publishedAt?.toUtc().toIso8601String(),
        'page': manifest.page,
        'size': asset.size,
        if (delta != null) 'delta': true,
        if (delta != null) 'deltaSize': delta!.size,
        'file': asset.file,
        'kind': asset.kind,
        'platform': asset.platform,
        'feed': feed,
        'via': route.name,
      };
}

class UpdateStatus {
  const UpdateStatus(
    this.phase, {
    required this.current,
    this.offer,
    this.received = 0,
    this.total = 0,
    this.file,
    this.error,
    this.checkedAt,
    this.lastError,
  });

  final UpdatePhase phase;
  final AppVersion current;

  /// available / downloading / ready (also failed after a download, so Retry knows what).
  final UpdateOffer? offer;
  final int received, total;

  /// ready: the verified file.
  final String? file;

  /// failed: why.
  final UpdateException? error;

  /// ms since epoch of the last finished check.
  final int? checkedAt;

  /// The last scheduled (silent) check failed: shown small, not as an error state.
  final UpdateException? lastError;

  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'current': current.semver,
        'currentBuild': current.build,
        if (offer != null) 'offer': offer!.toJson(),
        if (phase == UpdatePhase.downloading) 'received': received,
        if (phase == UpdatePhase.downloading) 'total': total,
        if (file != null) 'file': file,
        if (error != null) 'error': {'code': error!.code.name, 'message': error!.message},
        if (lastError != null) 'lastError': {'code': lastError!.code.name, 'message': lastError!.message},
        'checkedAt': checkedAt,
      };
}

/// Settings → Data «Auto-download» (`genCfg.updAutoDownload`): `wifi` = unmetered networks only.
enum UpdateAutoDownload { off, wifi, always }

/// What [AppUpdater.reconcile] found after a restart.
enum InstallOutcome { none, installed, failed }

typedef UpdateEventSink = void Function(String type, String level, Map<String, dynamic> data);

// ───────────────────────────── the updater ─────────────────────────────

/// Checks the feeds, downloads and verifies the file. The platform side takes it from
/// `ready` (see docs/updates.md); one instance for the app, owned by the core service.
///
/// Feeds are tried in order, all of them directly first, then (when a tunnel is up) all of
/// them through the tunnel: a feed that works straight is cheaper than the tunnel, and one
/// blocked host must not hide the others.
class AppUpdater {
  AppUpdater({
    required this.dir,
    required this.current,
    required this.platforms,
    List<String>? feeds,
    List<String>? publicKeys,
    UpdateGet? get,
    this.tunnelUp,
    this.onEvent,
    this.installedPackage,
    int Function()? now,
    this.manifestTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 30),
  })  : feeds = List.unmodifiable(feeds ?? releaseFeeds),
        publicKeys = List.unmodifiable(publicKeys ?? releasePublicKeys),
        _get = get ?? httpUpdateGet(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _status = UpdateStatus(UpdatePhase.idle, current: current);
  }

  /// `<dataDir>/updates`.
  final Directory dir;

  /// The running app: semver + build.
  final AppVersion current;

  /// The asset keys for this device, best first ([updatePlatforms]).
  final List<String> platforms;
  final List<String> feeds;
  final List<String> publicKeys;
  final UpdateGet _get;

  /// Is the tunnel up now (the `tunnel` route is only tried then).
  final bool Function()? tunnelUp;

  /// The events journal: `('updateAvailable' | 'updateDownloaded' | 'updateFailed' |
  /// 'updateInstalled', level, data)` in category `core`.
  final UpdateEventSink? onEvent;

  /// The file the running app was installed from (Android: `applicationInfo.sourceDir`), when the
  /// platform can read it: its sha256 picks a delta of the offer ([UpdateDelta.from]). Null: always
  /// the whole file (the desktop, for now).
  final String? installedPackage;
  final int Function() _now;
  final Duration manifestTimeout, requestTimeout, stallTimeout;

  late UpdateStatus _status;
  final _changes = StreamController<UpdateStatus>.broadcast();
  Future<UpdateStatus>? _checking, _downloading;
  bool _cancel = false;
  UpdateException? _lastError;
  Timer? _timer;
  int? _checkedAt;
  bool Function()? _autoCheck;
  UpdateAutoDownload _autoDownload = UpdateAutoDownload.off;
  bool _metered = false;

  UpdateStatus get status => _status;
  Stream<UpdateStatus> get changes => _changes.stream;

  File get _stateFile => File(p.join(dir.path, 'state.json'));
  File get _readyFile => File(p.join(dir.path, 'ready.json'));

  void _set(UpdateStatus s) {
    _status = s;
    if (!_changes.isClosed) _changes.add(s);
  }

  void _event(String type, String level, Map<String, dynamic> data) {
    try {
      onEvent?.call(type, level, data);
    } catch (_) {
      // the journal must not break an update
    }
  }

  List<UpdateRoute> get _routes => [UpdateRoute.direct, if (tunnelUp?.call() ?? false) UpdateRoute.tunnel];

  // ── check ──

  /// Asks the feeds for [channel] (beta also looks at stable: a beta user must not be left
  /// below the release). A running check is joined. [manual]: the user pressed Check now, a
  /// failure is an error state; a scheduled one is only [UpdateStatus.lastError].
  Future<UpdateStatus> check({UpdateChannel channel = UpdateChannel.stable, bool manual = false}) {
    if (_downloading != null) return _downloading!;
    return _checking ??= _check(channel, manual).whenComplete(() => _checking = null);
  }

  Future<UpdateStatus> _check(UpdateChannel channel, bool manual) async {
    final before = _status;
    _set(UpdateStatus(UpdatePhase.checking, current: current, offer: before.offer, checkedAt: _checkedAt, lastError: _lastError));
    try {
      if (publicKeys.isEmpty) throw UpdateException(UpdateError.noKey, 'No release key is built into this app');
      final channels = channel == UpdateChannel.beta ? [UpdateChannel.beta, UpdateChannel.stable] : [UpdateChannel.stable];
      final found = <_Found>[];
      final errors = <UpdateException>[];
      for (final c in channels) {
        try {
          final f = await _fetchManifest(c);
          if (f != null) found.add(f); // null: nothing published in that channel
        } on UpdateException catch (e) {
          errors.add(e);
        }
      }
      if (found.isEmpty && errors.isNotEmpty) throw UpdateException.worst(errors);
      found.sort((a, b) => b.manifest.version.compareTo(a.manifest.version));
      _checkedAt = _now();
      _lastError = null;
      unawaited(_saveState());
      if (found.isEmpty) {
        // every asked channel is empty: nothing newer than what runs
        _set(UpdateStatus(UpdatePhase.upToDate, current: current, checkedAt: _checkedAt));
        return _status;
      }
      final best = found.first;
      final m = best.manifest;
      if (m.version <= current) {
        _set(UpdateStatus(UpdatePhase.upToDate, current: current, checkedAt: _checkedAt));
        return _status;
      }
      final asset = chooseAsset(m, platforms);
      if (asset == null) {
        throw UpdateException(UpdateError.noAsset, 'Version ${m.version} has no file for this device (${platforms.join(', ')})');
      }
      final offer = UpdateOffer(
          manifest: m, asset: asset, forced: m.minSupported != null && current < m.minSupported!, feed: best.feed, route: best.route, delta: await _matchDelta(asset));
      // the same offer already downloaded: stay ready
      if (before.phase == UpdatePhase.ready && before.offer?.version == offer.version && before.file != null) {
        _set(UpdateStatus(UpdatePhase.ready, current: current, offer: offer, file: before.file, checkedAt: _checkedAt));
        return _status;
      }
      _set(UpdateStatus(UpdatePhase.available, current: current, offer: offer, checkedAt: _checkedAt));
      if (before.offer?.version != offer.version) {
        _event('updateAvailable', 'info', {'version': m.version.semver, 'build': m.version.build, 'channel': m.channel.name, 'forced': offer.forced, 'via': best.route.name});
      }
      return _status;
    } on UpdateException catch (e) {
      _event('updateFailed', manual ? 'warn' : 'info', {'stage': 'check', 'code': e.code.name, 'error': e.message, if (e.attempts.isNotEmpty) 'attempts': e.attempts});
      if (manual) {
        _set(UpdateStatus(UpdatePhase.failed, current: current, error: e, checkedAt: _checkedAt));
      } else {
        _lastError = e;
        _set(UpdateStatus(before.phase == UpdatePhase.checking ? UpdatePhase.idle : before.phase,
            current: current, offer: before.offer, file: before.file, checkedAt: _checkedAt, lastError: e));
      }
      return _status;
    }
  }

  static String _base(String feed) => feed.endsWith('/') ? feed : '$feed/';

  /// Direct pass over all feeds, then tunnel pass; the first verified manifest wins.
  /// Null: the channel is empty (nothing was ever published there) - a reachable feed
  /// answered 404 / 410 for the manifest itself and no feed failed in a way that says more
  /// than "unreachable" (a bad signature / manifest anywhere stays an error).
  Future<_Found?> _fetchManifest(UpdateChannel channel) async {
    if (feeds.isEmpty) throw UpdateException(UpdateError.network, 'No update feed is configured');
    final errors = <UpdateException>[];
    final attempts = <Map<String, dynamic>>[];
    var absent = false;
    for (final route in _routes) {
      for (final feed in feeds) {
        final name = 'manifest-${channel.name}.json';
        final url = Uri.parse('${_base(feed)}$name');
        try {
          final bytes = await _readBody(url, route, maxManifestBytes, absentIsEmpty: true);
          final sig = utf8.decode(await _readBody(Uri.parse('${_base(feed)}$name.sig'), route, 8 * 1024), allowMalformed: true);
          if (!await verifyManifestSignature(bytes, sig, publicKeys)) {
            throw UpdateException(UpdateError.badSignature, 'The manifest signature is not valid');
          }
          return _Found(UpdateManifest.parse(bytes, expectChannel: channel), feed, route);
        } on _ManifestAbsent catch (e) {
          absent = true;
          attempts.add({'url': url.toString(), 'route': route.name, 'code': 'notFound', 'error': 'HTTP ${e.status}'});
        } on UpdateException catch (e) {
          errors.add(e);
          attempts.add({'url': url.toString(), 'route': route.name, 'code': e.code.name, 'error': e.message});
        } catch (e) {
          errors.add(UpdateException(UpdateError.network, '$e'));
          attempts.add({'url': url.toString(), 'route': route.name, 'code': 'network', 'error': '$e'});
        }
      }
    }
    // a 404 is not a failure; only real errors beyond "unreachable" override it
    final w = errors.isEmpty ? null : UpdateException.worst(errors);
    if (absent && (w == null || w.code == UpdateError.network)) {
      _event('updateChannelEmpty', 'info', {'channel': channel.name, 'attempts': attempts});
      return null;
    }
    final err = w ?? UpdateException(UpdateError.network, 'No update feed answered');
    throw UpdateException(err.code, err.message, attempts: attempts);
  }

  Future<List<int>> _readBody(Uri url, UpdateRoute route, int max, {bool absentIsEmpty = false}) async {
    final r = await _get(url, route, timeout: requestTimeout);
    try {
      if (absentIsEmpty && (r.status == 404 || r.status == 410)) throw _ManifestAbsent(r.status);
      if (r.status != 200) throw HttpException('HTTP ${r.status}', uri: url);
      if ((r.length ?? 0) > max) throw HttpException('Too big', uri: url);
      final b = BytesBuilder(copy: false);
      await for (final chunk in r.body.timeout(manifestTimeout)) {
        b.add(chunk);
        if (b.length > max) throw HttpException('Too big', uri: url);
      }
      return b.takeBytes();
    } finally {
      r.onClose?.call();
    }
  }

  // ── schedule ──

  /// Check on launch (after [firstDelay], so it does not compete with the connect) and
  /// every [every] after that, while [autoCheck] says yes. Failures are silent.
  void startSchedule({
    required bool Function() autoCheck,
    required UpdateChannel Function() channel,
    Duration firstDelay = const Duration(seconds: 10),
    Duration every = const Duration(hours: 24),
    Timer Function(Duration, void Function())? timer,
  }) {
    stopSchedule();
    final mk = timer ?? Timer.new;
    _autoCheck = autoCheck;
    Future<void> tick() async {
      if (autoCheck() && _downloading == null && _status.phase != UpdatePhase.ready) {
        await check(channel: channel());
        await _maybeAutoDownload();
      }
      _timer = mk(every, () => unawaited(tick()));
    }

    _timer = mk(firstDelay, () => unawaited(tick()));
  }

  void stopSchedule() {
    _timer?.cancel();
    _timer = null;
  }

  /// Settings → Data «Auto-download» and what the platform reports about the network. A
  /// change while an offer waits (`available`) starts the download if the rules now allow it.
  void setAutoDownload({UpdateAutoDownload? auto, bool? metered}) {
    final changed = (auto != null && auto != _autoDownload) || (metered != null && metered != _metered);
    if (auto != null) _autoDownload = auto;
    if (metered != null) _metered = metered;
    if (changed) unawaited(_maybeAutoDownload());
  }

  /// Auto-download (never an install): [UpdateAutoDownload.always], or `wifi` on an unmetered
  /// network, while the scheduled check is on. A failure stays silent like a scheduled
  /// check's: the offer stays, the error goes to [UpdateStatus.lastError], the user can retry.
  Future<void> _maybeAutoDownload() async {
    if (_status.phase != UpdatePhase.available || _status.offer == null || _downloading != null || _checking != null) return;
    if (_autoCheck?.call() != true) return;
    final ok = _autoDownload == UpdateAutoDownload.always || (_autoDownload == UpdateAutoDownload.wifi && !_metered);
    if (!ok) return;
    try {
      final s = await download();
      if (s.phase == UpdatePhase.failed) {
        _lastError = s.error;
        _set(UpdateStatus(UpdatePhase.available, current: current, offer: s.offer, checkedAt: _checkedAt, lastError: _lastError));
      }
    } catch (_) {
      // nothing to download any more
    }
  }

  Future<void> dispose() async {
    stopSchedule();
    await _changes.close();
  }

  // ── download ──

  /// Downloads the offered file into [dir] and verifies size and sha256. Resumes a `.part`
  /// left by an earlier try. Returns the new status: `ready` (file verified) or `failed`.
  Future<UpdateStatus> download() async {
    final offer = _status.offer;
    if (offer == null) throw UpdateException(UpdateError.noOffer, 'Nothing to download');
    if (_status.phase == UpdatePhase.ready) return Future.value(_status);
    return _downloading ??= _download(offer).whenComplete(() => _downloading = null);
  }

  /// Stops a download in progress; the `.part` stays for a resume. Status goes back to `available`.
  void cancelDownload() => _cancel = true;

  Future<UpdateStatus> _download(UpdateOffer offer) async {
    _cancel = false;
    final a = offer.asset;
    _set(UpdateStatus(UpdatePhase.downloading, current: current, offer: offer, total: offer.delta?.size ?? a.size, checkedAt: _checkedAt));
    final errors = <UpdateException>[];
    final attempts = <Map<String, dynamic>>[];
    var plan = offer; // what the statuses show while downloading
    try {
      await dir.create(recursive: true);
      final routes = _routes;
      if (offer.route == UpdateRoute.tunnel && routes.contains(UpdateRoute.tunnel)) {
        routes
          ..remove(UpdateRoute.tunnel)
          ..insert(0, UpdateRoute.tunnel);
      }
      // the patch for the installed file first; whatever goes wrong there, the whole file is next
      final delta = offer.delta;
      if (delta != null) {
        final got = await _downloadDelta(offer, delta, routes);
        if (got != null) {
          await _writeReady(offer, got.file);
          _set(UpdateStatus(UpdatePhase.ready, current: current, offer: offer, file: got.file.path, checkedAt: _checkedAt));
          _event('updateDownloaded', 'info', {'version': offer.version.semver, 'build': offer.version.build, 'size': a.size, 'via': got.route.name, 'delta': true, 'downloaded': delta.size});
          return _status;
        }
        // the statuses of the whole-file download say so; a failure keeps [offer] (a retry tries the patch again)
        plan = offer.withoutDelta();
        _set(UpdateStatus(UpdatePhase.downloading, current: current, offer: plan, total: a.size, checkedAt: _checkedAt));
      }
      final urls = _urlsOf(plan, a.urls, a.file);
      for (final route in routes) {
        for (final url in urls) {
          try {
            final file = await _downloadOne(plan, url, route, file: a.file, size: a.size, sha: a.sha256);
            await _writeReady(plan, file);
            _set(UpdateStatus(UpdatePhase.ready, current: current, offer: plan, file: file.path, checkedAt: _checkedAt));
            _event('updateDownloaded', 'info', {'version': plan.version.semver, 'build': plan.version.build, 'size': a.size, 'via': route.name});
            return _status;
          } on UpdateException catch (e) {
            if (e.code == UpdateError.cancelled) rethrow;
            errors.add(e);
            attempts.add({'url': url.toString(), 'route': route.name, 'code': e.code.name, 'error': e.message});
          } catch (e) {
            errors.add(UpdateException(UpdateError.network, '$e'));
            attempts.add({'url': url.toString(), 'route': route.name, 'code': 'network', 'error': '$e'});
          }
        }
      }
      final w = errors.isEmpty ? UpdateException(UpdateError.network, 'No address to download from') : UpdateException.worst(errors);
      throw UpdateException(w.code, w.message, attempts: attempts);
    } on UpdateException catch (e) {
      if (e.code == UpdateError.cancelled) {
        _set(UpdateStatus(UpdatePhase.available, current: current, offer: offer, checkedAt: _checkedAt));
      } else {
        _event('updateFailed', 'warn', {'stage': e.code == UpdateError.hash || e.code == UpdateError.size ? 'verify' : 'download', 'code': e.code.name, 'error': e.message, if (e.attempts.isNotEmpty) 'attempts': e.attempts});
        _set(UpdateStatus(UpdatePhase.failed, current: current, offer: offer, error: e, checkedAt: _checkedAt));
      }
      return _status;
    } on FileSystemException catch (e) {
      final ex = UpdateException(UpdateError.disk, 'Cannot write ${e.path ?? dir.path}: ${e.message}');
      _event('updateFailed', 'warn', {'stage': 'download', 'code': 'disk', 'error': ex.message});
      _set(UpdateStatus(UpdatePhase.failed, current: current, offer: offer, error: ex, checkedAt: _checkedAt));
      return _status;
    }
  }

  /// The asset's addresses: absolute ones as they are, relative ones under every feed
  /// (the feed that gave the manifest first), none given: `<feed>/<file>`.
  List<Uri> _urlsOf(UpdateOffer o, List<String> urls, String file) {
    final order = [o.feed, ...feeds.where((f) => f != o.feed)];
    final out = <Uri>[];
    void add(Uri u) {
      if (!out.contains(u)) out.add(u);
    }

    final given = urls.isEmpty ? [file] : urls;
    for (final u in given) {
      final uri = Uri.parse(u);
      if (uri.hasScheme) {
        add(uri);
      } else {
        for (final f in order) {
          add(Uri.parse('${_base(f)}$u'));
        }
      }
    }
    return out;
  }

  /// One address over one route, resuming a `.part`; the verified file at the end. [file], [size]
  /// and [sha] are what is fetched: the installer, or a delta of the offer.
  Future<File> _downloadOne(UpdateOffer offer, Uri url, UpdateRoute route, {required String file, required int size, required String sha, bool retried = false}) async {
    final part = File(p.join(dir.path, '$file.part'));
    var have = part.existsSync() ? part.lengthSync() : 0;
    if (have > size) {
      part.deleteSync();
      have = 0;
    }
    if (have < size) {
      final r = await _get(url, route, rangeFrom: have, timeout: requestTimeout);
      try {
        if (r.status == 416 && have > 0 && !retried) {
          part.deleteSync();
          return await _downloadOne(offer, url, route, file: file, size: size, sha: sha, retried: true);
        }
        if (r.status != 200 && r.status != 206) throw HttpException('HTTP ${r.status}', uri: url);
        final resume = r.status == 206 && have > 0;
        if (!resume) have = 0; // the server sent the whole file: start over
        final sink = part.openWrite(mode: resume ? FileMode.append : FileMode.write);
        var got = have;
        try {
          await for (final chunk in r.body.timeout(stallTimeout)) {
            if (_cancel) throw UpdateException(UpdateError.cancelled, 'Cancelled');
            got += chunk.length;
            if (got > size) throw UpdateException(UpdateError.size, 'The file is bigger than the $size bytes announced');
            sink.add(chunk);
            if (_status.phase == UpdatePhase.downloading && (got - _status.received >= 65536 || got == size)) {
              _set(UpdateStatus(UpdatePhase.downloading, current: current, offer: offer, received: got, total: size, checkedAt: _checkedAt));
            }
          }
          await sink.flush();
        } catch (e) {
          // keep what came, for a resume - except the file that is already wrong
          await sink.close().catchError((_) {});
          if (e is UpdateException && e.code == UpdateError.size) _drop(part);
          rethrow;
        }
        await sink.close();
      } finally {
        r.onClose?.call();
      }
    }
    if (part.lengthSync() != size) {
      final n = part.lengthSync();
      // the connection ended early: leave the .part, the next try resumes it
      throw UpdateException(UpdateError.network, 'The connection ended at $n of $size bytes');
    }
    final digest = (await sha256.bind(part.openRead()).first).toString();
    if (digest != sha) {
      _drop(part);
      throw UpdateException(UpdateError.hash, 'The file does not match its sha256');
    }
    final done = File(p.join(dir.path, file));
    if (done.existsSync()) done.deleteSync();
    return part.renameSync(done.path);
  }

  // ── delta ──

  String? _installedSha;
  String? _installedKey;

  File get _installedCache => File(p.join(dir.path, 'installed.json'));

  /// sha256 of [installedPackage], hashed once: remembered by path + size + mtime (in memory and in
  /// `installed.json`, so a restart does not hash 100 MB again). Null: no package / unreadable.
  Future<String?> _installedSha256() async {
    final path = installedPackage;
    if (path == null || path.isEmpty) return null;
    try {
      final f = File(path);
      final st = f.statSync();
      if (st.type != FileSystemEntityType.file) return null;
      final key = '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
      if (_installedKey == key && _installedSha != null) return _installedSha;
      try {
        final j = jsonDecode(_installedCache.readAsStringSync());
        if (j is Map && j['key'] == key && j['sha256'] is String) {
          _installedKey = key;
          return _installedSha = j['sha256'] as String;
        }
      } catch (_) {}
      final sha = (await sha256.bind(f.openRead()).first).toString();
      _installedKey = key;
      _installedSha = sha;
      try {
        await dir.create(recursive: true);
        await writeFileDurable(_installedCache, jsonEncode({'key': key, 'sha256': sha}));
      } catch (_) {}
      return sha;
    } catch (_) {
      return null;
    }
  }

  /// The delta of [a] made against the installed file, if the manifest has one.
  Future<UpdateDelta?> _matchDelta(UpdateAsset a) async {
    if (a.deltas.isEmpty) return null;
    final have = await _installedSha256();
    if (have == null) return null;
    for (final d in a.deltas) {
      if (d.from == have) return d;
    }
    return null;
  }

  /// Fetches [d] (resumable like a full file), applies it to [installedPackage] and checks the result
  /// against the asset's size and sha256. The finished installer and the route it came by; null =
  /// no delta this time (nothing matched / unreachable / damaged patch / wrong result / disk): the
  /// caller downloads the whole file and the journal has the reason. A cancel is rethrown.
  Future<({File file, UpdateRoute route})?> _downloadDelta(UpdateOffer offer, UpdateDelta d, List<UpdateRoute> routes) async {
    final a = offer.asset;
    final base = installedPackage;
    final failures = <Map<String, dynamic>>[];
    void giveUp(String code, String error) {
      _event('updateDeltaFailed', 'info', {'code': code, 'error': error, 'from': d.from.substring(0, 12), if (failures.isNotEmpty) 'attempts': failures});
    }

    if (base == null) return null;
    for (final route in routes) {
      for (final url in _urlsOf(offer, d.urls, d.file)) {
        File patch;
        try {
          patch = await _downloadOne(offer, url, route, file: d.file, size: d.size, sha: d.sha256);
        } on UpdateException catch (e) {
          if (e.code == UpdateError.cancelled) rethrow;
          failures.add({'url': url.toString(), 'route': route.name, 'code': e.code.name, 'error': e.message});
          continue;
        } on FileSystemException catch (e) {
          giveUp('disk', 'Cannot write ${e.path ?? dir.path}: ${e.message}');
          return null;
        } catch (e) {
          failures.add({'url': url.toString(), 'route': route.name, 'code': 'network', 'error': '$e'});
          continue;
        }
        // the patch is the signed one (sha256 checked): if it does not apply, other addresses would not help
        final out = File(p.join(dir.path, '${a.file}.new.part'));
        try {
          await applyDelta(oldPath: base, patchPath: patch.path, outPath: out.path, expectOldSha256: d.from, expectNewSha256: a.sha256);
          if (out.lengthSync() != a.size) throw DeltaException('The result is not ${a.size} bytes');
          final done = File(p.join(dir.path, a.file));
          if (done.existsSync()) done.deleteSync();
          _drop(File(p.join(dir.path, '${a.file}.part'))); // a whole-file try that was cut earlier
          return (file: out.renameSync(done.path), route: route);
        } on DeltaException catch (e) {
          giveUp('delta', e.message);
        } on FileSystemException catch (e) {
          giveUp('disk', 'Cannot write ${e.path ?? dir.path}: ${e.message}');
        } catch (e) {
          giveUp('delta', '$e');
        } finally {
          _drop(patch);
          _drop(out);
        }
        return null;
      }
    }
    giveUp('network', 'The patch could not be downloaded');
    return null;
  }

  void _drop(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ── persisted state: the ready file, last check, the install in progress ──

  Future<void> _writeReady(UpdateOffer offer, File file) =>
      writeFileDurable(_readyFile, jsonEncode({'offer': offer.toJson(), 'asset': offer.asset.toJson(), 'manifest': offer.manifest.toJson(), 'feed': offer.feed, 'route': offer.route.name, 'file': p.basename(file.path)}));

  Map<String, dynamic> _readState() {
    try {
      final j = jsonDecode(_stateFile.readAsStringSync());
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return {};
  }

  Future<void> _saveState([Map<String, dynamic>? install, bool clearInstall = false]) async {
    try {
      final s = _readState();
      s['lastCheckAt'] = _checkedAt;
      if (install != null) s['installing'] = install;
      if (clearInstall) s.remove('installing');
      await dir.create(recursive: true);
      await writeFileDurable(_stateFile, jsonEncode(s));
    } catch (_) {
      // the state is a convenience
    }
  }

  /// At start: picks up a file downloaded by an earlier run (re-verified: size and sha256
  /// again, the disk may have changed) and the time of the last check. A file for a version
  /// that is not newer than the running one is deleted. Call [reconcile] first.
  Future<UpdateStatus> restore() async {
    _checkedAt ??= (_readState()['lastCheckAt'] as num?)?.toInt();
    if (_status.phase == UpdatePhase.idle && _checkedAt != null) _set(UpdateStatus(UpdatePhase.idle, current: current, checkedAt: _checkedAt));
    try {
      if (!_readyFile.existsSync()) {
        _sweep();
        return _status;
      }
      final j = jsonDecode(_readyFile.readAsStringSync()) as Map<String, dynamic>;
      final m = UpdateManifest.parse(utf8.encode(jsonEncode(j['manifest'])));
      final a = UpdateAsset.fromJson(j['asset']['platform'] ?? (j['offer'] as Map)['platform'], j['asset']);
      final f = File(p.join(dir.path, p.basename(a.file)));
      final stale = m.version <= current || !f.existsSync() || f.lengthSync() != a.size;
      if (!stale && (await sha256.bind(f.openRead()).first).toString() == a.sha256) {
        final offer = UpdateOffer(
            manifest: m,
            asset: a,
            forced: m.minSupported != null && current < m.minSupported!,
            feed: j['feed'] as String? ?? '',
            route: j['route'] == 'tunnel' ? UpdateRoute.tunnel : UpdateRoute.direct);
        _set(UpdateStatus(UpdatePhase.ready, current: current, offer: offer, file: f.path, checkedAt: _checkedAt));
        _sweep(keep: {p.basename(f.path), p.basename(_readyFile.path)});
        return _status;
      }
      _drop(f);
      _drop(_readyFile);
    } catch (_) {
      _drop(_readyFile);
    }
    _sweep();
    return _status;
  }

  /// How long an unfinished `.part` waits for a resume before [restore] deletes it.
  static const partKeep = Duration(days: 3);

  /// At start: files nothing refers to any more go — installers other than the ready one
  /// (an update installed another way, a newer one superseded it) and `.part`s older than
  /// [partKeep]. A recent `.part` stays for a resume. Never touches `.json` files.
  void _sweep({Set<String> keep = const {}}) {
    try {
      if (!dir.existsSync()) return;
      final now = DateTime.fromMillisecondsSinceEpoch(_now());
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final n = p.basename(e.path);
        // bookkeeping (`state.json`, `ready.json`, the updater's `started.json`) is not ours to sweep
        if (n.endsWith('.json') || keep.contains(n)) continue;
        if (n.endsWith('.part') && now.difference(e.lastModifiedSync()) < partKeep) continue;
        _drop(e);
      }
    } catch (_) {}
  }

  /// The platform side calls it right before it hands the file to the installer.
  Future<void> beginInstall() async {
    final o = _status.offer;
    if (o == null || _status.phase != UpdatePhase.ready) throw UpdateException(UpdateError.noOffer, 'No downloaded update to install');
    await _saveState({'from': current.toString(), 'to': o.version.toString(), 'at': _now(), 'file': o.asset.file});
  }

  /// The install did not happen (the user declined the Android dialog, the installer
  /// reported a failure): [reason] goes to the journal; the file stays for another try.
  Future<void> installFailed(String reason) async {
    _event('updateFailed', 'warn', {'stage': 'install', 'code': 'install', 'error': reason});
    await _saveState(null, true);
  }

  /// At start, before [restore]: if an install was begun, did it work? The running version
  /// reached the target -> `updateInstalled`, the downloaded files go. Still the old one ->
  /// `updateFailed` (stage install: the installer or the updater did not finish); the
  /// downloaded file stays and the same update can be offered again.
  Future<InstallOutcome> reconcile() async {
    final inst = _readState()['installing'];
    if (inst is! Map) return InstallOutcome.none;
    final to = AppVersion.tryParse('${inst['to']}');
    await _saveState(null, true);
    if (to != null && current >= to) {
      _event('updateInstalled', 'info', {'from': '${inst['from']}', 'to': current.toString()});
      cleanup(keepFile: null);
      return InstallOutcome.installed;
    }
    _event('updateFailed', 'warn', {'stage': 'install', 'code': 'install', 'error': 'The app is still ${current.toString()} after the install', 'from': '${inst['from']}', 'to': '${inst['to']}'});
    return InstallOutcome.failed;
  }

  /// Deletes the updates folder's files (`.part`, installers, `ready.json`) except
  /// [keepFile] (a file name). Never touches `state.json`.
  void cleanup({String? keepFile}) {
    try {
      if (!dir.existsSync()) return;
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final n = p.basename(e.path);
        if (n == 'state.json' || n == keepFile) continue;
        _drop(e);
      }
    } catch (_) {}
  }
}

class _Found {
  _Found(this.manifest, this.feed, this.route);
  final UpdateManifest manifest;
  final String feed;
  final UpdateRoute route;
}

/// A feed answered 404 / 410 for the manifest file itself: nothing is published there.
class _ManifestAbsent implements Exception {
  _ManifestAbsent(this.status);
  final int status;
}
