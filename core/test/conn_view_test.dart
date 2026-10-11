import 'package:jormungand_core/jormungand_core.dart';
import 'package:jormungand_core/src/sbapi/started_service.pb.dart' show ProcessInfo;
import 'package:test/test.dart';

Map<String, dynamic> conn(
  String id,
  String host, {
  String net = 'tcp',
  String process = '',
  String ruleKind = 'final',
  String ruleName = '',
  String ruleId = '',
  String rule = '',
  List<String> out = const ['route0/s::n'],
  num down = 0,
  num up = 0,
  num downRate = 0,
  num upRate = 0,
  String start = '2026-01-01T10:00:00Z',
}) => {
  'id': id, 'host': host, 'port': '443', 'net': net, 'rule': rule, 'ruleName': ruleName,
  'ruleKind': ruleKind, if (ruleId.isNotEmpty) 'ruleId': ruleId, 'out': out, 'process': process,
  'down': down, 'up': up, 'downRate': downRate, 'upRate': upRate, 'start': start,
};

LiveConn c(Map<String, dynamic> m) => LiveConn.fromJson(m);

void main() {
  test('rule label: final is empty, a named rule is its name, an unnamed one its raw text', () {
    expect(c(conn('1', 'a.com')).ruleLabel, '');
    expect(c(conn('1', 'a.com', ruleKind: 'user', ruleName: 'Work', rule: 'domain=a.com')).ruleLabel, 'Work');
    expect(c(conn('1', 'a.com', ruleKind: '', rule: 'domain=a.com')).ruleLabel, 'domain=a.com');
    expect(c(conn('1', 'a.com', ruleKind: '')).ruleLabel, '');
    expect(c(conn('1', 'a.com', rule: 'x')).raw, 'x');
  });

  test('app is the file name of the process; port 0 is no port', () {
    final x = c({...conn('1', 'a.com', process: r'C:\Apps\Telegram.exe'), 'port': 0});
    expect(x.app, 'Telegram.exe');
    expect(x.port, '');
    expect(c(conn('2', 'a.com', process: '/usr/bin/curl')).app, 'curl');
  });

  test('pkg: the first package name of sing-box\'s process info reaches the live and the closed connection and the list JSON', () {
    final proc = ProcessInfo(processPath: '', packageNames: ['org.telegram.messenger', 'other.pkg']);
    final raw = Connection(id: '1', chainList: ['route0/s::a'], destination: 'a.com:443', processInfo: proc);
    expect(LiveConnection(raw).pkg, 'org.telegram.messenger');
    expect(ClosedConnection.of(raw).pkg, 'org.telegram.messenger');
    expect(LiveConnection(Connection(id: '2')).pkg, '');
    expect(ClosedConnection.of(Connection(id: '2', processInfo: ProcessInfo(processPath: '/usr/bin/curl'))).pkg, '');
    expect(c({...conn('1', 'a.com'), 'pkg': 'org.telegram.messenger'}).pkg, 'org.telegram.messenger');
    expect(c(conn('1', 'a.com')).pkg, '');
    expect(c({...conn('1', 'a.com'), 'pkg': 'org.telegram.messenger'}).app, 'org.telegram.messenger', reason: 'no process path on Android: the package is the app');
  });

  test('domain: the registrable part, three labels under co.uk', () {
    expect(connDomain('www.example.com'), 'example.com');
    expect(connDomain('a.b.bbc.co.uk'), 'bbc.co.uk');
    expect(connDomain('example.com'), 'example.com');
    expect(connDomain('localhost'), 'localhost');
  });

  test('service: by the rule that caught it, by app, by domain, by Telegram address', () {
    expect(connService(c(conn('1', 'x.com', ruleKind: 'service', ruleId: 'netflix'))), 'netflix');
    expect(connService(c(conn('1', 'x.com', ruleKind: 'app', ruleId: 'com.discord'))), 'discord');
    expect(connService(c(conn('1', 'r1.googlevideo.com'))), 'youtube');
    expect(connService(c(conn('1', 'cdn.ggpht.com'))), 'youtube');
    expect(connService(c(conn('1', '149.154.167.51'))), 'telegram');
    expect(connService(c(conn('1', '8.8.8.8'))), isNull);
    expect(connService(c(conn('1', 'example.com'))), isNull);
  });

  test('sorts: Newest, speed, totals, Longest', () {
    final a = c(conn('a', 'a.com', start: '2026-01-01T10:00:00Z', downRate: 5, down: 10));
    final b = c(conn('b', 'b.com', start: '2026-01-01T10:05:00Z', downRate: 9, down: 1));
    final v = ConnView();
    expect(v.shown([a, b]).map((x) => x.id), ['b', 'a']);
    v.sort = ConnSort.downSpeed;
    expect(v.shown([a, b]).map((x) => x.id), ['b', 'a']);
    v.sort = ConnSort.downloaded;
    expect(v.shown([a, b]).map((x) => x.id), ['a', 'b']);
    v.sort = ConnSort.duration;
    expect(v.shown([b, a]).map((x) => x.id), ['a', 'b']);
  });

  test('filter: OR inside a section, AND across; query matches host, app, rule, route', () {
    final list = [
      c(conn('1', 'a.com', net: 'tcp', process: 'curl', out: ['direct'])),
      c(conn('2', 'b.com', net: 'udp', process: 'curl', ruleKind: 'user', ruleName: 'Work')),
      c(conn('3', 'c.com', net: 'udp', process: 'wget')),
    ];
    final v = ConnView();
    v.filter.toggle(ConnSection.net, 'udp');
    expect(v.shown(list).map((x) => x.id).toSet(), {'2', '3'});
    v.filter.toggle(ConnSection.app, 'curl');
    expect(v.shown(list).map((x) => x.id), ['2']);
    expect(v.filter.count, 2);
    v.filter.clear();
    v.query = 'work';
    expect(v.shown(list).map((x) => x.id), ['2']);
    v.query = 'default';
    expect(v.shown(list).map((x) => x.id).toSet(), {'1', '3'});
    v.via = (x) => x.exit == 'direct' ? 'Direct' : 'Berlin';
    v.query = 'direct';
    expect(v.shown(list).map((x) => x.id), ['1']);
  });

  test('groups: service, domain, app for a bare IP, Other; sums and group order', () {
    final list = [
      c(conn('1', 'r1.googlevideo.com', downRate: 100, down: 5)),
      c(conn('2', 'i.ytimg.com', downRate: 50, down: 7)),
      c(conn('3', 'www.example.com', downRate: 10)),
      c(conn('4', '1.2.3.4', process: 'curl', downRate: 1)),
      c(conn('5', '5.6.7.8', downRate: 1)),
    ];
    final v = ConnView()..sort = ConnSort.downSpeed;
    final g = v.groups(v.shown(list))!;
    expect(g.map((x) => x.key), ['s:youtube', 'd:example.com', 'a:curl', 'o']);
    expect(g.first.name, 'YouTube');
    expect(g.first.rows.length, 2);
    expect(g.first.downRate, 150);
    expect(g.first.down, 12);
    expect(g.last.name, '');
    v.group = ConnGroupBy.app;
    expect(v.groups(v.shown(list))!.map((x) => x.key), ['a:', 'a:curl']);
    v.group = ConnGroupBy.none;
    expect(v.groups(v.shown(list)), isNull);
  });

  test('app groups are titled by appName for a package (key stays the package); a process keeps its file name; the search matches the name', () {
    const tg = 'org.telegram.messenger';
    final list = [
      c({...conn('1', 'a.com'), 'pkg': tg}),
      c({...conn('2', '1.2.3.4'), 'pkg': tg}),
      c({...conn('3', '1.2.3.5'), 'pkg': 'com.gone.app'}),
      c(conn('4', '1.2.3.6', process: r'C:\Apps\curl.exe')),
    ];
    final v = ConnView()..group = ConnGroupBy.app;
    var g = v.groups(v.shown(list))!;
    expect(g.map((x) => x.name).toSet(), {tg, 'com.gone.app', 'curl.exe'}, reason: 'no resolver: the package');
    v.appName = (p) => p == tg ? 'Tele Gram' : p;
    g = v.groups(v.shown(list))!;
    expect(g.map((x) => (x.key, x.name)).toSet(), {('a:$tg', 'Tele Gram'), ('a:com.gone.app', 'com.gone.app'), ('a:curl.exe', 'curl.exe')});
    v.group = ConnGroupBy.service; // a bare IP falls back to its app, the domain stays a domain
    g = v.groups(v.shown(list))!;
    expect(g.map((x) => x.name).toSet(), {'a.com', 'Tele Gram', 'com.gone.app', 'curl.exe'});
    v.query = 'tele gram';
    expect(v.shown(list).map((x) => x.id).toSet(), {'1', '2'});
  });

  test('group of Longest sorts by its oldest start, Newest by its newest', () {
    final list = [
      c(conn('1', 'a.youtube.com', start: '2026-01-01T09:00:00Z')),
      c(conn('2', 'b.youtube.com', start: '2026-01-01T12:00:00Z')),
      c(conn('3', 'www.example.com', start: '2026-01-01T10:00:00Z')),
    ];
    final v = ConnView();
    expect(v.groups(v.shown(list))!.map((x) => x.key), ['s:youtube', 'd:example.com']);
    v.sort = ConnSort.duration;
    expect(v.groups(v.shown(list))!.map((x) => x.key), ['s:youtube', 'd:example.com']);
    final w = [list[0], list[2]];
    v.sort = ConnSort.newest;
    expect(v.groups(v.shown(w))!.map((x) => x.key), ['d:example.com', 's:youtube']);
  });

  test('filter values: counts, selected without a connection stay (0), via for exits', () {
    final list = [
      c(conn('1', 'a.com', out: ['route0/a::1', 'route0-entry/b::2'])),
      c(conn('2', 'b.com', out: ['route0/a::1', 'route0-entry/b::2'])),
      c(conn('3', 'c.com', out: ['direct'])),
    ];
    final v = ConnView();
    final vals = v.values(ConnSection.exit, list, {'gone'}, label: (s) => s, viaText: (t) => t.join('>'));
    expect(vals.map((x) => (x.value, x.count)), [('route0/a::1', 2), ('direct', 1), ('gone', 0)]);
    expect(vals.first.via, ['route0-entry/b::2']);
    final q = v.values(ConnSection.host, list, {}, label: (s) => s, query: 'b.');
    expect(q.map((x) => x.value), ['b.com']);
  });
}
