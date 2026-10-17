// TUN mode (docs/core.md → «TUN»): the config the builder makes for plan.mode == 'tun', checked
// by sing-box's own `check` (which does not create the interface), and the daemon refusing a TUN
// connect when it is not elevated. No test here brings a TUN up: the host's traffic is not ours.
import 'dart:convert';
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fixtures.dart';

final _bin = p.join('tool', 'bin', Platform.isWindows ? 'sing-box.exe' : 'sing-box');
final _skip = File(_bin).existsSync() ? false : 'no sing-box in tool/bin';

final _node = parseLink(ssSip002)!.outbound;

Map<String, dynamic> _grp(Map outbound) => {
      'pick': 'fastest',
      'chosen': null,
      'nodes': [
        {'key': 's::0', 'outbound': outbound},
      ],
    };

Map<String, dynamic> _plan({String? mode = 'tun', bool global = false, String? stack, bool? ipv6, Map<String, dynamic>? routing}) => {
      'kind': 'unit',
      'main': _grp(_node),
      'global': global,
      'mode': ?mode,
      'tunStack': ?stack,
      'ipv6': ?ipv6,
      'routing': ?routing,
    };

Map<String, dynamic> _rule(String id, Map<String, List<String>> domain, {String action = 'proxy', Map<String, List<String>>? ip, bool ipTunOnly = false}) => {
      'id': id,
      'name': id,
      'action': action,
      'target': '',
      'fallback': 'default',
      'block': 'drop',
      'dns': 'auto',
      if (ipTunOnly) 'ipTunOnly': true,
      'groups': {
        'domain': {'not': false, 'v': domain},
        if (ip != null) 'ip': {'not': false, 'v': ip},
      },
    };

Map<String, dynamic> _routing({bool? hijack, List<Map>? rules, List<Map>? apps, Map<String, dynamic>? quick}) => {
      'apps': apps ?? [],
      'rules': rules ?? [],
      'quick': quick ?? {'final': 'proxy'},
      'targets': {},
      'dns': {
        'servers': [
          {'id': 'remote', 'addr': 'https://1.1.1.1/dns-query', 'via': 'vpn', 'on': true},
          {'id': 'local', 'addr': 'system', 'via': 'direct', 'on': true},
        ],
        'hijack': ?hijack,
      },
    };

List<Map> _rules(Map<String, dynamic> c) => ((c['route'] as Map)['rules'] as List).cast<Map>();
List<Map> _inbounds(Map<String, dynamic> c) => (c['inbounds'] as List).cast<Map>();
Map? _tun(Map<String, dynamic> c) => _inbounds(c).where((i) => i['type'] == 'tun').firstOrNull;
bool _isHijack(Map r) => r['action'] == 'hijack-dns';
bool _isSelf(Map r) => r.containsKey('process_path') || r.containsKey('process_path_regex');

Map<String, dynamic> _build(Map<String, dynamic> plan,
        {List<String> self = const [r'C:\Apps\dart.exe', r'C:\Tools\sing-box.exe'], List<String> packages = const [], int? tunnelPort = 40001, RoutingInfo? info}) =>
    buildConfig(plan, tunnelPort: tunnelPort, selfPaths: self, selfPackages: packages, info: info);

const _pkg = 'dev.jormungand.app';
bool _isSelfPackage(Map r) => r.containsKey('package_name') && r['outbound'] == 'direct' && '${r['package_name']}' == '[$_pkg]';
List<Map> _dnsRules(Map<String, dynamic> c) => (((c['dns'] as Map)['rules'] as List?) ?? const []).cast<Map>();

void main() {
  group('the tun inbound', () {
    test('tun mode with IPv6 on: dual stack, strict routes, LAN excluded, the default stack mixed', () {
      final t = _tun(_build(_plan(ipv6: true)))!;
      expect(t, {
        'type': 'tun',
        'tag': 'tun-in',
        'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'mtu': 9000,
        'auto_route': true,
        'strict_route': true,
        'stack': 'mixed',
        'route_exclude_address': tunBypass,
      });
      expect(tunBypass, containsAll(['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', 'fc00::/7', 'fe80::/10']));
      expect(t.keys, isNot(contains('inet4_address')), reason: '1.14 syntax: address, not the legacy fields');
      expect(t.keys, isNot(contains('sniff')), reason: 'sniffing is a route rule');
    });

    test('IPv6 off (the default, also when the plan has no ipv6): the TUN stays dual stack, IPv6 entering it is rejected, DNS answers no AAAA', () {
      for (final plan in [_plan(), _plan(ipv6: false)]) {
        final c = _build(plan);
        final t = _tun(c)!;
        expect(t['address'], tunAddress, reason: 'the ::/0 route stays: IPv6 literals must not leave past the VPN');
        expect(t['route_exclude_address'], tunBypass);
        expect((c['dns'] as Map)['strategy'], 'ipv4_only');
        final rules = _rules(c);
        expect(rules.where((r) => r['action'] == 'reject').toList(), [
          {'inbound': ['tun-in'], 'ip_version': 6, 'action': 'reject', 'no_drop': true},
        ]);
        // after sniff and the DNS hijack (DNS to the tunnel's IPv6 resolver is still answered), before the rest
        final reject = rules.indexWhere((r) => r['action'] == 'reject');
        expect(reject, greaterThan(rules.indexWhere((r) => r['action'] == 'sniff')));
        expect(reject, greaterThan(rules.lastIndexWhere(_isHijack)));
        expect(reject, lessThan(rules.indexWhere((r) => r['ip_is_private'] == true)), reason: 'before Private networks and the user rules');
      }
    });

    test('IPv6 on: today\'s dual stack, no reject rule, no DNS strategy; proxy mode takes the DNS strategy only', () {
      final c = _build(_plan(ipv6: true, routing: _routing(hijack: false)));
      expect((c['dns'] as Map).containsKey('strategy'), isFalse);
      expect(_rules(c).where((r) => r['action'] == 'reject'), isEmpty);
      expect(_rules(c).where(_isHijack).single['ip_cidr'], tunDnsAddress);
      expect((_build(_plan(mode: 'proxy', ipv6: true))['dns'] as Map).containsKey('strategy'), isFalse);
      final off = _build(_plan(mode: 'proxy'));
      expect((off['dns'] as Map)['strategy'], 'ipv4_only', reason: 'proxy clients get no AAAA either');
      expect(_tun(off), isNull);
      expect(_rules(off).where((r) => r['action'] == 'reject'), isEmpty, reason: 'the reject rule is the TUN\'s');
    });

    test('plan.tunStack picks the stack; an unknown one is mixed', () {
      for (final s in ['mixed', 'system', 'gvisor']) {
        expect(_tun(_build(_plan(stack: s)))!['stack'], s);
      }
      expect(_tun(_build(_plan(stack: 'wireguard')))!['stack'], 'mixed');
    });

    test('apps set to Direct as a whole (packages, Rules mode) are left out of the tunnel (exclude_package)', () {
      Map<String, dynamic> app(String id, String act, {String kind = 'package', bool split = false, String udp = 'default'}) => {
            'id': id,
            'kind': kind,
            'name': id,
            'act': act,
            'target': '',
            'fallback': 'default',
            'split': split,
            'udp': {'act': udp, 'target': '', 'fallback': 'default'},
          };
      final apps = [
        app('com.bank', 'direct'),
        app('com.chat', 'proxy'),
        app('com.split.half', 'direct', split: true), // UDP stays Default: not whole
        app('com.split.both', 'direct', split: true, udp: 'direct'),
        app('chrome.exe', 'direct', kind: 'process'),
        app('com.dflt', 'default'),
      ];
      final t = _tun(_build(_plan(routing: _routing(apps: apps))))!;
      expect(t['exclude_package'], ['com.bank', 'com.split.both']);
      expect(_tun(_build(_plan(global: true, routing: _routing(apps: apps))))!.containsKey('exclude_package'), isFalse, reason: 'Global ignores apps');
      expect(_tun(_build(_plan()))!.containsKey('exclude_package'), isFalse);
    });

    test('proxy mode (or no mode): no tun inbound, no hijack rule; mixed-in stays in both', () {
      for (final mode in [null, 'proxy']) {
        final c = _build(_plan(mode: mode));
        expect(_tun(c), isNull);
        expect(_rules(c).where(_isHijack), isEmpty);
      }
      expect(_inbounds(_build(_plan())).any((i) => i['tag'] == 'mixed-in'), isTrue);
    });

    test('route: sniff, auto_detect_interface and find_process on', () {
      final route = _build(_plan())['route'] as Map;
      expect(route['auto_detect_interface'], true);
      expect(route['find_process'], true);
      expect((route['rules'] as List).cast<Map>().any((r) => r['action'] == 'sniff'), isTrue);
    });
  });

  group('system rules', () {
    test('the core and the sing-box binary go direct, after sniff and tunnel-in, before the user rules', () {
      final plan = _plan(routing: _routing(rules: [_rule('r1', {'domain_suffix': ['a.example']})]));
      final rules = _rules(_build(plan));
      final self = rules.indexWhere(_isSelf), tunnel = rules.indexWhere((r) => (r['inbound'] as List?)?.contains('tunnel-in') == true);
      final sniff = rules.indexWhere((r) => r['action'] == 'sniff');
      final private = rules.indexWhere((r) => r['ip_is_private'] == true), user = rules.indexWhere((r) => r['domain_suffix']?.toString() == '[a.example]');
      expect([sniff, tunnel, self, private, user].every((i) => i >= 0), isTrue, reason: '$rules');
      expect(sniff < tunnel && tunnel < self && self < private && private < user, isTrue, reason: 'order: sniff, tunnel-in, self, private, user');
      expect(rules[self]['action'], 'route');
      expect(rules[self]['outbound'], 'direct');
      final field = rules[self].containsKey('process_path_regex') ? 'process_path_regex' : 'process_path';
      expect(field, Platform.isWindows ? 'process_path_regex' : 'process_path');
      final vals = (rules[self][field] as List).cast<String>();
      expect(vals, hasLength(2));
      if (Platform.isWindows) {
        // case-insensitive, anchored, escaped
        expect(vals.first, startsWith('(?i)^'));
        RegExp go(String s) => RegExp(s.substring(4), caseSensitive: false); // (?i) is Go's flag
        expect(go(vals.first).hasMatch(r'c:\apps\DART.exe'), isTrue);
        expect(go(vals.last).hasMatch(r'C:\Tools\sing-box.exe'), isTrue);
        expect(go(vals.last).hasMatch(r'C:\Tools\sing-box.exe.evil'), isFalse);
      } else {
        expect(vals, ['C:\\Apps\\dart.exe', 'C:\\Tools\\sing-box.exe']);
      }
    });

    test('also in proxy mode and in Global', () {
      for (final plan in [_plan(mode: 'proxy'), _plan(global: true)]) {
        expect(_rules(_build(plan)).where(_isSelf), hasLength(1));
      }
    });

    test('selfProcessPaths: this process and the sing-box file; a missing file is left out', () {
      expect(selfProcessPaths('nothing-here'), [Platform.resolvedExecutable]);
      if (File(_bin).existsSync()) {
        final paths = selfProcessPaths(_bin);
        expect(paths, hasLength(2));
        expect(paths.last.toLowerCase(), endsWith('sing-box${Platform.isWindows ? '.exe' : ''}'));
        expect(File(paths.last).existsSync(), isTrue);
      }
    });

    test('Android: no self paths, so no process_path rule (resolvedExecutable is the shared app_process64); the package is the rule', () {
      expect(selfProcessPaths(_bin, android: true), isEmpty);
      final paths = selfProcessPaths(_bin, android: true), packages = selfPackageNames(package: _pkg, android: true);
      expect(packages, [_pkg]);
      final plan = _plan(routing: _routing(rules: [_rule('r1', {'domain_suffix': ['a.example']})]));
      final c = buildConfig(plan, tunnelPort: 40001, selfPaths: paths, selfPackages: packages);
      final rules = _rules(c);
      expect(rules.where(_isSelf), isEmpty);
      expect(rules.any((r) => r.containsKey('process_path') || r.containsKey('process_path_regex')), isFalse);
      expect(rules.where(_isSelfPackage).single, {'package_name': [_pkg], 'action': 'route', 'outbound': 'direct'});
      // the same place as the desktop's rule: after sniff and tunnel-in, before the LAN rule and the user's
      final self = rules.indexWhere(_isSelfPackage), tunnel = rules.indexWhere((r) => (r['inbound'] as List?)?.contains('tunnel-in') == true);
      final sniff = rules.indexWhere((r) => r['action'] == 'sniff');
      final private = rules.indexWhere((r) => r['ip_is_private'] == true), user = rules.indexWhere((r) => r['domain_suffix']?.toString() == '[a.example]');
      expect(sniff < tunnel && tunnel < self && self < private && private < user, isTrue, reason: '$rules');
      // Global and proxy mode keep it too; a platform without a package or a path has none
      for (final p in [_plan(global: true), _plan(mode: 'proxy')]) {
        final g = buildConfig(p, tunnelPort: 40001, selfPackages: packages);
        expect(_rules(g).where(_isSelfPackage), hasLength(1));
        expect(_rules(g).where(_isSelf), isEmpty);
      }
      expect(_rules(buildConfig(_plan(), tunnelPort: 40001)).any((r) => r['outbound'] == 'direct' && (r.containsKey('package_name') || _isSelf(r))), isFalse);
    });

    test('desktop: process rules only, no package rule; selfPackageNames is empty off Android', () {
      expect(selfPackageNames(package: _pkg, android: false), isEmpty);
      final rules = _rules(_build(_plan(), packages: selfPackageNames(package: _pkg, android: false)));
      expect(rules.where(_isSelf), hasLength(1));
      expect(rules.any((r) => r.containsKey('package_name')), isFalse);
      expect(_dnsRules(_build(_plan())).where((r) => r.containsKey('process_path') || r.containsKey('process_path_regex')), hasLength(1));
    });

    test('the self rules come from selfRules: package and paths side by side are two rules, none is none', () {
      expect(selfRules(), isEmpty);
      final both = selfRules(paths: [r'C:\x.exe'], packages: [_pkg]);
      expect(both, hasLength(2));
      expect(both.where((r) => r.containsKey('package_name')), hasLength(1));
      expect(both.every((r) => r['action'] == 'route' && r['outbound'] == 'direct'), isTrue);
    });

    test('the own package is read from the process name when the platform does not say; an explicit one wins', () {
      expect(selfPackageNames(package: 'a.b', android: true), ['a.b']);
      expect(selfPackageNames(package: '', android: false), isEmpty);
      // off Android (this machine) /proc/self/cmdline is not a package name: nothing is guessed
      final read = selfPackageNames(android: true);
      expect(read.length <= 1, isTrue);
      for (final p in read) {
        expect(RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$').hasMatch(p), isTrue);
      }
    });

    test('registered as system rules in the rule names', () {
      final info = RoutingInfo();
      final c = _build(_plan(), info: info);
      final rules = _rules(c);
      expect(info.ruleNames.of(ruleText(rules.firstWhere(_isSelf))!)?.id, 'core');
      expect(info.ruleNames.of(ruleText(rules.firstWhere(_isHijack))!)?.id, 'dns-hijack');
      expect(info.ruleNames.of(ruleText(rules.firstWhere(_isSelf))!)?.kind, 'system');
    });
  });

  group('user rules in TUN (Rules mode)', () {
    final routing = _routing(
      apps: [
        {'id': 'steam.exe', 'kind': 'process', 'name': 'Steam', 'act': 'direct', 'target': '', 'fallback': 'default', 'split': false},
        {'id': 'bad.exe', 'kind': 'process', 'name': 'Bad', 'act': 'block', 'target': '', 'fallback': 'default', 'split': false},
        {'id': 'tor.exe', 'kind': 'process', 'name': 'Tor', 'act': 'proxy', 'target': '', 'fallback': 'direct', 'split': false},
      ],
      rules: [
        _rule('direct-site', {'domain_suffix': ['bank.example']}, action: 'direct'),
        _rule('by-ip', {}, ip: {'ip_cidr': ['8.8.8.0/24']}),
        _rule('tun-ip', {}, ip: {'ip_cidr': ['9.9.9.0/24']}, action: 'direct', ipTunOnly: true),
        _rule('site-last', {'domain_suffix': ['site.example']}),
      ],
      quick: {'ads': false, 'region': null, 'services': {'telegram': 'direct'}, 'final': 'direct'},
    );

    test('apps (direct / block / proxy+fallback), own rules, services, final: present, in the order of the proxy mode', () {
      final tun = _build(_plan(routing: routing)), proxy = _build(_plan(mode: 'proxy', routing: routing));
      List<String> after(Map<String, dynamic> c) {
        final r = _rules(c);
        // the TUN's own system rules (hijack, IPv6 off) sit after the self rule too; they are not the user's
        return [
          for (final x in r.skip(r.indexWhere(_isSelf) < 0 ? 0 : r.indexWhere(_isSelf) + 1))
            if (!_isHijack(x) && jsonEncode(x) != jsonEncode(ipv6OffRule)) jsonEncode(x),
        ];
      }

      // everything of the proxy mode's rules after the system part is in TUN too, the same, in the same order
      final proxyRules = after(proxy), tunRules = after(tun);
      expect(tunRules.where((r) => !r.contains('"resolve"')), proxyRules.where((r) => !r.contains('"resolve"')));
      expect(tunRules.any((r) => r.contains('steam.exe') && r.contains('"outbound":"direct"')), isTrue, reason: 'per-app Direct');
      expect(tunRules.any((r) => r.contains('bad.exe') && r.contains('reject')), isTrue, reason: 'per-app Block');
      expect(tunRules.any((r) => r.contains('tor.exe')), isTrue, reason: 'per-app Proxy with a fallback');
      expect(tunRules.any((r) => r.contains('bank.example')), isTrue);
      expect(tunRules.any((r) => r.contains('telegram.org')), isTrue, reason: 'a service');
      // order: apps, own rules, services
      int at(String s) => tunRules.indexWhere((r) => r.contains(s));
      expect([at('steam.exe'), at('bank.example'), at('8.8.8.0/24'), at('9.9.9.0/24'), at('site.example'), at('telegram.org')], orderedEquals([...[at('steam.exe'), at('bank.example'), at('8.8.8.0/24'), at('9.9.9.0/24'), at('site.example'), at('telegram.org')]..sort()]));
      expect((tun['route'] as Map)['final'], 'direct', reason: 'the quick "final" rule');
    });

    // "Resolve for IP rules" steps only: the resolve ladder of a selector falling back to Direct (docs/rules.md §6, `flag-fb<i>`)
    // is another mechanism (the names a rule sends direct once its target died), it follows the rule, not this setting
    bool isIpResolve(Map r) => r['action'] == 'resolve' && r.containsKey('server') && !r.containsKey('process_name') && !jsonEncode(r).contains('flag-fb');

    test('the resolve step in TUN is only for the proxy ports (tun-in brings the IP); the proxy mode has it for all; IP-only-in-TUN rules apply in both', () {
      final tun = _build(_plan(routing: routing)), proxy = _build(_plan(mode: 'proxy', routing: routing));
      final tunResolve = _rules(tun).where(isIpResolve).toList();
      expect(tunResolve, hasLength(1));
      expect(tunResolve.single['inbound'], ['mixed-in', 'sys-in'], reason: 'never tun-in');
      final proxyResolve = _rules(proxy).where(isIpResolve).toList();
      expect(proxyResolve, hasLength(1));
      expect(proxyResolve.single.containsKey('inbound'), isFalse, reason: 'proxy mode: unchanged, for every inbound');
      expect({...tunResolve.single}..remove('inbound'), proxyResolve.single);
      // in the same place: right before the first IP rule without the flag
      expect(_rules(tun).indexWhere(isIpResolve) + 1, _rules(tun).indexWhere((r) => '${r['ip_cidr']}' == '[8.8.8.0/24]'));
      expect(_rules(tun).any((r) => '${r['ip_cidr']}' == '[9.9.9.0/24]'), isTrue);
      expect(_rules(tun).any((r) => '${r['ip_cidr']}' == '[8.8.8.0/24]'), isTrue);
    });

    test('Resolve for IP rules = off: no step in TUN either', () {
      final r = Map<String, dynamic>.from(routing)..['dns'] = {...(routing['dns'] as Map<String, dynamic>), 'resolve': 'off'};
      final rules = _rules(_build(_plan(routing: r)));
      expect(rules.where(isIpResolve), isEmpty);
      // the fallback ladder of tor.exe (Proxy → Direct) is not that setting: it stays, in front of its rule, with the only direct
      // candidate of this plan (the OS resolver), for every inbound (the names it resolves come through the tunnel too)
      final ladder = rules.where((x) => jsonEncode(x).contains('flag-fb0') && x['action'] == 'resolve').toList();
      expect(ladder, hasLength(1));
      expect(ladder.single['server'], 'dns-local');
      expect(ladder.single.containsKey('inbound'), isFalse);
    });

    test('the "no VPN DNS server" warning of the resolve step comes in TUN too (the step is there for the proxy ports)', () {
      final r = Map<String, dynamic>.from(routing)
        ..['dns'] = {
          'servers': [
            {'id': 'local', 'addr': 'system', 'via': 'direct', 'on': true},
          ],
        };
      final warnings = <String>[];
      buildConfig(_plan(routing: r), warnings: warnings);
      expect(warnings.where((w) => w.contains('Resolve for IP rules')), hasLength(1));
      final w2 = <String>[];
      buildConfig(_plan(mode: 'proxy', routing: r), warnings: w2);
      expect(w2.where((w) => w.contains('Resolve for IP rules')), hasLength(1));
    });
  });

  group('Global in TUN', () {
    final routing = _routing(rules: [_rule('r1', {'domain_suffix': ['a.example']}, action: 'direct')], apps: [
      {'id': 'steam.exe', 'kind': 'process', 'name': 'Steam', 'act': 'direct', 'target': '', 'fallback': 'default', 'split': false},
    ]);

    test('everything goes to the main flow: no user rules, no apps; system rules and the LAN rule stay', () {
      final c = _build(_plan(global: true, routing: routing));
      final rules = _rules(c);
      expect(rules.any((r) => '$r'.contains('a.example') || '$r'.contains('steam.exe')), isFalse);
      expect(rules.where(_isSelf), hasLength(1));
      expect(rules.where(_isHijack), isNotEmpty);
      expect(rules.where((r) => r['ip_is_private'] == true), hasLength(1));
      expect((c['route'] as Map)['final'], 'proxy');
      expect(_tun(c), isNotNull);
    });
  });

  group('DNS in TUN', () {
    test('Hijack DNS on (also when the plan does not say): the tunnel\'s own resolver first, then (behind the self rules) port 53 and sniffed dns from the tun', () {
      final resolver = {'inbound': ['tun-in'], 'ip_cidr': tunDnsAddress, 'port': [53], 'action': 'hijack-dns'};
      for (final plan in [_plan(routing: _routing(hijack: true)), _plan(routing: _routing()), _plan()]) {
        final rules = _rules(_build(plan));
        final hijack = rules.where(_isHijack).toList();
        expect(hijack, [
          resolver,
          {'inbound': ['tun-in'], 'port': [53], 'action': 'hijack-dns'},
          {'inbound': ['tun-in'], 'protocol': ['dns'], 'action': 'hijack-dns'},
        ]);
        final at = rules.indexWhere(_isHijack), self = rules.indexWhere(_isSelf);
        expect(at, greaterThan(rules.indexWhere((r) => r['action'] == 'sniff')));
        // the app's own lookups (system resolver → the tunnel's resolver) are answered by the core, always;
        // its other DNS (the DNS probes of Settings → DNS) is the self rule's and reaches the real server
        expect(rules.indexOf(resolver), lessThan(self));
        expect(rules.indexWhere((r) => r['port']?.toString() == '[53]' && r['ip_cidr'] == null), greaterThan(self));
        expect(rules.indexWhere((r) => r['protocol']?.toString() == '[dns]'), greaterThan(self));
      }
    });

    test('Hijack DNS off: only queries to the tunnel\'s own resolver are answered; the rest routes like any traffic', () {
      final rules = _rules(_build(_plan(routing: _routing(hijack: false))));
      expect(rules.where(_isHijack).toList(), [
        {'inbound': ['tun-in'], 'ip_cidr': tunDnsAddress, 'port': [53], 'action': 'hijack-dns'},
      ]);
      expect(tunDnsAddress.first, startsWith('172.19.0.2'), reason: 'the second address of the tun /30');
    });

    test('the app\'s own DNS lookups (through the hijack) are answered first of all by a direct server, in Rules and Global, desktop and Android', () {
      for (final global in [false, true]) {
        final plan = _plan(global: global, routing: _routing(rules: [_rule('r', {'domain_suffix': ['a.example']})]));
        // Rules: the first enabled non-VPN server; the bootstrap (`local`/system) for the main flow's resolver
        for (final (paths, packages) in [
          (const [r'C:\Apps\dart.exe'], const <String>[]),
          (const <String>[], const [_pkg]),
        ]) {
          final c = buildConfig(plan, tunnelPort: 40001, selfPaths: paths, selfPackages: packages);
          final dns = c['dns'] as Map;
          final rules = _dnsRules(c);
          final own = rules.first;
          expect(own['inbound'], ['tun-in'], reason: 'only what the TUN hands to the DNS: the proxy ports\' lookups are not the app\'s');
          expect(own['action'], 'route');
          expect(own.containsKey(packages.isNotEmpty ? 'package_name' : (Platform.isWindows ? 'process_path_regex' : 'process_path')), isTrue, reason: '$own');
          expect(own.containsKey('outbound'), isFalse);
          // the server is `default_domain_resolver`: direct by construction, never one that detours
          final server = own['server'];
          expect(server, (c['route'] as Map)['default_domain_resolver']);
          final def = (dns['servers'] as List).cast<Map>().firstWhere((s) => s['tag'] == server);
          expect(def.containsKey('detour'), isFalse, reason: 'the server answers outside the tunnel: $def');
          expect(server, isNot(dns['final']), reason: 'final is the VPN server (via vpn, first enabled): the point is not to depend on it');
          expect(dns['final'], 'dns-remote-doh1-v');
        }
      }
    });

    test('no own DNS rule without the TUN (the proxy ports\' queries are not the app\'s) or without a self rule', () {
      expect(_dnsRules(_build(_plan(mode: 'proxy'))).where((r) => r.containsKey('process_path') || r.containsKey('process_path_regex')), isEmpty);
      expect(_dnsRules(buildConfig(_plan(), tunnelPort: 40001)).any((r) => r.containsKey('package_name') || r.containsKey('server') && r['inbound'] != null), isFalse);
      expect(_dnsRules(buildConfig(_plan(mode: 'proxy'), selfPackages: const [_pkg])), isEmpty);
    });

    test('the DNS rules for the same processes are made from the self rules', () {
      for (final r in selfRules(paths: [r'C:\x.exe'], packages: [_pkg])) {
        final d = selfDnsRules([r], server: 'dns-x').single;
        expect({...d}..remove('inbound')..remove('action')..remove('server'), {...r}..remove('action')..remove('outbound'));
        expect([d['inbound'], d['action'], d['server']], [['tun-in'], 'route', 'dns-x']);
      }
    });

    test('Global keeps the hijack too; proxy mode never has it', () {
      expect(_rules(_build(_plan(global: true))).where(_isHijack), isNotEmpty);
      expect(_rules(_build(_plan(mode: 'proxy', routing: _routing(hijack: true)))).where(_isHijack), isEmpty);
    });
  });

  group('sing-box check', () {
    Future<void> check(String name, Map<String, dynamic> config) async {
      final dir = await Directory.systemTemp.createTemp('jorm-tun');
      try {
        final f = File(p.join(dir.path, 'config.json'));
        // the DNS flag files must exist for sing-box: put them in the temp directory
        for (final s in (((config['route'] as Map)['rule_set'] as List?) ?? const []).cast<Map>().where((s) => '${s['tag']}'.startsWith('flag-'))) {
          s['path'] = p.join(dir.path, '${s['tag']}.json');
          File('${s['path']}').writeAsStringSync(dnsFlagJson(true));
        }
        await f.writeAsString(jsonEncode(config));
        final r = await Process.run(_bin, ['check', '-c', f.path, '--disable-color']);
        expect(r.exitCode, 0, reason: '$name: ${r.stdout}${r.stderr}');
      } finally {
        await dir.delete(recursive: true);
      }
    }

    final routing = _routing(
      apps: [
        {'id': 'steam.exe', 'kind': 'process', 'name': 'Steam', 'act': 'direct', 'target': '', 'fallback': 'default', 'split': false},
      ],
      rules: [
        _rule('d', {'domain_suffix': ['bank.example']}, action: 'direct'),
        _rule('ip', {}, ip: {'ip_cidr': ['8.8.8.0/24']}, ipTunOnly: true),
      ],
    );
    final self = selfProcessPaths(_bin);

    test('every stack, hijack on / off, Rules and Global, IPv6 on / off', () async {
      for (final stack in tunStacks) {
        for (final hijack in [true, false]) {
          for (final global in [false, true]) {
            for (final ipv6 in [true, false]) {
              final plan = _plan(stack: stack, global: global, ipv6: ipv6, routing: _routing(hijack: hijack, apps: routing['apps'] as List<Map>, rules: routing['rules'] as List<Map>));
              await check('$stack hijack=$hijack global=$global ipv6=$ipv6', buildConfig(plan, tunnelPort: 40001, selfPaths: self));
            }
          }
        }
      }
    }, skip: _skip, timeout: const Timeout(Duration(minutes: 2)));

    test('Android shape: the package rule and the own-DNS rule pass check (Rules and Global, hijack on / off)', () async {
      for (final global in [false, true]) {
        for (final hijack in [true, false]) {
          final plan = _plan(global: global, routing: _routing(hijack: hijack, rules: routing['rules'] as List<Map>));
          final c = buildConfig(plan, tunnelPort: 40001, selfPaths: const [], selfPackages: const [_pkg]);
          expect(_rules(c).where(_isSelfPackage), hasLength(1));
          expect(_dnsRules(c).first['package_name'], [_pkg]);
          await check('android global=$global hijack=$hijack', c);
        }
      }
    }, skip: _skip);

    test('the resolve step limited to mixed-in / sys-in passes check (with and without a sys-in inbound)', () async {
      final r = _routing(rules: [_rule('ip', {}, ip: {'ip_cidr': ['8.8.8.0/24']})]);
      for (final sysPort in <int?>[null, 40002]) {
        final c = buildConfig(_plan(routing: r), tunnelPort: 40001, selfPaths: self, sysPort: sysPort);
        expect(_rules(c).where((x) => x['action'] == 'resolve' && '${x['inbound']}' == '[mixed-in, sys-in]'), hasLength(1));
        await check('resolve in TUN sysPort=$sysPort', c);
      }
    }, skip: _skip);
  });

  group('the daemon', () {
    test('not elevated: a TUN connect is refused before anything starts, with the event; proxy mode connects', () async {
      final r = await _Rig.start(elevated: false);
      try {
        final (code, res) = await r.raw('POST', '/api/connect', r.body('tun'));
        expect(code, 500);
        expect(res['error'], TunNeedsAdmin.message);
        expect(r.box.starts, 0, reason: 'sing-box never started');
        var st = await r.call('GET', '/api/status');
        expect([st['connected'], st['mode'], st['error']], [false, null, TunNeedsAdmin.message]);
        var events = await r.events();
        expect([for (final e in events) '${e['cat']}/${e['type']}'], ['core/tunNeedsAdmin']);
        expect(events.single['level'], 'error');
        expect(events.single['data'], {'stage': 'check'});

        // Proxy mode is not affected
        expect((await r.raw('POST', '/api/connect', r.body('proxy'))).$1, 200);
        st = await r.call('GET', '/api/status');
        expect([st['connected'], st['mode']], [true, 'proxy']);
        final cfg = r.box.config!;
        expect((cfg['inbounds'] as List).cast<Map>().any((i) => i['type'] == 'tun'), isFalse);
        // the core's own and the sing-box paths are in the config in either mode
        expect(((cfg['route'] as Map)['rules'] as List).cast<Map>().any(_isSelf), isTrue);

        // switching to TUN while connected, not elevated: refused, and not left half connected
        expect((await r.raw('POST', '/api/connect', r.body('tun'))).$1, 500);
        st = await r.call('GET', '/api/status');
        expect([st['connected'], st['mode']], [false, null]);
        expect(r.box.up, isFalse);
      } finally {
        await r.close();
      }
    });

    test('elevated: a TUN connect starts sing-box with the tun inbound and reports mode tun', () async {
      final r = await _Rig.start(elevated: true);
      try {
        final st = await r.call('POST', '/api/connect', {...r.body('tun'), 'plan': {..._plan(mode: 'tun', stack: 'gvisor'), 'mixedPort': 2080}});
        expect([st['connected'], st['mode']], [true, 'tun']);
        expect(_tun(r.box.config!)!['stack'], 'gvisor');
        final ev = (await r.events()).where((e) => e['type'] == 'connected').single;
        expect((ev['data'] as Map)['mode'], 'tun');
        expect((await r.call('POST', '/api/disconnect', {}))['mode'], isNull);
      } finally {
        await r.close();
      }
    });

    test('a sing-box refusal for permission in TUN is the same clear error; other failures are not', () async {
      expect(tunAccessDenied('start inbound/tun[tun-in]: configure tun interface: Access is denied.'), isTrue);
      expect(tunAccessDenied('create tun: operation not permitted'), isTrue);
      expect(tunAccessDenied('sing-box rejected the config: unknown field'), isFalse);
      final r = await _Rig.start(elevated: true);
      try {
        r.box.failWith = 'sing-box failed to start: start inbound/tun[tun-in]: configure tun interface: Access is denied.';
        final (code, res) = await r.raw('POST', '/api/connect', r.body('tun'));
        expect([code, res['error']], [500, TunNeedsAdmin.message]);
        var events = await r.events();
        expect([for (final e in events) '${e['cat']}/${e['type']}'], ['core/tunNeedsAdmin']);
        expect((events.single['data'] as Map)['stage'], 'start');
        expect((events.single['data'] as Map)['error'], contains('Access is denied'));

        r.box.failWith = 'sing-box failed to start: address already in use';
        final (code2, res2) = await r.raw('POST', '/api/connect', r.body('tun'));
        expect([code2, res2['error']], [500, 'sing-box failed to start: address already in use']);
        events = await r.events();
        expect([for (final e in events) '${e['cat']}/${e['type']}'], ['core/tunNeedsAdmin', 'conn/connectFailed']);
        expect((events.last['data'] as Map).containsKey('fix'), isFalse, reason: 'not the proxy port: no fix');
      } finally {
        await r.close();
      }
    });

    test('conn/connectFailed says where to fix it: a taken proxy port is fix: settings, an unusable Manual pick fix: pick', () async {
      expect(userPortRefused('start service: start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:2080: bind: address already in use', 2080), isTrue);
      expect(userPortRefused('listen tcp 127.0.0.1:2080: bind: Only one usage of each socket address is normally permitted.', 2080), isTrue);
      expect(userPortRefused('listen tcp 127.0.0.1:20801: bind: address already in use', 2080), isFalse, reason: 'another port');
      expect(userPortRefused('start inbound/mixed[tunnel-in]: listen tcp 127.0.0.1:51000: bind: address already in use', 2080), isFalse);
      expect(userPortRefused('sing-box rejected the config: unknown field', 2080), isFalse);
      final r = await _Rig.start(elevated: true);
      try {
        r.box.failWith = 'sing-box failed to start: start service: start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:2080: bind: address already in use';
        final (code, _) = await r.raw('POST', '/api/connect', {...r.body('tun'), 'plan': {..._plan(mode: 'proxy'), 'mixedPort': 2080}});
        expect(code, 500);
        var failed = (await r.events()).where((e) => e['type'] == 'connectFailed').toList();
        expect(failed, hasLength(1));
        expect((failed.single['data'] as Map)['fix'], 'settings');
        expect('${(failed.single['data'] as Map)['reason']}', contains('[mixed-in]'), reason: 'the words of sing-box stay as they are');

        // Manual on a server the plan has no usable outbound for: the config refuses it
        r.box.failWith = null;
        final plan = _plan(mode: 'proxy');
        final main = (plan['main'] as Map).cast<String, dynamic>();
        final (code2, _) = await r.raw('POST', '/api/connect', {
          ...r.body('tun'),
          'plan': {
            ...plan,
            'mixedPort': 2080,
            'main': {...main, 'pinned': true, 'chosen': 'gone::x'},
          },
        });
        expect(code2, 500);
        failed = (await r.events()).where((e) => e['type'] == 'connectFailed').toList();
        expect(failed, hasLength(2));
        expect((failed.last['data'] as Map)['fix'], 'pick');
      } finally {
        await r.close();
      }
    });
  });
}

class _Rig {
  _Rig._(this.tmp, this.box, this.daemon, this.api);

  final Directory tmp;
  final _FakeBox box;
  final Daemon daemon;
  final HttpServer api;

  static Future<_Rig> start({required bool elevated}) async {
    final tmp = await Directory.systemTemp.createTemp('jorm-tun-d');
    final box = _FakeBox();
    final d = Daemon(
      singBox: 'none',
      dataDir: p.join(tmp.path, 'data'),
      uiFile: 'none',
      exitCheck: (_) async => {'ip': '127.0.0.1'},
      sysProxy: _FakeSys(),
      process: box,
      isElevated: () => elevated,
    );
    await d.init();
    final api = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api.listen(d.handle);
    return _Rig._(tmp, box, d, api);
  }

  Map<String, dynamic> body(String mode) => {
        'plan': {..._plan(mode: mode), 'mixedPort': 2080},
        'systemProxy': false,
      };

  Future<(int, Map<String, dynamic>)> raw(String method, String path, [Map<String, dynamic>? body]) async {
    final c = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:${api.port}$path'));
      req.headers.set('X-Jorm', '1');
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      return (res.statusCode, (jsonDecode(await res.transform(utf8.decoder).join()) as Map).cast<String, dynamic>());
    } finally {
      c.close(force: true);
    }
  }

  Future<Map<String, dynamic>> call(String method, String path, [Map<String, dynamic>? body]) async => (await raw(method, path, body)).$2;

  Future<List<Map<String, dynamic>>> events() async => [
        for (final e in (await call('GET', '/api/events'))['events'] as List)
          if ((e as Map)['type'] != 'deprecated') e.cast<String, dynamic>(),
      ];

  Future<void> close() async {
    await daemon.shutdown();
    await api.close(force: true);
    await tmp.delete(recursive: true);
  }
}

class _FakeSys extends SystemProxy {
  _FakeSys() : super(File('never-written'));
  bool _on = false;

  @override
  bool get isSet => _on;

  @override
  Future<String?> enable(int port) async {
    _on = true;
    return null;
  }

  @override
  Future<void> restore() async => _on = false;
}

class _FakeBox extends SingBoxProcess {
  _FakeBox() : super('none', 'none');
  bool up = false;
  int starts = 0;
  String? failWith;
  Map<String, dynamic>? config;

  @override
  bool get running => up;

  @override
  int? get pid => up ? 1 : null;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    starts++;
    this.config = config;
    if (failWith != null) throw SingBoxError(failWith!);
    up = true;
  }

  @override
  Future<void> stop() async => up = false;
}
