// Spare entries of Auto's list (docs/logs.md → catalog rows `auto/unstable`, `sub/updated`; «Задетые настройки»; notify table):
// a route Auto is not on is a spare one. Its `auto/unstable` and a `sub/updated` that only touched spare entries are info
// journal entries with `spare: true`, never notifications; anything the user runs on keeps the warn.
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'catalog_model_test.dart' show snap, source;

class _Api extends SingBoxApi {
  _Api() : super(0, '');
  @override
  Map<String, String> get selected => const {};
  @override
  Stream<void> get groupsChanged => const Stream.empty();
  @override
  Future<bool> select(String group, String outbound) async => true;
  @override
  Iterable<LiveConnection> get connections => const [];
  @override
  Future<bool> closeConnection(String id) async => true;
  @override
  Future<bool> closeAllConnections() async => true;
  @override
  Stream<ClosedConnection> closedConnections() => const Stream.empty();
  @override
  void watch() {}
  @override
  Future<void> close() async {}
}

class _Runner implements BoxRunner {
  bool up = false;
  final _api = _Api();
  @override
  void Function(String line)? onLog;
  @override
  void Function(int code)? onExit;
  @override
  bool get running => up && withApi;
  @override
  int? get pid => null;
  @override
  SingBoxApi? get api => up && withApi ? _api : null;

  /// A running core has an API service (Auto exists). Off: the updater fetches by the plain socket.
  bool withApi = false;
  @override
  void note(String line) {}
  @override
  Future<void> start(Map<String, dynamic> config) async => up = true;
  @override
  Future<void> stop() async => up = false;
}

Map<String, dynamic> _route(String id, {bool chain = false}) {
  Map<String, dynamic> pick(String key) => {
        'pick': 'priority',
        'chosen': key,
        'nodes': [
          {
            'key': key,
            'outbound': {'type': 'shadowsocks', 'server': '127.0.0.1', 'server_port': 1, 'method': 'aes-128-gcm', 'password': 'x'},
          },
        ],
      };
  return {'id': id, 'kind': chain ? 'chain' : 'unit', if (chain) 'entry': pick('s::e'), 'main': pick('s::a')};
}

/// Routes `x` (Auto starts on it, the first) and `c1` (a chain, the spare one).
Map<String, dynamic> _plan({Map<String, dynamic>? routing}) => {
      'plan': {
        'routes': [_route('x'), _route('c1', chain: true)],
        'mixedPort': 2080,
        'global': routing == null,
        'routing': ?routing,
      },
    };

String _link(int i, String name) => 'ss://YWVzLTEyOC1nY206cGFzcw@198.51.100.${20 + i}:8388#$name';
const _names = ['one', 'two', 'three', 'four'];

void main() {
  late Directory tmp;
  late HttpServer origin;
  late CoreService svc;
  final runner = _Runner();
  var served = <int>[0, 1, 2, 3];

  setUp(() async {
    served = [0, 1, 2, 3];
    runner
      ..up = false
      ..withApi = false;
    tmp =await Directory.systemTemp.createTemp('jorm-spare');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((rq) {
      rq.response
        ..write([for (final i in served) _link(i, _names[i])].join('\n'))
        ..close();
    });
    svc = CoreService(
      directProbe: (_, _) async => 5,
      isElevated: () => true,
      singBox: 'none',
      resolveAddresses: false,
      dataDir: p.join(tmp.path, 'data'),
      runner: runner,
      sysProxy: NoSystemProxy(),
      exitCheck: (_) async => {'ip': '127.0.0.1'},
    );
    await svc.init();
  });
  tearDown(() async {
    await svc.dispose();
    await origin.close(force: true);
    for (var i = 0; i < 10 && tmp.existsSync(); i++) {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  List<Map> events(String cat, String type) => [
        for (final e in (svc.events()['events'] as List).cast<Map>())
          if (e['cat'] == cat && e['type'] == type) e,
      ];
  Future<void> connect({Map<String, dynamic>? routing}) async {
    runner.withApi = true;
    await svc.connect(_plan(routing: routing));
    // Auto now exists; the updater's fetch goes by the plain socket again (the fake core has no real service inbound)
    runner.withApi = false;
  }

  Future<void> unstable(String id) =>
      svc.routeUnstable(AutoUnstable(id: id, strikes: 3, holdMs: 60000, at: DateTime.now().millisecondsSinceEpoch));

  group('auto/unstable', () {
    test('a route that is not the current one: info, spare true; the current one: warn, no spare', () async {
      await connect();
      await unstable('c1');
      final spare = events('auto', 'unstable').single;
      expect(spare['level'], 'info');
      expect((spare['data'] as Map)['spare'], true);
      expect((spare['data'] as Map)['id'], 'c1');

      await unstable('x');
      final cur = events('auto', 'unstable').last;
      expect(cur['level'], 'warn');
      expect((cur['data'] as Map).containsKey('spare'), isFalse);
      expect((cur['data'] as Map)['id'], 'x');
    });
  });

  group('sub/updated of a subscription whose servers a spare chain exit uses', () {
    // source `a` is served by [origin]; the chain c1 goes x -> a (so a lost server of `a` touches c1, and nothing else
    // unless a rule targets it); `x` is the connection Auto runs on.
    Map<String, dynamic> snapshot({bool rule = false}) {
      final nodes = [for (final n in parseLinks([for (var i = 0; i < 4; i++) _link(i, _names[i])].join('\n'))) n.toJson()];
      return snap(over: {
        'sourcesData': {
          'a': source('a', [], extra: {
            'name': 'Prov',
            'url': 'http://127.0.0.1:${origin.port}/sub',
            'updateInterval': 10,
            'updatedAt': 0,
            'nodes': nodes,
          }),
          'x': source('x', ['1']),
        },
        'sourceOrder': ['a', 'x'],
        'connectOrder': ['x', 'c1'],
        'activeConnectId': 'x',
        'catalogOrder': {'simple': ['x', 'c1'], 'profiles': <String>[]},
        'profilesData': <String, dynamic>{},
        'modeState': {'profiles': {'order': <String>[], 'active': null, 'auto': true}},
        'chainsData': {
          'c1': {'id': 'c1', 'name': 'X via A', 'inId': 'x', 'outId': 'a', 'inAuto': true, 'outOff': [for (final n in nodes) if (n['name'] != 'one') 'a::${n['id']}']},
        },
        if (rule) ...{
          'rulesData': {
            'r1': {
              'id': 'r1',
              'name': 'Rule r1',
              'enabled': true,
              'action': 'proxy',
              'target': 'node:a::${nodes.firstWhere((n) => n['name'] == 'one')['id']}',
              'fallback': 'block',
              'groups': {'domain': {'not': false, 'v': {'domain_suffix': ['r1.test']}}},
            },
          },
          'ruleOrder': ['r1'],
        },
      });
    }

    Future<Map> removeOne({bool rule = false}) async {
      await svc.saveState(snapshot(rule: rule));
      served = [1, 2, 3]; // `one`, the only ticked exit server of c1, gone: the chain is left with no exit (a chain is listed only then)
      svc.updater.askAgain('a');
      await svc.updater.runDue();
      return events('sub', 'updated').firstWhere((e) => (e['data'] as Map)['lost'] != null);
    }

    List<Map> affected(Map e) => ((e['data'] as Map)['affected'] as List).cast<Map>();

    test('only the spare chain is affected: its item is spare, the event is info', () async {
      await connect();
      final e = await removeOne();
      final c1 = affected(e).where((a) => a['id'] == 'c1').toList();
      expect(c1, hasLength(1), reason: 'the chain loses a server');
      expect(affected(e).every((a) => a['spare'] == true), isTrue, reason: '$e');
      expect(e['level'], 'info');
    });

    test('a rule target affected too: no spare on it, the whole event stays warn', () async {
      await connect();
      final e = await removeOne(rule: true);
      expect(e['level'], 'warn');
      final r1 = affected(e).firstWhere((a) => a['kind'] == 'rule');
      expect(r1.containsKey('spare'), isFalse);
      expect(affected(e).every((a) => a['spare'] == true), isFalse);
    });

    test('a chain that is a rule\'s target is not spare', () async {
      await connect(routing: {
        'fallback': 'main',
        'targets': {'chain:c1': _route('c1', chain: true)},
        'rules': <Map<String, dynamic>>[],
      });
      final e = await removeOne();
      final c1 = affected(e).firstWhere((a) => a['id'] == 'c1');
      expect(c1.containsKey('spare'), isFalse);
      expect(e['level'], 'warn');
    });

    test('not connected: no spare marks, warn as before', () async {
      final e = await removeOne();
      expect(affected(e).any((a) => a.containsKey('spare')), isFalse);
      expect(e['level'], 'warn');
    });
  });

  group('eventNotifies', () {
    EventRecord rec(String cat, String type, Map<String, dynamic> data, {String level = 'info'}) =>
        EventRecord.fromJson({'id': 1, 'at': 0, 'cat': cat, 'type': type, 'level': level, 'own': false, 'data': data});

    test('a spare auto/unstable and an all-spare sub/updated never notify; their ordinary forms do', () {
      expect(eventNotifies(null, rec('auto', 'unstable', {'id': 'c1', 'spare': true})), isFalse);
      expect(eventNotifies(null, rec('auto', 'unstable', {'id': 'x'}, level: 'warn')), isTrue);

      Map<String, dynamic> sub(List<Map<String, dynamic>> affected) =>
          {'source': 'a', 'name': 'Prov', 'lost': ['two'], 'lostCount': 1, 'affected': affected};
      final spare = {'kind': 'chain', 'id': 'c1', 'name': 'C', 'to': 'main', 'spare': true};
      final rule = {'kind': 'rule', 'id': 'r1', 'name': 'R', 'to': 'block'};
      expect(eventNotifies(null, rec('sub', 'updated', sub([spare]))), isFalse);
      expect(eventNotifies(null, rec('sub', 'updated', sub([spare, rule]), level: 'warn')), isTrue);
      expect(eventNotifies(null, rec('sub', 'updated', sub([rule]), level: 'warn')), isTrue);
    });

    test('conn/vpnUp by app does not notify', () {
      expect(eventNotifies(null, rec('conn', 'vpnUp', {'by': 'app', 'downMs': 1, 'causes': ['core']})), isFalse);
    });
  });
}
