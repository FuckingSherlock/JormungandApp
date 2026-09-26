// The rule-set cache: download order and fallback, freshness, refusing a page that is not a
// rule set, lists via VPN only through the tunnel port, retry back-off. Loopback only: the
// "sources" and the "tunnel" are local HTTP servers.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _srs = [0x53, 0x52, 0x53, 0x01, 0x78, 0x9c];

void main() {
  late Directory tmp;
  late HttpServer origin, tunnel;
  late List<String> hits, tunnelHits;
  var body = <String, List<int>>{};

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jorm-rs');
    hits = [];
    tunnelHits = [];
    body = {
      '/rf/a.srs': [..._srs, 1],
      '/sn/b.srs': [..._srs, 2],
      '/page.srs': utf8.encode('<html>blocked</html>'),
      '/set.json': utf8.encode(
        jsonEncode({
          'version': 2,
          'rules': [
            {
              'domain_suffix': ['x.test'],
            },
          ],
        }),
      ),
    };
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((r) {
      hits.add(r.uri.path);
      final b = body[r.uri.path];
      r.response.statusCode = b == null ? 404 : 200;
      if (b != null) r.response.add(b);
      r.response.close();
    });
    // a "tunnel": a proxy that answers every request itself
    tunnel = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    tunnel.listen((r) {
      tunnelHits.add('${r.uri}');
      r.response.add([..._srs, 9]);
      r.response.close();
    });
  });

  tearDown(() async {
    await origin.close(force: true);
    await tunnel.close(force: true);
    await tmp.delete(recursive: true);
  });

  String url(String path) => 'http://127.0.0.1:${origin.port}$path';
  RuleSetSource set(String tag, List<String> paths, {bool vpn = false, bool binary = true, Duration every = const Duration(days: 1)}) =>
      RuleSetSource(tag, [for (final x in paths) url(x)], viaVpn: vpn, binary: binary, every: every);

  test('missing: downloaded, a 404 moves to the next URL, a fresh copy is not asked again', () async {
    final cache = RuleSetCache(tmp.path);
    final sets = [
      set('geosite-a', ['/rf/a.srs']),
      set('geosite-b', ['/rf/b.srs', '/sn/b.srs']),
      set('set-j', ['/set.json'], binary: false),
    ];
    final r = await cache.ensure(sets);
    expect(r.errors, isEmpty);
    expect(r.pending, isEmpty);
    expect(r.files.keys, unorderedEquals(['geosite-a', 'geosite-b', 'set-j']));
    expect(p.extension(r.files['set-j']!), '.json');
    expect(File(r.files['geosite-b']!).readAsBytesSync().last, 2);
    expect(hits, unorderedEquals(['/rf/a.srs', '/rf/b.srs', '/sn/b.srs', '/set.json']));
    hits.clear();
    await cache.ensure(sets, refresh: true);
    expect(hits, isEmpty, reason: 'fresh lists stay');
  });

  test('stale: used as is at connect, replaced on refresh', () async {
    var now = DateTime.now();
    final cache = RuleSetCache(tmp.path, now: () => now);
    final s = set('geosite-a', ['/rf/a.srs'], every: const Duration(hours: 1));
    await cache.ensure([s]);
    body['/rf/a.srs'] = [..._srs, 7];
    now = now.add(const Duration(hours: 2));
    hits.clear();
    final r = await cache.ensure([s]);
    expect(hits, isEmpty);
    expect(r.files, contains('geosite-a'));
    await cache.ensure([s], refresh: true);
    expect(File(r.files['geosite-a']!).readAsBytesSync().last, 7);
  });

  test('a page that is not a rule set is refused and never replaces a good copy', () async {
    var now = DateTime.now();
    final cache = RuleSetCache(tmp.path, now: () => now, retryAfter: Duration.zero);
    final bad = await cache.ensure([
      set('geosite-p', ['/page.srs']),
    ]);
    expect(bad.pending, ['geosite-p']);
    expect(bad.errors.single, contains('not a sing-box binary rule set'));
    final s = set('geosite-a', ['/rf/a.srs'], every: const Duration(hours: 1));
    await cache.ensure([s]);
    body['/rf/a.srs'] = utf8.encode('<html>captive portal</html>');
    now = now.add(const Duration(hours: 2));
    final r = await cache.ensure([s], refresh: true);
    expect(r.errors, hasLength(1));
    expect(File(r.files['geosite-a']!).readAsBytesSync().last, 1);
    final json = await cache.ensure([
      set('set-bad', ['/rf/a.srs'], binary: false),
    ]);
    expect(json.errors.single, contains('JSON rule set'));
  });

  test('via VPN: pending without a tunnel, then only through the tunnel port', () async {
    final cache = RuleSetCache(tmp.path);
    final s = set('geoip-ru', ['/rf/a.srs'], vpn: true);
    final before = await cache.ensure([s]);
    expect(before.pending, ['geoip-ru']);
    expect(before.errors, isEmpty);
    expect(hits, isEmpty);
    final after = await cache.ensure([s], proxyPort: tunnel.port);
    expect(after.files, contains('geoip-ru'));
    expect(hits, isEmpty, reason: 'never direct');
    expect(tunnelHits.single, endsWith('/rf/a.srs'));
    // a direct list ignores the tunnel
    await cache.ensure([
      set('geosite-a', ['/rf/a.srs']),
    ], proxyPort: tunnel.port);
    expect(hits, ['/rf/a.srs']);
    expect(tunnelHits, hasLength(1));
  });

  test('a failed list is not asked for again before retryAfter', () async {
    var now = DateTime.now();
    final cache = RuleSetCache(tmp.path, now: () => now, retryAfter: const Duration(minutes: 5));
    final s = set('geosite-x', ['/nope.srs']);
    expect((await cache.ensure([s])).errors.single, contains('not found'));
    expect((await cache.ensure([s])).errors, isEmpty);
    expect(hits, ['/nope.srs']);
    now = now.add(const Duration(minutes: 6));
    await cache.ensure([s]);
    expect(hits, ['/nope.srs', '/nope.srs']);
  });

  test('ensureFor: what the routing plan names; the tunnel inbound in the config', () async {
    final plan = {
      'kind': 'unit',
      'main': {
        'pick': 'fastest',
        'nodes': [
          {
            'key': 'k',
            'outbound': {'type': 'direct'},
          },
        ],
      },
      'routing': {
        'quick': {'region': 'RU', 'final': 'proxy'},
        'geo': {
          'geosite': {'via': 'direct', 'every': 3600},
          'geoip': {'via': 'vpn', 'every': 3600},
        },
      },
    };
    expect(ruleSetsNeeded(plan).map((s) => s.tag), containsAll(['geosite-category-ru', 'geoip-ru']));
    final c = buildConfig(plan, tunnelPort: 45678);
    expect((c['inbounds'] as List).last, containsPair('tag', 'tunnel-in'));
    expect(((c['route'] as Map)['rules'] as List)[1], {
      'inbound': ['tunnel-in'],
      'action': 'route',
      'outbound': 'proxy',
    });
    expect(joinWarnings(['a', '', 'a', 'b', 'c', 'd']), 'a; b; c; …and 1 more');
    expect(joinWarnings(['']), isNull);
  });
}
