// The appInfo of the support report (report_info.dart): what the app and the phone say about
// themselves, the plan's display names, the app's own settings — and nothing secret.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jormungand/core/report_info.dart';
import 'package:jormungand/core/settings_model.dart';
import 'package:jormungand_core/jormungand_core.dart';

import 'fake_core_host.dart';

CatalogNode _node(String id, String name) => CatalogNode(
  id: id,
  name: name,
  flag: '\u{1F1E9}\u{1F1EA}',
  protocol: 'vless',
  address: '$id.example.com',
  port: 443,
  outbound: {
    'type': 'vless',
    'server': '$id.example.com',
    'server_port': 443,
    'uuid': '11111111-2222-3333-4444-555555555555',
  },
);

FakeCoreHost _host({bool android = true}) {
  final host = FakeCoreHost(android: android);
  host.catalog.sourcesData['s1'] = Source(
    id: 's1',
    name: 'Alpha',
    url: 'https://alpha.example.com/sub?token=SECRETTOKEN123',
    nodes: [_node('a1', 'Alpha one'), _node('a2', 'Alpha two')],
  );
  host.catalog.sourceOrder = ['s1'];
  host.catalog.syncCatalog();
  return host;
}

void main() {
  const device = {
    'model': 'Pixel 7',
    'manufacturer': 'Google',
    'brand': 'google',
    'androidApi': 34,
    'androidRelease': '14',
  };

  ReportInfo info({
    Future<Map<String, dynamic>> Function()? dev,
    Future<bool> Function()? vpnUp,
    Future<String> Function()? net,
    Future<bool> Function()? metered,
  }) => ReportInfo(
    device: dev ?? () async => device,
    abis: () async => ['arm64-v8a', 'armeabi-v7a'],
    libbox: () async => '1.12.4',
    vpnUp: vpnUp ?? () async => true,
    networkType: net ?? () async => 'wifi',
    metered: metered ?? () async => false,
    now: () => DateTime.parse('2026-03-04T12:00:00+03:00'),
    systemLocale: () => 'ru-RU',
    timeout: const Duration(milliseconds: 200),
  );

  test('identity, device, platform facts and the reserved keys', () async {
    final host = _host();
    final m = await info().build(host);
    expect(m['version'], '0.1.0');
    expect(m['versionCode'], 7);
    expect(m['commit'], 'abc1234');
    expect(m['platform'], 'android');
    expect(m['androidApi'], 34);
    expect(m['androidRelease'], '14');
    expect(m['device'], {'model': 'Pixel 7', 'manufacturer': 'Google', 'brand': 'google'});
    expect(m['abis'], ['arm64-v8a', 'armeabi-v7a']);
    expect(m['locale'], 'ru-RU');
    expect(m['timezone'], isA<String>());
    expect(m['utcOffset'], matches(RegExp(r'^[+-]\d\d:\d\d$')));
    expect(m['libbox'], '1.12.4');
    expect(m['network'], {'type': 'wifi', 'vpnService': true, 'metered': false});
    expect(m['planSig'], isA<String>());
    expect((m['planSig'] as String), isNotEmpty);
  });

  test('the host\'s own plan signature wins over the catalog\'s', () async {
    final m = await info().build(_host(), planSig: 'running-sig');
    expect(m['planSig'], 'running-sig');
  });

  test('names: the plan\'s route and its servers by display name', () async {
    final host = _host();
    final m = await info().build(host);
    final names = (m['names'] as Map).cast<String, String>();
    expect(names['s1'], 'Alpha');
    expect(names['s1::a1'], 'Alpha one');
    expect(names['s1::a2'], 'Alpha two');
  });

  test('no plan to build: no names, the report still comes', () async {
    final host = FakeCoreHost(android: false);
    final m = await info(dev: () async => const {}).build(host);
    expect(m['names'], isEmpty);
    expect(m.containsKey('planSig'), isFalse);
    expect(m.containsKey('device'), isFalse);
    expect(m['platform'], isNot('android'));
  });

  test('a platform answer that never comes or throws costs only its field', () async {
    final m = await info(
      dev: () => Future<Map<String, dynamic>>.error(StateError('no channel')),
      vpnUp: () => Future<bool>.delayed(const Duration(seconds: 5), () => true),
      net: () async => throw StateError('x'),
    ).build(_host());
    expect(m.containsKey('device'), isFalse);
    expect((m['network'] as Map).containsKey('vpnService'), isFalse);
    expect((m['network'] as Map).containsKey('type'), isFalse);
    expect((m['network'] as Map)['metered'], false);
    expect(m['version'], '0.1.0');
  });

  test('settings: the look, the language, the toggles — and no credentials', () async {
    final host = _host();
    host.gen
      ..lang = 'ru'
      ..theme = 'github'
      ..uiScale = 1.15
      ..connectOnLaunch = true
      ..updChannel = 'beta';
    host.notif.setFlag('subUpdated', true);
    host.catalog.connCfg
      ..proxyAuth = true
      ..proxyUser = 'localuser'
      ..proxyPass = 'localpass-777';
    final m = await info().build(host);
    final s = m['settings'] as Map;
    expect(s['language'], 'ru');
    expect(s['theme'], 'github');
    expect(s['textScale'], 1.15);
    expect(s['connectOnLaunch'], true);
    expect(s['updChannel'], 'beta');
    expect((s['notifications'] as Map)['subUpdated'], true);
    expect(s.containsKey('launchAtStartup'), isFalse, reason: 'desktop-only on Android');

    // the plan signature is the catalog's own string, local proxy login included: the core puts only
    // a 12-hex digest of it into the report (report.dart), so it is the one value that may carry it
    final text = jsonEncode({...m}..remove('planSig'));
    for (final bad in ['SECRETTOKEN123', 'localuser', 'localpass-777', '11111111-2222-3333-4444-555555555555']) {
      expect(text, isNot(contains(bad)), reason: bad);
    }
  });

  test('appSettings does not create the slots in the catalog', () {
    final host = _host();
    expect(host.catalog.unknown.containsKey('genCfg'), isFalse);
    appSettings(host);
    expect(host.catalog.unknown.containsKey('genCfg'), isFalse);
    expect(host.catalog.unknown.containsKey('notifCfg'), isFalse);
  });
}
