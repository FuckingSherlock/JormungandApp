// App self-update (docs/updates.md): versions, the signed manifest, feed fallback (direct ->
// tunnel), download with size / sha256 checks, resume, install reconcile. Feeds are loopback
// HTTP servers; the "tunnel" is a route label the fake getter understands. Nothing leaves
// the machine.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/appupdate_release.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

AppVersion v(String s) => AppVersion.parse(s);

/// A feed or a file host on loopback: serves [files] by path, honours Range, counts hits.
class Host {
  Host._(this.server);
  final HttpServer server;
  final files = <String, List<int>>{};
  final hits = <String>[];
  final ranges = <String?>[];

  /// path -> status to answer instead of the file
  final fail = <String, int>{};

  /// Ignore Range (answer 200 with the whole file).
  bool ignoreRange = false;

  /// Close the connection after this many body bytes of a file (a cut download).
  int? cutAfter;

  static Future<Host> start() async {
    final h = Host._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    h.server.listen(h._serve);
    return h;
  }

  int get port => server.port;
  String get base => 'http://127.0.0.1:$port/feed';
  Uri url(String path) => Uri.parse('$base/$path');

  Future<void> _serve(HttpRequest req) async {
    final path = req.uri.path.replaceFirst('/feed/', '');
    hits.add(path);
    ranges.add(req.headers.value('range'));
    final res = req.response;
    try {
      final status = fail[path];
      if (status != null) {
        res.statusCode = status;
        return;
      }
      final body = files[path];
      if (body == null) {
        res.statusCode = 404;
        return;
      }
      var from = 0;
      final r = req.headers.value('range');
      if (r != null && !ignoreRange) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(r)!.group(1)!);
        if (from >= body.length) {
          res.statusCode = 416;
          return;
        }
        res.statusCode = 206;
      }
      var chunk = body.sublist(from);
      if (cutAfter != null && chunk.length > cutAfter!) {
        res.contentLength = chunk.length;
        final s = await res.detachSocket(); // headers go out, then the body is cut off
        s.add(chunk.sublist(0, cutAfter!));
        await s.flush();
        s.destroy();
        return;
      }
      res.contentLength = chunk.length;
      res.add(chunk);
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> close() => server.close(force: true);
}

/// The getter the updater is given: really fetches (over loopback), but refuses hosts that
/// are "blocked" - directly only, or on every route - and records every try.
class Net {
  final blockedDirect = <int>{};
  final blockedAll = <int>{};
  final calls = <String>[];
  final _real = httpUpdateGet();

  UpdateGet get get => (Uri url, UpdateRoute route, {int rangeFrom = 0, Duration timeout = const Duration(seconds: 5)}) {
        calls.add('${route.name}:${url.port}${url.path.replaceFirst('/feed', '')}');
        if (blockedAll.contains(url.port) || (route == UpdateRoute.direct && blockedDirect.contains(url.port))) {
          return Future.error(SocketException('blocked ${url.port}'));
        }
        return _real(url, UpdateRoute.direct, rangeFrom: rangeFrom, timeout: timeout);
      };
}

/// A signed release: a manifest (+ signature) and its installer bytes.
class Release {
  Release(this.keys, this.manifest, this.bytes, this.sig, this.installer);
  final ReleaseKeys keys;
  final UpdateManifest manifest;
  final Uint8List bytes; // manifest file
  final String sig;
  final Uint8List installer;
  String get file => manifest.assets.values.first.file;
}

final _rnd = Random(7);
Uint8List noise(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) _rnd.nextInt(256)]);

Future<Release> release(
  ReleaseKeys keys, {
  String version = '0.2.0',
  int build = 2,
  UpdateChannel channel = UpdateChannel.stable,
  String? minSupported,
  String platform = 'android-arm64-v8a',
  int size = 200000,
  List<String> urls = const [],
  Uint8List? installer,
  Map<String, String> notes = const {'en': 'Faster Auto', 'ru': 'Быстрее Auto'},
}) async {
  final data = installer ?? noise(size);
  final m = UpdateManifest(
    channel: channel,
    version: AppVersion.parse(version, build: build),
    minSupported: minSupported == null ? null : AppVersion.parse(minSupported),
    publishedAt: DateTime.utc(2026, 10, 3, 12),
    notes: notes,
    assets: {
      platform: UpdateAsset(platform: platform, file: 'jormungand-$version-$platform.apk', size: data.length, sha256: sha256.convert(data).toString(), urls: urls, kind: 'apk'),
    },
  );
  final bytes = manifestBytes(m);
  return Release(keys, m, bytes, await signatureFile(bytes, keys.seed), data);
}

void publish(Host h, Release r, {UpdateChannel? channel, bool installer = true}) {
  final name = 'manifest-${(channel ?? r.manifest.channel).name}.json';
  h.files[name] = r.bytes;
  h.files['$name.sig'] = utf8.encode(r.sig);
  if (installer) h.files[r.file] = r.installer;
}

void main() {
  late ReleaseKeys keys, other;
  late Directory tmp;
  late Host a, b;
  late Net net;
  var tunnel = false;

  setUpAll(() async {
    keys = await generateReleaseKeys();
    other = await generateReleaseKeys();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm_upd_');
    a = await Host.start();
    b = await Host.start();
    net = Net();
    tunnel = false;
  });

  tearDown(() async {
    await a.close();
    await b.close();
    // a state.json write may still be finishing (the updater does not wait for it): Windows
    // refuses to delete an open file, so try again, then leave it to the OS temp cleanup
    for (var i = 0; i < 5 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  AppUpdater updater({String current = '0.1.0+1', List<String>? feeds, List<String>? publicKeys, List<String>? platforms, UpdateEventSink? onEvent}) => AppUpdater(
        dir: Directory(p.join(tmp.path, 'updates')),
        current: v(current),
        platforms: platforms ?? ['android-arm64-v8a', 'android-armeabi-v7a'],
        feeds: feeds ?? [a.base],
        publicKeys: publicKeys ?? [keys.publicBase64],
        get: net.get,
        tunnelUp: () => tunnel,
        onEvent: onEvent,
        stallTimeout: const Duration(seconds: 5),
      );

  group('AppVersion', () {
    test('precedence: numbers, pre-release below release, build breaks a tie', () {
      expect(v('0.2.0') > v('0.1.9'), isTrue);
      expect(v('0.10.0') > v('0.9.0'), isTrue); // numeric, not text
      expect(v('1.0.0') > v('0.99.99'), isTrue);
      expect(v('0.3.0-beta.2') < v('0.3.0'), isTrue);
      expect(v('0.3.0-beta.2') > v('0.3.0-beta.1'), isTrue);
      expect(v('0.3.0-beta.10') > v('0.3.0-beta.9'), isTrue);
      expect(v('0.3.0-beta') > v('0.3.0-alpha'), isTrue);
      expect(v('0.3.0-1') < v('0.3.0-beta'), isTrue); // numeric identifiers are lower
      expect(v('0.3.0-beta') < v('0.3.0-beta.1'), isTrue);
      expect(v('0.2.0+5') > v('0.2.0+4'), isTrue);
      expect(v('0.2.0+1') > v('0.2.0'), isTrue);
      expect(v('0.2.1+1') > v('0.2.0+99'), isTrue); // semver first
      expect(v('0.2.0+3'), v('0.2.0+3'));
      expect(v('0.2.0+3').hashCode, v('0.2.0+3').hashCode);
    });

    test('parse and print', () {
      expect(v('v1.2.3-rc.1+7').toString(), '1.2.3-rc.1+7');
      expect(v('1.2.3').toString(), '1.2.3');
      expect(AppVersion.parse('1.2.3', build: 9).build, 9);
      expect(AppVersion.parse('1.2.3+4', build: 9).build, 4);
      for (final bad in ['1.2', '1.2.3.4', 'x', '', '1.2.3-', '1.2.3-01', '01.2.3', '1.2.3+x']) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('manifest', () {
    test('round trip, notes by language', () async {
      final r = await release(keys, minSupported: '0.1.5');
      final m = UpdateManifest.parse(r.bytes, expectChannel: UpdateChannel.stable);
      expect(m.version.toString(), '0.2.0+2');
      expect(m.minSupported, v('0.1.5'));
      expect(m.notesFor('ru'), 'Быстрее Auto');
      expect(m.notesFor('de'), 'Faster Auto'); // falls back to en
      expect(m.assets['android-arm64-v8a']!.sha256, hasLength(64));
    });

    UpdateException refused(Map<String, dynamic> j, {UpdateChannel? ch}) {
      try {
        UpdateManifest.parse(utf8.encode(jsonEncode(j)), expectChannel: ch);
      } on UpdateException catch (e) {
        return e;
      }
      fail('accepted: $j');
    }

    test('refused: wrong shape, app, channel, schema, names, versions', () async {
      final good = jsonDecode(utf8.decode((await release(keys)).bytes)) as Map<String, dynamic>;
      Map<String, dynamic> with_(void Function(Map<String, dynamic>) f) {
        final c = jsonDecode(jsonEncode(good)) as Map<String, dynamic>;
        f(c);
        return c;
      }

      expect(refused(with_((j) => j['app'] = 'karing')).code, UpdateError.wrongApp);
      expect(refused(with_((j) => j['schema'] = 2)).code, UpdateError.schema);
      expect(refused(with_((j) => j['schema'] = 0)).code, UpdateError.badManifest);
      expect(refused(with_((j) => j['channel'] = 'nightly')).code, UpdateError.badManifest);
      expect(refused(good, ch: UpdateChannel.beta).code, UpdateError.badManifest); // stable in the beta slot
      expect(refused(with_((j) => j['build'] = 0)).code, UpdateError.badManifest);
      expect(refused(with_((j) => j['version'] = '0.2.0+9')).code, UpdateError.badManifest);
      expect(refused(with_((j) => j['version'] = 'two')).code, UpdateError.badManifest);
      expect(refused(with_((j) => j['minSupported'] = '9.0.0')).code, UpdateError.badManifest);
      expect(refused(with_((j) => j['assets'] = <String, dynamic>{})).code, UpdateError.badManifest);
      expect(refused(with_((j) => (j['assets']['android-arm64-v8a'] as Map)['file'] = '../evil.apk')).code, UpdateError.badManifest);
      expect(refused(with_((j) => (j['assets']['android-arm64-v8a'] as Map)['file'] = 'a/b.apk')).code, UpdateError.badManifest);
      expect(refused(with_((j) => (j['assets']['android-arm64-v8a'] as Map)['sha256'] = 'ABC')).code, UpdateError.badManifest);
      expect(refused(with_((j) => (j['assets']['android-arm64-v8a'] as Map)['size'] = -1)).code, UpdateError.badManifest);
      expect(refused(with_((j) => (j['assets']['android-arm64-v8a'] as Map)['urls'] = ['ftp://x/y'])).code, UpdateError.badManifest);
      expect(refused(with_((j) => (j['assets']['android-arm64-v8a'] as Map)['urls'] = ['../up'])).code, UpdateError.badManifest);
      expect(() => UpdateManifest.parse(utf8.encode('nope')), throwsA(isA<UpdateException>()));
      expect(() => UpdateManifest.parse(utf8.encode('[]')), throwsA(isA<UpdateException>()));
    });

    test('an asset for a platform this build does not know is skipped', () async {
      final good = jsonDecode(utf8.decode((await release(keys)).bytes)) as Map<String, dynamic>;
      (good['assets'] as Map)['ios-arm64'] = {'whatever': true};
      final m = UpdateManifest.parse(utf8.encode(jsonEncode(good)));
      expect(m.assets.keys, ['android-arm64-v8a']);
    });
  });

  group('signature', () {
    test('valid; tampered manifest; wrong key; garbage; rotation', () async {
      final r = await release(keys);
      final pub = keys.publicBase64;
      expect(await verifyManifestSignature(r.bytes, r.sig, [pub]), isTrue);

      final tampered = Uint8List.fromList(r.bytes)..[r.bytes.length ~/ 2] ^= 1;
      expect(await verifyManifestSignature(tampered, r.sig, [pub]), isFalse);
      // one more byte at the end (a space) is a different message too
      expect(await verifyManifestSignature([...r.bytes, 32], r.sig, [pub]), isFalse);

      expect(await verifyManifestSignature(r.bytes, r.sig, [other.publicBase64]), isFalse);
      expect(await verifyManifestSignature(r.bytes, r.sig, const []), isFalse);
      expect(await verifyManifestSignature(r.bytes, '', [pub]), isFalse);
      expect(await verifyManifestSignature(r.bytes, 'not base64 !!', [pub]), isFalse);
      expect(await verifyManifestSignature(r.bytes, base64.encode(List.filled(64, 0)), [pub]), isFalse);
      expect(await verifyManifestSignature(r.bytes, base64.encode(List.filled(10, 1)), [pub]), isFalse);
      expect(await verifyManifestSignature(r.bytes, r.sig, ['@@@', pub]), isTrue); // a bad key is skipped

      // rotation: the app knows both keys, the manifest is signed by either (or both)
      expect(await verifyManifestSignature(r.bytes, r.sig, [other.publicBase64, pub]), isTrue);
      final r2 = await release(other);
      expect(await verifyManifestSignature(r2.bytes, r2.sig, [pub, other.publicBase64]), isTrue);
      expect(await verifyManifestSignature(r.bytes, '${r2.sig}\n${r.sig}', [pub]), isTrue);
    });

    test('keys from the seed are stable, a file that is not a key is refused', () async {
      final k2 = await keysFromSeed(keys.seed);
      expect(k2.publicBase64, keys.publicBase64);
      final f = File(p.join(tmp.path, 'k'))..writeAsStringSync('${keys.seedBase64}\n');
      expect(readSeedFile(f), keys.seed);
      f.writeAsStringSync('hello');
      expect(() => readSeedFile(f), throwsFormatException);
    });

    test('the release key must stay out of git trees', () {
      expect(insideGitTree(p.join(Directory.current.path, 'key')), isTrue); // core/ is in the repo
      expect(insideGitTree(p.join(tmp.path, 'key')), isFalse);
    });
  });

  group('asset choice', () {
    test('first of the preferred platforms the manifest has', () async {
      final r = await release(keys);
      final m = UpdateManifest.parse(r.bytes);
      expect(chooseAsset(m, ['android-arm64-v8a'])!.file, contains('arm64'));
      expect(chooseAsset(m, ['android-x86_64', 'android-arm64-v8a'])!.platform, 'android-arm64-v8a');
      expect(chooseAsset(m, ['android-armeabi-v7a']), isNull);
      expect(chooseAsset(m, const []), isNull);
    });

    test('platforms of a device', () {
      expect(updatePlatforms(os: 'android', abis: ['arm64-v8a', 'armeabi-v7a', 'armeabi']), ['android-arm64-v8a', 'android-armeabi-v7a']);
      expect(updatePlatforms(os: 'android', abis: ['x86_64', 'x86']), ['android-x86_64']);
      expect(updatePlatforms(os: 'windows'), ['windows-x64']);
      expect(updatePlatforms(os: 'linux'), isEmpty);
    });

    test('a newer version with no file for the device is an error on a manual check', () async {
      publish(a, await release(keys, platform: 'android-x86_64'));
      final s = await updater().check(manual: true);
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.noAsset);
    });
  });

  group('check', () {
    test('newer version -> available with the offer; events once', () async {
      publish(a, await release(keys));
      final events = <String>[];
      final u = updater(onEvent: (t, l, d) => events.add('$t/$l/${d['version']}'));
      final s = await u.check(manual: true);
      expect(s.phase, UpdatePhase.available);
      expect(s.offer!.version.toString(), '0.2.0+2');
      expect(s.offer!.forced, isFalse);
      expect(s.offer!.asset.size, 200000);
      expect(s.offer!.route, UpdateRoute.direct);
      expect(s.toJson()['offer']['notes']['ru'], 'Быстрее Auto');
      await u.check();
      expect(events, ['updateAvailable/info/0.2.0']);
    });

    test('minSupported above the running version: forced', () async {
      publish(a, await release(keys, minSupported: '0.1.5'));
      final s = await updater(current: '0.1.0+1').check(manual: true);
      expect(s.offer!.forced, isTrue);
      expect((await updater(current: '0.1.5+1').check()).offer!.forced, isFalse);
      // exactly minSupported is fine
      expect((await updater(current: '0.1.5+1').check()).phase, UpdatePhase.available);
    });

    test('same version, older version, same semver with a lower build -> up to date', () async {
      publish(a, await release(keys, version: '0.2.0', build: 5));
      expect((await updater(current: '0.2.0+5').check()).phase, UpdatePhase.upToDate);
      expect((await updater(current: '0.3.0+9').check()).phase, UpdatePhase.upToDate);
      expect((await updater(current: '0.2.0+6').check()).phase, UpdatePhase.upToDate);
      expect((await updater(current: '0.2.0+4').check()).phase, UpdatePhase.available);
      final s = await updater(current: '0.2.0+5').check();
      expect(s.checkedAt, isNotNull);
    });

    test('beta channel: the newer of beta and stable; stable never sees beta', () async {
      publish(a, await release(keys, version: '0.3.0-beta.1', build: 7, channel: UpdateChannel.beta));
      publish(a, await release(keys, version: '0.2.0', build: 5));
      var s = await updater().check(channel: UpdateChannel.beta, manual: true);
      expect(s.offer!.version.toString(), '0.3.0-beta.1+7');
      s = await updater().check(manual: true);
      expect(s.offer!.version.toString(), '0.2.0+5');
      // stable overtakes the beta: a beta user is not left behind
      publish(a, await release(keys, version: '0.3.0', build: 9));
      s = await updater().check(channel: UpdateChannel.beta, manual: true);
      expect(s.offer!.version.toString(), '0.3.0+9');
      // beta slot missing: stable still answers
      a.files.remove('manifest-beta.json');
      s = await updater().check(channel: UpdateChannel.beta, manual: true);
      expect(s.phase, UpdatePhase.available);
    });

    test('a beta manifest put in the stable slot is refused', () async {
      final r = await release(keys, channel: UpdateChannel.beta);
      publish(a, r, channel: UpdateChannel.stable);
      final s = await updater().check(manual: true);
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.badManifest);
    });

    test('feed fallback: first feed dead or 404 -> the second answers', () async {
      publish(b, await release(keys));
      final dead = await Host.start();
      final deadPort = dead.port;
      await dead.close();
      final u = updater(feeds: ['http://127.0.0.1:$deadPort/feed', a.base, b.base]);
      final s = await u.check(manual: true);
      expect(s.phase, UpdatePhase.available);
      expect(s.offer!.feed, b.base);
      expect(a.hits, ['manifest-stable.json']); // 404 on the manifest, the .sig is not asked
    });

    group('empty channel (manifest answers 404 / 410)', () {
      test('stable with no manifest anywhere -> up to date, no error, lastError cleared; attempts logged', () async {
        final events = <String>[];
        final attempts = <dynamic>[];
        final u = updater(onEvent: (t, l, d) {
          events.add('$t/$l');
          if (t == 'updateChannelEmpty') attempts.addAll(d['attempts'] as List);
        });
        a.fail['manifest-stable.json'] = 500;
        expect((await u.check()).lastError!.code, UpdateError.network);
        a.fail.clear();
        final s = await u.check(manual: true);
        expect(s.phase, UpdatePhase.upToDate);
        expect(s.error, isNull);
        expect(s.lastError, isNull);
        expect(s.checkedAt, isNotNull);
        expect(a.hits.where((h) => h.endsWith('.sig')), isEmpty);
        expect(events, contains('updateChannelEmpty/info'));
        expect(events.where((e) => e.startsWith('updateFailed')), hasLength(1)); // only the 500 earlier
        expect(attempts.single['code'], 'notFound');
        expect(attempts.single['error'], 'HTTP 404');
      });

      test('410 counts as absent too; 403 does not', () async {
        a.fail['manifest-stable.json'] = 410;
        expect((await updater().check(manual: true)).phase, UpdatePhase.upToDate);
        a.fail['manifest-stable.json'] = 403;
        final s = await updater().check(manual: true);
        expect(s.phase, UpdatePhase.failed);
        expect(s.error!.code, UpdateError.network);
      });

      test('beta: valid beta + stable 404 -> the beta is offered; both empty -> up to date', () async {
        publish(a, await release(keys, version: '0.3.0-beta.1', build: 7, channel: UpdateChannel.beta));
        var s = await updater().check(channel: UpdateChannel.beta, manual: true);
        expect(s.phase, UpdatePhase.available);
        expect(s.offer!.version.toString(), '0.3.0-beta.1+7');
        a.files.clear();
        s = await updater().check(channel: UpdateChannel.beta, manual: true);
        expect(s.phase, UpdatePhase.upToDate);
        expect(s.error, isNull);
      });

      test('beta: stable empty, beta unreachable -> still a network error', () async {
        net.blockedAll.add(a.port);
        final s = await updater().check(channel: UpdateChannel.beta, manual: true);
        expect(s.error!.code, UpdateError.network);
      });

      test('404 on one feed + a valid manifest on another -> the offer', () async {
        publish(b, await release(keys));
        final s = await updater(feeds: [a.base, b.base]).check(manual: true);
        expect(s.phase, UpdatePhase.available);
        expect(s.offer!.feed, b.base);
      });

      test('404 on one feed + a bad signature on another -> badSignature, not "empty"', () async {
        publish(b, await release(other, version: '0.9.0', build: 9));
        final s = await updater(feeds: [a.base, b.base]).check(manual: true);
        expect(s.phase, UpdatePhase.failed);
        expect(s.error!.code, UpdateError.badSignature);
        expect(s.error!.attempts, hasLength(2));
      });

      test('404 on a reachable feed + the others only unreachable -> empty channel', () async {
        net.blockedAll.add(b.port);
        final s = await updater(feeds: [a.base, b.base]).check(manual: true);
        expect(s.phase, UpdatePhase.upToDate);
        expect(s.error, isNull);
      });

      test('a manifest without its signature file is not "empty" (the .sig 404 is an error)', () async {
        publish(a, await release(keys));
        a.files.remove('manifest-stable.json.sig');
        final s = await updater().check(manual: true);
        expect(s.phase, UpdatePhase.failed);
        expect(s.error!.code, UpdateError.network);
      });

      test('every feed unreachable -> network error, never "up to date"', () async {
        net.blockedAll.addAll([a.port, b.port]);
        final s = await updater(feeds: [a.base, b.base]).check(manual: true);
        expect(s.phase, UpdatePhase.failed);
        expect(s.error!.code, UpdateError.network);
        expect(s.error!.attempts, hasLength(2));
      });
    });

    test('a feed with a bad signature is skipped for the next one; all bad -> badSignature', () async {
      final forged = await release(other, version: '0.9.0', build: 9);
      publish(a, forged);
      final good = await release(keys);
      publish(b, good);
      var s = await updater(feeds: [a.base, b.base]).check(manual: true);
      expect(s.offer!.version.toString(), '0.2.0+2');
      s = await updater(feeds: [a.base]).check(manual: true);
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.badSignature);
      expect(s.error!.message, isNot(contains('network')));
      // the manifest changed after signing
      final tampered = Uint8List.fromList(good.bytes);
      a.files['manifest-stable.json'] = utf8.encode(utf8.decode(tampered).replaceFirst('0.2.0', '9.9.9'));
      a.files['manifest-stable.json.sig'] = utf8.encode(good.sig);
      s = await updater(feeds: [a.base]).check(manual: true);
      expect(s.error!.code, UpdateError.badSignature);
    });

    test('a missing signature file refuses the manifest', () async {
      publish(a, await release(keys));
      a.files.remove('manifest-stable.json.sig');
      final s = await updater().check(manual: true);
      expect(s.phase, UpdatePhase.failed);
    });

    test('direct first on every feed, then the tunnel: direct fails -> through the tunnel', () async {
      publish(a, await release(keys));
      publish(b, await release(keys));
      net.blockedDirect.addAll([a.port, b.port]);
      tunnel = true;
      final s = await updater(feeds: [a.base, b.base]).check(manual: true);
      expect(s.phase, UpdatePhase.available);
      expect(s.offer!.route, UpdateRoute.tunnel);
      expect(s.offer!.feed, a.base);
      expect(net.calls.where((c) => c.startsWith('direct')).length, 2); // both feeds tried direct first
      expect(net.calls.indexOf(net.calls.firstWhere((c) => c.startsWith('tunnel'))), 2);
    });

    test('a feed that works directly beats the tunnel even when it is the second', () async {
      publish(b, await release(keys));
      net.blockedDirect.add(a.port);
      tunnel = true;
      final s = await updater(feeds: [a.base, b.base]).check(manual: true);
      expect(s.offer!.feed, b.base);
      expect(s.offer!.route, UpdateRoute.direct);
      expect(net.calls.any((c) => c.startsWith('tunnel')), isFalse);
    });

    test('the tunnel is not tried when no tunnel is up', () async {
      publish(a, await release(keys));
      net.blockedDirect.add(a.port);
      tunnel = false;
      final s = await updater().check(manual: true);
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.network);
      expect(net.calls.any((c) => c.startsWith('tunnel')), isFalse);
      expect(s.error!.attempts, hasLength(1));
    });

    test('all feeds down on every route -> network error with each try', () async {
      net.blockedAll.addAll([a.port, b.port]);
      tunnel = true;
      final s = await updater(feeds: [a.base, b.base]).check(manual: true);
      expect(s.error!.code, UpdateError.network);
      expect(s.error!.attempts, hasLength(4));
    });

    test('no key built in / no feeds configured', () async {
      publish(a, await release(keys));
      expect((await updater(publicKeys: const []).check(manual: true)).error!.code, UpdateError.noKey);
      expect((await updater(feeds: const []).check(manual: true)).error!.code, UpdateError.network);
    });

    test('a scheduled check that fails stays silent: lastError, not an error state', () async {
      publish(a, await release(keys));
      final u = updater();
      await u.check(manual: true);
      expect(u.status.phase, UpdatePhase.available);
      a.fail['manifest-stable.json'] = 500;
      final s = await u.check();
      expect(s.phase, UpdatePhase.available); // the offer stays
      expect(s.lastError!.code, UpdateError.network);
      a.fail.clear();
      expect((await u.check()).lastError, isNull);
    });

    test('a check joins a running one', () async {
      publish(a, await release(keys));
      final u = updater();
      final f1 = u.check(), f2 = u.check();
      await Future.wait([f1, f2]);
      expect(a.hits.where((h) => h == 'manifest-stable.json'), hasLength(1));
    });
  });

  group('download', () {
    Future<AppUpdater> offered({Release? r, List<String>? feeds, int size = 200000}) async {
      r ??= await release(keys, size: size);
      publish(a, r);
      final u = updater(feeds: feeds);
      await u.check(manual: true);
      expect(u.status.phase, UpdatePhase.available);
      return u;
    }

    test('downloads, verifies size and sha256, reports progress, leaves a ready file', () async {
      final r = await release(keys, size: 300000);
      publish(a, r);
      final events = <String>[];
      final u2 = updater(onEvent: (t, l, d) => events.add(t));
      final seen = <int>[];
      final sub = u2.changes.listen((s) {
        if (s.phase == UpdatePhase.downloading) seen.add(s.received);
      });
      await u2.check();
      final s = await u2.download();
      await sub.cancel();
      expect(s.phase, UpdatePhase.ready);
      expect(File(s.file!).readAsBytesSync(), r.installer);
      expect(p.basename(s.file!), r.file);
      expect(File('${s.file}.part').existsSync(), isFalse);
      expect(events, ['updateAvailable', 'updateDownloaded']);
      expect(seen, isNotEmpty);
      expect(seen.last, 300000);
      expect(seen, orderedEquals([...seen]..sort()));
      // downloading again is a no-op
      expect((await u2.download()).phase, UpdatePhase.ready);
    });

    test('sha256 mismatch: failed, nothing left on disk, other address tried first', () async {
      final r = await release(keys, size: 50000, urls: ['http://127.0.0.1:${b.port}/feed/bad.apk', 'http://127.0.0.1:${a.port}/feed/jormungand-0.2.0-android-arm64-v8a.apk']);
      b.files['bad.apk'] = noise(50000); // right size, wrong content
      final u = await offered(r: r);
      final s = await u.download();
      expect(s.phase, UpdatePhase.ready, reason: 'the second address is the real one');
      expect(File(s.file!).readAsBytesSync(), r.installer);
      expect(File(p.join(u.dir.path, 'bad.apk')).existsSync(), isFalse);

      // only the bad address: failed with a hash error, nothing kept
      final r2 = await release(keys, version: '0.4.0', build: 4, size: 50000, urls: ['http://127.0.0.1:${b.port}/feed/bad2.apk']);
      b.files['bad2.apk'] = noise(50000);
      publish(a, r2, installer: false);
      final u2 = updater();
      await u2.check(manual: true);
      final f = await u2.download();
      expect(f.phase, UpdatePhase.failed);
      expect(f.error!.code, UpdateError.hash);
      expect(f.offer, isNotNull);
      final left = Directory(u2.dir.path).listSync().map((e) => p.basename(e.path)).where((n) => n.contains('0.4.0')).toList();
      expect(left, isEmpty);
    });

    test('a file longer than announced is refused and dropped', () async {
      final r = await release(keys, size: 40000);
      a.files[r.file] = [...r.installer, ...noise(100)];
      publish(a, r, installer: false);
      final u = updater();
      await u.check(manual: true);
      final s = await u.download();
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.size);
      expect(Directory(u.dir.path).listSync().where((e) => e.path.endsWith('.part')), isEmpty);
    });

    test('a cut connection leaves a .part, the next try resumes it with Range', () async {
      final r = await release(keys, size: 100000);
      final u = await offered(r: r);
      a.cutAfter = 30000;
      var s = await u.download();
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.network);
      final part = File(p.join(u.dir.path, '${r.file}.part'));
      expect(part.existsSync(), isTrue);
      expect(part.lengthSync(), 30000);
      a.cutAfter = null;
      a.ranges.clear();
      s = await u.download();
      expect(s.phase, UpdatePhase.ready);
      expect(File(s.file!).readAsBytesSync(), r.installer);
      expect(a.ranges.single, 'bytes=30000-');
    });

    test('a server that ignores Range sends the whole file: start over', () async {
      final r = await release(keys, size: 80000);
      final u = await offered(r: r);
      File(p.join(u.dir.path, '${r.file}.part'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(r.installer.sublist(0, 20000));
      a.ignoreRange = true;
      final s = await u.download();
      expect(s.phase, UpdatePhase.ready);
      expect(File(s.file!).readAsBytesSync(), r.installer);
    });

    test('a .part with garbage of the right prefix length fails the hash and is dropped', () async {
      final r = await release(keys, size: 60000);
      final u = await offered(r: r);
      File(p.join(u.dir.path, '${r.file}.part'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(noise(10000)); // not the file's start
      var s = await u.download();
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.hash);
      expect(File(p.join(u.dir.path, '${r.file}.part')).existsSync(), isFalse);
      s = await u.download(); // from scratch now
      expect(s.phase, UpdatePhase.ready);
    });

    test('a .part bigger than the file is discarded', () async {
      final r = await release(keys, size: 30000);
      final u = await offered(r: r);
      File(p.join(u.dir.path, '${r.file}.part'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(noise(50000));
      expect((await u.download()).phase, UpdatePhase.ready);
    });

    test('relative addresses and the tunnel route for the file', () async {
      final r = await release(keys, size: 20000, urls: ['files/x.apk']);
      publish(b, r, installer: false);
      a.files['files/x.apk'] = noise(20000); // wrong content on the first feed
      b.files['files/x.apk'] = r.installer;
      net.blockedDirect.add(b.port);
      tunnel = true;
      final u = updater(feeds: [a.base, b.base]);
      await u.check(manual: true);
      expect(u.status.offer!.feed, b.base);
      expect(u.status.offer!.route, UpdateRoute.tunnel);
      net.calls.clear();
      final s = await u.download();
      expect(s.phase, UpdatePhase.ready);
      // the manifest came through the tunnel, so the file is asked that way first: the
      // manifest's own feed (b) first, then a (wrong content, hash refused)
      expect(net.calls.first, startsWith('tunnel:${b.port}'));
    });

    test('cancel keeps the part and goes back to available', () async {
      final r = await release(keys, size: 500000);
      final u = await offered(r: r);
      u.changes.listen((s) {
        if (s.phase == UpdatePhase.downloading && s.received > 0) u.cancelDownload();
      });
      final s = await u.download();
      expect(s.phase, UpdatePhase.available);
      expect(s.offer, isNotNull);
    });

    test('download with nothing offered', () async {
      expect(updater().download(), throwsA(isA<UpdateException>()));
    });

    test('a disk that cannot be written -> disk error', () async {
      final r = await release(keys, size: 10000);
      publish(a, r);
      File(p.join(tmp.path, 'updates')).writeAsStringSync('a file where the folder should be');
      final u = updater();
      await u.check(manual: true);
      final s = await u.download();
      expect(s.phase, UpdatePhase.failed);
      expect(s.error!.code, UpdateError.disk);
    });
  });

  group('after a restart', () {
    test('a downloaded file is picked up again (re-verified); a damaged one is dropped', () async {
      final r = await release(keys, size: 50000);
      publish(a, r);
      final u = updater();
      await u.check(manual: true);
      final done = await u.download();
      expect(done.phase, UpdatePhase.ready);

      final again = updater();
      expect(await again.reconcile(), InstallOutcome.none);
      final s = await again.restore();
      expect(s.phase, UpdatePhase.ready);
      expect(s.file, done.file);
      expect(s.offer!.version.toString(), '0.2.0+2');
      expect(s.offer!.asset.sha256, r.manifest.assets.values.first.sha256);

      File(done.file!).writeAsBytesSync(noise(50000));
      final broken = await updater().restore();
      expect(broken.phase, UpdatePhase.idle);
      expect(File(done.file!).existsSync(), isFalse);
    });

    test('a file for a version that is not newer is dropped', () async {
      publish(a, await release(keys, size: 20000));
      final u = updater();
      await u.check(manual: true);
      await u.download();
      final s = await updater(current: '0.2.0+2').restore();
      expect(s.phase, UpdatePhase.idle);
      expect(Directory(u.dir.path).listSync().where((e) => e.path.endsWith('.apk')), isEmpty);
    });

    test('install reconcile: reached the target -> installed + cleanup; still old -> failed, file kept', () async {
      publish(a, await release(keys, size: 20000));
      final events = <String>[];
      final u = updater(onEvent: (t, l, d) => events.add('$t/${d['stage'] ?? ''}'));
      await u.check(manual: true);
      await u.download();
      await u.beginInstall();

      // the app came back as the old version
      final stuck = updater(onEvent: (t, l, d) => events.add('$t/${d['stage'] ?? ''}'));
      expect(await stuck.reconcile(), InstallOutcome.failed);
      expect(await stuck.reconcile(), InstallOutcome.none); // reported once
      expect((await stuck.restore()).phase, UpdatePhase.ready); // the file is still there for a retry
      expect(events.last, 'updateFailed/install');

      await stuck.beginInstall();
      final fresh = updater(current: '0.2.0+2', onEvent: (t, l, d) => events.add(t));
      expect(await fresh.reconcile(), InstallOutcome.installed);
      expect(events.last, 'updateInstalled');
      expect((await fresh.restore()).phase, UpdatePhase.idle);
      expect(Directory(u.dir.path).listSync().whereType<File>().map((f) => p.basename(f.path)), ['state.json']);
    });

    test('beginInstall needs a downloaded file; installFailed is journalled and clears the mark', () async {
      final u = updater();
      expect(u.beginInstall(), throwsA(isA<UpdateException>()));
      publish(a, await release(keys, size: 20000));
      final events = <String>[];
      final u2 = updater(onEvent: (t, l, d) => events.add('$t/${d['error']}'));
      await u2.check(manual: true);
      await u2.download();
      await u2.beginInstall();
      await u2.installFailed('user declined');
      expect(events.last, 'updateFailed/user declined');
      expect(await updater().reconcile(), InstallOutcome.none);
    });

    test('the time of the last check survives', () async {
      publish(a, await release(keys));
      final u = updater();
      await u.check();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final n = updater();
      await n.restore();
      expect(n.status.checkedAt, u.status.checkedAt);
    });
  });

  group('schedule', () {
    test('first check after the delay, then every 24 h; off = skipped; stop = stopped', () async {
      publish(a, await release(keys));
      final timers = <(Duration, void Function())>[];
      var on = true;
      final u = updater();
      u.startSchedule(
          autoCheck: () => on,
          channel: () => UpdateChannel.stable,
          timer: (d, f) {
            timers.add((d, f));
            return Timer(const Duration(days: 1), () {}); // never fires: the test calls it
          });
      expect(timers.single.$1, const Duration(seconds: 10));
      timers.single.$2();
      await pumpEventQueue(times: 200);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(u.status.phase, UpdatePhase.available);
      expect(timers, hasLength(2));
      expect(timers.last.$1, const Duration(hours: 24));

      a.hits.clear();
      on = false;
      timers.last.$2();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(a.hits, isEmpty);
      expect(timers, hasLength(3));

      u.stopSchedule();
      await u.dispose();
    });
  });

  group('http', () {
    test('httpUpdateGet: tunnel goes through the proxy port, no tunnel fails at once, Range is sent', () async {
      final body = noise(5000);
      a.files['f.bin'] = body;
      // a loopback forward proxy: remembers what it forwarded
      final seen = <String>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      proxy.listen((req) async {
        seen.add(req.uri.toString());
        final c = HttpClient()..findProxy = ((_) => 'DIRECT');
        final up = await c.getUrl(req.uri);
        final ur = await up.close();
        req.response.statusCode = ur.statusCode;
        await ur.pipe(req.response);
        c.close();
      });
      int? port = proxy.port;
      final get = httpUpdateGet(proxyPort: () => port);
      final target = a.url('f.bin');

      final viaTunnel = await get(target, UpdateRoute.tunnel);
      final got = BytesBuilder();
      await viaTunnel.body.forEach(got.add);
      viaTunnel.onClose?.call();
      expect(got.takeBytes(), body);
      expect(seen, [target.toString()]);

      final direct = await get(target, UpdateRoute.direct, rangeFrom: 1000);
      expect(direct.status, 206);
      expect(a.ranges.last, 'bytes=1000-');
      direct.onClose?.call();
      expect(seen, hasLength(1));

      port = null;
      await expectLater(get(target, UpdateRoute.tunnel), throwsA(isA<SocketException>()));
      await proxy.close(force: true);
    });
  });
}
