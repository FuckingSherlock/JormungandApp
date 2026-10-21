// A server sing-box cannot run (no outbound, or a non-empty `unsupported` reason) is not usable. liveNodes keeps it
// (the plan names such a target `unsupported`); unsupportedRefs lists the unusable ones that are not disabled, which
// the UI shows in the «Unavailable» block instead of its live lists.
import 'dart:convert';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

const _clock = 1760000000000;

Map<String, dynamic> node(String id, {bool outbound = true, String? unsupported}) => {
      'id': id,
      'name': 'Server $id',
      'flag': '🇩🇪',
      'protocol': 'vless',
      'address': '$id.example',
      'port': 443,
      if (outbound) 'outbound': {'o': id},
      'unsupported': ?unsupported,
    };

Map<String, dynamic> source(String id, List<Map<String, dynamic>> nodes, {List<String> disabled = const []}) => {
      'id': id,
      'kind': 'sub',
      'name': 'Source $id',
      'enabled': true,
      'inAuto': true,
      'offNodes': <String>[],
      'disabledNodes': disabled,
      'gone': <dynamic>[],
      'nodes': nodes,
    };

/// One source `a` with [nodes] (and [disabled] server ids), one profile `p` over it.
Catalog make(List<Map<String, dynamic>> nodes, {List<String> disabled = const []}) {
  final snap = <String, dynamic>{
    'sourcesData': {'a': source('a', nodes, disabled: disabled)},
    'sourceOrder': ['a'],
    'sourceSeq': 1,
    'connectMode': 'simple',
    'connectOrder': ['a'],
    'activeConnectId': 'a',
    'autoConnect': true,
    'pinnedNode': null,
    'modeState': {
      'profiles': {'order': ['p'], 'active': 'p', 'auto': true},
    },
    'profilesData': {
      'p': {'id': 'p', 'name': 'All', 'sources': ['a'], 'nodes': <String>[], 'inAuto': true},
    },
    'profileSeq': 1,
    'chainsData': <String, dynamic>{},
    'chainSeq': 0,
    'catalogOrder': {'simple': ['a'], 'profiles': ['p']},
    'routeCustom': {'simple': false, 'profiles': false},
    'segState': {'mode': 'proxy', 'route': 'rules', 'sys': 'off'},
    'connCfg': <String, dynamic>{},
    'autoCfg': <String, dynamic>{},
    'rulesData': <String, dynamic>{},
    'ruleOrder': <String>[],
    'ruleSeq': 1,
    'quickCfg': <String, dynamic>{},
    'appRules': <String, dynamic>{},
    'pings': <dynamic>[],
  };
  return Catalog.fromJson(jsonDecode(jsonEncode(snap)) as Map<String, dynamic>, now: () => _clock);
}

/// a1 usable, a2 no outbound, a3 unsupported, a4 usable but disabled, a5 unsupported and disabled,
/// a6 usable, a7 an empty `unsupported` reason (still usable).
Catalog mixed() => make([
      node('a1'),
      node('a2', outbound: false),
      node('a3', unsupported: 'wireguard is not run by sing-box'),
      node('a4'),
      node('a5', unsupported: 'ssr is not run by sing-box'),
      node('a6'),
      node('a7', unsupported: ''),
    ], disabled: ['a4', 'a5']);

void main() {
  test('liveNodes leaves out only the disabled servers: the plan still sees the unusable ones (reason unsupported)', () {
    final c = mixed();
    expect(c.liveNodes(c.sourcesData['a']!).map((n) => n.id), ['a1', 'a2', 'a3', 'a6', 'a7']);
  });

  test('a server is usable only with an outbound and no non-empty unsupported reason', () {
    final c = mixed();
    expect(c.nodeOfKey('a::a1')!.usable, isTrue);
    expect(c.nodeOfKey('a::a7')!.usable, isTrue);
    expect(c.nodeOfKey('a::a2')!.usable, isFalse);
    expect(c.nodeOfKey('a::a3')!.usable, isFalse);
  });

  test('unsupportedRefs lists the unusable servers that are not disabled, as refs of the source', () {
    final c = mixed();
    final refs = c.unsupportedRefs('a');
    expect([for (final r in refs) r.key], ['a::a2', 'a::a3']);
    expect([for (final r in refs) r.sid], ['a', 'a']);
    expect([for (final r in refs) r.node.id], ['a2', 'a3']);
  });

  test('unsupportedRefs is empty for an unknown source and for a source with only usable servers', () {
    expect(mixed().unsupportedRefs('nope'), isEmpty);
    expect(make([node('a1'), node('a2')]).unsupportedRefs('a'), isEmpty);
  });

  test('a source where every server is unusable lists them all in unsupportedRefs', () {
    final c = make([node('a1', outbound: false), node('a2', unsupported: 'x')]);
    expect(c.unsupportedRefs('a').map((r) => r.node.id), ['a1', 'a2']);
  });
}
