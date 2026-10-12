// planCheckers (config.dart): the backup check URLs a plan asks for.
import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

void main() {
  group('tunCheckRule in buildConfig', () {
    Map<String, dynamic> plan(String mode) => {
          'kind': 'unit',
          'mode': mode,
          'main': {
            'pick': 'priority',
            'chosen': 'k::0',
            'nodes': [
              {'key': 'k::0', 'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'}},
            ],
          },
        };
    List<Map> rules(Map<String, dynamic> cfg) => ((cfg['route'] as Map)['rules'] as List).cast<Map>();

    test('TUN with a port: the rule stands right after the tunnel-in rule, before the self rules, with exact fields', () {
      final r = rules(buildConfig(plan('tun'), tunnelPort: 7001, tunCheckPort: 45678, selfPackages: ['dev.jormungand.app']));
      final i = r.indexWhere((x) => x['override_port'] == 45678);
      expect(i, greaterThan(0));
      expect(r[i], {
        'inbound': ['tun-in'],
        'ip_cidr': ['192.0.2.251/32'],
        'port': [44251],
        'network': ['tcp'],
        'action': 'route',
        'outbound': 'direct',
        'override_address': '127.0.0.1',
        'override_port': 45678,
      });
      expect(r[i - 1]['inbound'], ['tunnel-in'], reason: 'right after tunnelRule');
      final self = r.indexWhere((x) => x['package_name'] != null);
      expect(self, greaterThan(i), reason: 'ahead of the self rules');
    });

    test('TUN without a port: no rule', () {
      final r = rules(buildConfig(plan('tun'), tunnelPort: 7001));
      expect(r.where((x) => x['override_port'] != null), isEmpty);
    });

    test('not TUN: no rule even with a port', () {
      final r = rules(buildConfig(plan('proxy'), tunnelPort: 7001, tunCheckPort: 45678));
      expect(r.where((x) => x['override_port'] != null), isEmpty);
    });
  });

  group('planCheckers', () {
    test('missing everywhere: defaultCheckers', () {
      expect(planCheckers({}), defaultCheckers);
    });

    test('auto.checkers []: none, even if urlTest.checkers has some', () {
      expect(planCheckers({
        'auto': {'checkers': []},
        'urlTest': {
          'checkers': ['https://a.example/'],
        },
      }), isEmpty);
    });

    test('auto.checkers wins over urlTest.checkers when both are set', () {
      expect(
          planCheckers({
            'auto': {
              'checkers': ['https://a.example/'],
            },
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          ['https://a.example/']);
    });

    test('no auto.checkers: falls back to urlTest.checkers', () {
      expect(
          planCheckers({
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          ['https://b.example/']);
    });

    test('urlTest.checkers []: none', () {
      expect(
          planCheckers({
            'urlTest': {'checkers': []},
          }),
          isEmpty);
    });

    test('non-string and empty entries are dropped, from either key', () {
      expect(
          planCheckers({
            'auto': {
              'checkers': ['https://a.example/', 42, '', null, 'https://b.example/'],
            },
          }),
          ['https://a.example/', 'https://b.example/']);
    });

    test('auto.checkers present but not a list: defaultCheckers (?? does not fall through to urlTest)', () {
      expect(
          planCheckers({
            'auto': {'checkers': 'oops'},
            'urlTest': {
              'checkers': ['https://b.example/'],
            },
          }),
          defaultCheckers);
    });
  });

  test('AutoSettings.fromPlan reads checkers via planCheckers', () {
    final a = AutoSettings.fromPlan({
      'auto': {
        'checkers': ['https://a.example/'],
      },
    });
    expect(a.checkers, ['https://a.example/']);

    final b = AutoSettings.fromPlan({});
    expect(b.checkers, defaultCheckers);
  });
}
