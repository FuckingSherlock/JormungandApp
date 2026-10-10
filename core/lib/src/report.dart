import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'plan.dart';
import 'redact.dart';
import 'tun_ingress.dart' show TunIngressDetector;

/// The support report (docs/logs.md → Отчёт): the state of the core, the journal and the raw log in
/// one structured map, so that "it does not work" arrives with what is needed to see why.
///
/// [buildReport] is a pure function of what the caller hands it (the service gathers it in
/// `CoreService.report`); the host adds what only it knows through [appInfo] and the core never
/// guesses it. Everything free-form goes through the [Redactor] before it is returned.

/// The report's layout version: a field added is not a new one, a field removed or re-meant is.
const reportFormat = 1;

/// How many applications [tunSummary] lists (the rest are summed up in `others`).
const tunSummaryTop = 30;

/// The whole report.
///
/// - [now]: the clock of the report; [appInfo]: what the host says about itself and the device
///   (`version`, `versionCode`, `commit`, `platform`, `androidApi`, `device`, `abis`, `locale`,
///   `timezone`, …; reserved keys: `libbox` → `core.libbox`, `planSig` → `connection`, `names` →
///   display names of route ids and server keys, `network` → `network.host`, `settings` →
///   `settings.app`);
/// - [version]: `CoreApi.version()`; [status]: the status map; [plan]: the running plan (or null);
///   [upSince]: when the tunnel came up; [settings]: what the service knows about its own settings
///   (non-secret); [network]: `{interfaces, tunUp}`;
/// - [events]: every journal event; [lines]: every raw line of both rings, oldest first;
/// - [failures] / [tunIngress]: the trackers' snapshots (null = the core has none).
Map<String, dynamic> buildReport({
  required DateTime now,
  Map<String, dynamic> appInfo = const {},
  Map<String, dynamic> version = const {},
  Map<String, dynamic> status = const {},
  Map<String, dynamic>? plan,
  DateTime? upSince,
  Map<String, dynamic> settings = const {},
  Map<String, dynamic> network = const {},
  List<Map<String, dynamic>> events = const [],
  List<Map<String, dynamic>> lines = const [],
  Map<String, dynamic>? failures,
  Map<String, dynamic>? tunIngress,
  Redactor? redactor,
}) {
  final r = redactor ?? Redactor();
  // fixed fields (a commit hash must stay readable) vs free text (the raw log, event data, errors)
  Object? fixed(Object? v) => r.json(v, free: false);
  Object? free(Object? v) => r.json(v);

  final names = <String, String>{
    for (final e in ((appInfo['names'] as Map?) ?? const {}).entries)
      if (e.value is String && (e.value as String).isNotEmpty) '${e.key}': e.value as String,
  };
  final app = {...appInfo}..removeWhere((k, _) => _hostKeys.contains(k));
  final libbox = appInfo['libbox'];
  final hostNetwork = appInfo['network'];
  final appSettings = appInfo['settings'];

  final raw = [
    for (final l in lines) {...l, 'msg': r.text('${l['msg']}')},
  ];
  final resume = [
    for (final l in raw)
      if ('${l['msg']}'.startsWith('[resume]')) l,
  ];

  final connection = _connection(now: now, status: status, plan: plan, upSince: upSince, appInfo: appInfo, names: names);
  final net = (status['network'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};

  final out = <String, dynamic>{
    'format': reportFormat,
    'createdAt': now.toUtc().toIso8601String(),
    'createdAtMs': now.millisecondsSinceEpoch,
    'app': fixed(app),
    'core': fixed({
      'version': version['core'],
      'singBox': version['singBox'],
      'libbox': ?libbox,
      'dart': ?version['dart'],
      'os': ?version['os'],
    }),
    'connection': free(connection),
    'settings': fixed({
      if (plan != null) ..._planSettings(plan),
      ...settings,
      if (appSettings is Map) 'app': appSettings,
    }),
    'network': fixed({
      ...net,
      ...network,
      if (hostNetwork is Map) 'host': hostNetwork,
    }),
    'counters': {
      'tun': fixed(tunSummary(lines)),
      'failures': free(failures),
      'tunIngress': free(tunIngress),
      'rings': {'lines': lines.length, 'events': events.length},
    },
    'events': [for (final e in events) free(e)],
    'raw': raw,
    'resume': resume,
  };
  out['redactions'] = {'total': r.total, 'byKind': {...r.counts}};
  return out;
}

// keys of appInfo the report places elsewhere (or only reads)
const _hostKeys = {'libbox', 'planSig', 'names', 'network', 'settings'};

/// The part of the plan that is a setting, not a secret: the port, whether the local proxy asks for
/// a login (never the login), the stack, IPv6, the URL test and Auto settings, Global.
Map<String, dynamic> _planSettings(Map<String, dynamic> plan) => {
      'mode': plan['mode'],
      'mixedPort': plan['mixedPort'],
      'mixedAuth': plan['mixedAuth'] != null,
      'tunStack': planTunStack(plan),
      'ipv6': planIpv6(plan),
      'hijackDns': planHijackDns(plan),
      'global': plan['global'] == true,
      if (plan['urlTest'] != null) 'urlTest': plan['urlTest'],
      if (plan['auto'] != null) 'auto': plan['auto'],
    };

Map<String, dynamic> _connection({
  required DateTime now,
  required Map<String, dynamic> status,
  required Map<String, dynamic>? plan,
  required DateTime? upSince,
  required Map<String, dynamic> appInfo,
  required Map<String, String> names,
}) {
  final connected = status['connected'] == true;
  final state = status['down'] != null
      ? 'down'
      : status['recovering'] != null
          ? 'recovering'
          : connected
              ? 'connected'
              : 'disconnected';
  final auto = (status['auto'] as Map?)?.cast<String, dynamic>();
  final health = <String, Map<String, dynamic>>{
    for (final h in (auto?['routes'] as List?) ?? const [])
      if (h is Map && h['id'] != null) '${h['id']}': h.cast<String, dynamic>(),
  };
  String? name(Object? k) => k == null ? null : names['$k'];

  final out = <String, dynamic>{
    'state': state,
    'mode': status['mode'],
    'systemProxy': status['systemProxy'],
    if (status['blocking'] != null) 'blocking': status['blocking'],
    if (status['recovering'] != null) 'recovering': status['recovering'],
    if (status['down'] != null) 'down': status['down'],
    'restarts': status['restarts'],
    if (status['error'] != null) 'error': status['error'],
    if (status['warning'] != null) 'warning': status['warning'],
  };
  if (connected && upSince != null) {
    out['upSince'] = upSince.millisecondsSinceEpoch;
    out['uptimeMs'] = now.difference(upSince).inMilliseconds;
  }
  final exit = status['exit'];
  if (exit is Map) {
    out['exit'] = {
      'country': ?exit['country'],
      'direct': exit['direct'],
      'error': ?exit['error'],
      'at': ?exit['at'],
    };
  }
  final sig = appInfo['planSig'];
  if (plan != null) {
    final routes = planRoutes(plan);
    final cur = planCurrent(plan, routes.length);
    out['planHash'] = planHash(plan);
    // the app's own signature of the plan is a long JSON string: a digest of it says the same
    if (sig is String && sig.isNotEmpty) out['planSig'] = sig.length <= 40 ? sig : _digest(sig);
    out['stack'] = planTun(plan) ? planTunStack(plan) : null;
    out['routing'] = plan['global'] == true ? 'global' : 'rules';
    out['manual'] = plan['manual'] == true;
    out['servers'] = <String>{for (final rt in routes) ..._keysOf(rt['main']), for (final rt in routes) ..._keysOf(rt['entry'])}.length;
    out['routes'] = [
      for (var i = 0; i < routes.length; i++)
        {
          'id': routes[i]['id'],
          'kind': routes[i]['kind'] ?? 'unit',
          if (name(routes[i]['id']) != null) 'name': name(routes[i]['id']),
          'servers': _keysOf(routes[i]['main']).length,
          if (routes[i]['entry'] != null) 'entryServers': _keysOf(routes[i]['entry']).length,
          'pick': (routes[i]['main'] as Map?)?['pick'],
          if (routes[i]['main'] is Map && (routes[i]['main'] as Map)['pinned'] == true) 'pinned': true,
          'current': i == cur,
          if (health['${routes[i]['id']}'] != null) 'health': _health(health['${routes[i]['id']}']!, name),
        },
    ];
    final idx = auto != null ? (auto['index'] as num?)?.toInt() ?? cur : cur;
    final route = idx >= 0 && idx < routes.length ? routes[idx] : routes[cur];
    out['current'] = {
      'id': auto?['now'] ?? route['id'],
      'index': idx,
      'kind': route['kind'] ?? 'unit',
      if (auto != null) 'server': auto['server'],
      if (auto != null && name(auto['server']) != null) 'serverName': name(auto['server']),
      if (auto != null && auto['entryServer'] != null) 'entryServer': auto['entryServer'],
      if (auto != null && name(auto['entryServer']) != null) 'entryServerName': name(auto['entryServer']),
      if (name(route['id']) != null) 'name': name(route['id']),
    };
  } else if (sig is String && sig.isNotEmpty) {
    out['planSig'] = sig.length <= 40 ? sig : _digest(sig);
  }
  if (auto != null) {
    out['auto'] = {
      for (final k in const ['switches', 'switchedAt', 'lastSwitch', 'unstable', 'lastUnstable', 'noNet', 'offline', 'requestFails', 'blocked', 'unreachable', 'stalledClosed', 'checkedAt'])
        if (auto[k] != null) k: auto[k],
    };
  }
  return out;
}

Map<String, dynamic> _health(Map<String, dynamic> h, String? Function(Object?) name) => {
      for (final k in const ['ms', 'fails', 'oks', 'at', 'strikes', 'holdUntil', 'server', 'entryServer'])
        if (h[k] != null) k: h[k],
      if (name(h['server']) != null) 'serverName': name(h['server']),
      if (name(h['entryServer']) != null) 'entryServerName': name(h['entryServer']),
    };

// the server keys of a plan group (`{nodes: [{key, outbound}]}`)
List<String> _keysOf(Object? group) {
  if (group is! Map) return const [];
  final nodes = group['nodes'];
  if (nodes is! List) return const [];
  return [
    for (final n in nodes)
      if (n is Map && n['key'] != null) '${n['key']}' else if (n is String) n,
  ];
}

String _digest(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 12);

/// 12 hex characters of the plan's shape: the same plan gives the same hash, any change of the
/// routes, the servers (by key, never by what they hold), the routing or the settings a new one.
/// Reading two reports side by side, "was the plan the same" is one comparison; the hash says
/// nothing about the credentials (they are not part of what is hashed).
String planHash(Map<String, dynamic> plan) {
  Object? group(Object? g) {
    if (g is! Map) return null;
    return {
      'pick': g['pick'],
      'chosen': g['chosen'],
      'pinned': g['pinned'],
      'nodes': _keysOf(g),
      for (final e in g.entries)
        if (e.key != 'nodes' && e.key != 'pick' && e.key != 'chosen' && e.key != 'pinned' && e.value is! Map && e.value is! List) e.key: e.value,
    };
  }

  final skeleton = {
    'mode': plan['mode'],
    'mixedPort': plan['mixedPort'],
    'mixedAuth': plan['mixedAuth'] != null,
    'tunStack': plan['tunStack'],
    'ipv6': plan['ipv6'],
    'global': plan['global'],
    'urlTest': plan['urlTest'],
    'auto': plan['auto'],
    'routing': plan['routing'],
    'manual': plan['manual'],
    'current': plan['current'],
    'routes': [
      for (final rt in planRoutes(plan)) {'id': rt['id'], 'kind': rt['kind'], 'main': group(rt['main']), 'entry': group(rt['entry'])},
    ],
  };
  return _digest(jsonEncode(_canonical(skeleton)));
}

Object? _canonical(Object? v) {
  if (v is Map) {
    final keys = [for (final k in v.keys) '$k']..sort();
    return {for (final k in keys) k: _canonical(v[k])};
  }
  if (v is List) return [for (final e in v) _canonical(e)];
  return v;
}

// ── the TUN summary ──

// sing-box's `[id duration] body` (the ring's lines carry no level or time)
final _idRe = RegExp(r'^\[(\d{1,10}) [0-9][^\]\s]*\] (.*)$', dotAll: true);
final _tunIn = RegExp(r'^inbound/tun\[[^\]]*\]: inbound (DNS packet|packet connection|connection)\b');
final _otherIn = RegExp(r'^inbound/\w+\[[^\]]*\]: .*?\binbound (?:DNS packet|packet connection|connection)\b');
final _found = RegExp(r'^router: found (?:package name|process path): (.+)$');

/// What the raw lines say about the traffic that entered through the TUN, per application: how
/// often sing-box looked up the program behind a connection (`syn`) and how often it never made a
/// connection of it (`orphan`) — the signature of TCP that dies between the TUN and the router.
///
/// The pairing is the live detector's ([TunIngressDetector], the same lines, window and capacities):
/// the look-up of a connection is a line of its own with an id of its own, right next to the line
/// of the connection, so a `found …` line is paired with a connection line within
/// [TunIngressDetector.pairLines] lines (a TCP connection takes two, others one); the ones nobody
/// takes are orphans. A `found …` line of an id that has an inbound line of its own is not a look-up
/// at all (mixed / socks inbounds). Only lines of sing-box are counted, as the detector counts them.
///
/// → `{packages: [{package, syn, orphan}] (the [top] busiest by orphans, then syn), others: {packages,
/// syn, orphan} (the rest), total: {syn, orphan, tcp, udp, dns}, window: {lines, from, to}}`;
/// `window` is what the rings still held.
Map<String, dynamic> tunSummary(List<Map<String, dynamic>> lines, {int top = tunSummaryTop}) {
  final syn = <String, int>{}, orphan = <String, int>{};
  var tcp = 0, udp = 0, dns = 0, n = 0;
  final seen = <String>{};
  final reals = <_Real>[]; // lines within reach that still have room
  final pending = <_Orphan>[]; // look-ups within reach that nobody took
  int? from, to;

  void forget() {
    reals.removeWhere((r) => n - r.line > TunIngressDetector.pairLines);
    while (pending.isNotEmpty && n - pending.first.line > TunIngressDetector.pairLines) {
      final o = pending.removeAt(0);
      orphan[o.who] = (orphan[o.who] ?? 0) + 1;
    }
  }

  for (final l in lines) {
    if (l['src'] != 'sing-box') continue;
    final t = l['t'];
    if (t is int) {
      from = from == null || t < from ? t : from;
      to = to == null || t > to ? t : to;
    }
    n++;
    final msg = '${l['msg']}';
    if (!msg.contains('inbound') && !msg.contains('found p')) {
      forget();
      continue;
    }
    final m = _idRe.firstMatch(msg);
    if (m != null) {
      final id = m[1]!, body = m[2]!;
      final tin = _tunIn.firstMatch(body);
      if (tin != null) {
        if (seen.add(id)) {
          final type = tin[1]!;
          if (type == 'connection') {
            tcp++;
          } else if (type == 'packet connection') {
            udp++;
          } else {
            dns++;
          }
          var room = type == 'connection' ? TunIngressDetector.tcpCapacity : TunIngressDetector.otherCapacity;
          forget();
          for (final o in pending.reversed.toList()) {
            if (room == 0 || n - o.line > TunIngressDetector.pairLines) break;
            pending.remove(o);
            room--;
          }
          if (room > 0) reals.add(_Real(n, room));
        }
      } else if (_otherIn.hasMatch(body)) {
        seen.add(id);
      } else {
        final f = _found.firstMatch(body);
        if (f != null && !seen.contains(id)) {
          var who = f[1]!.trim();
          // a desktop path: the program, not where it lives
          final cut = who.lastIndexOf(RegExp(r'[\\/]'));
          if (cut >= 0 && cut < who.length - 1) who = who.substring(cut + 1);
          syn[who] = (syn[who] ?? 0) + 1;
          forget();
          var taken = false;
          for (final r in reals.reversed) {
            if (n - r.line > TunIngressDetector.pairLines) break;
            if (r.room > 0) {
              r.room--;
              taken = true;
              break;
            }
          }
          if (!taken) pending.add(_Orphan(n, who));
        }
      }
    }
    forget();
    if (seen.length > 4096) seen.remove(seen.first);
  }

  final apps = {...syn.keys, ...orphan.keys}.toList()
    ..sort((a, b) {
      final c = (orphan[b] ?? 0).compareTo(orphan[a] ?? 0);
      if (c != 0) return c;
      final d = (syn[b] ?? 0).compareTo(syn[a] ?? 0);
      return d != 0 ? d : a.compareTo(b);
    });
  int sum(Iterable<String> ks, Map<String, int> m) => ks.fold(0, (a, k) => a + (m[k] ?? 0));
  final rest = apps.skip(top).toList();
  return {
    'packages': [
      for (final a in apps.take(top)) {'package': a, 'syn': syn[a] ?? 0, 'orphan': orphan[a] ?? 0},
    ],
    'others': {'packages': rest.length, 'syn': sum(rest, syn), 'orphan': sum(rest, orphan)},
    'total': {'syn': sum(apps, syn), 'orphan': sum(apps, orphan), 'tcp': tcp, 'udp': udp, 'dns': dns},
    'window': {'lines': n, 'from': from, 'to': to},
  };
}

class _Real {
  _Real(this.line, this.room);
  final int line;
  int room;
}

class _Orphan {
  _Orphan(this.line, this.who);
  final int line;
  final String who;
}

// ── plain text ──

/// [report] as text for reading: a header with the state, then the events and the raw log, time
/// first (UTC), one line each. What "Download log" writes; the structured map stays the exact form.
String reportToText(Map<String, dynamic> report) {
  final b = StringBuffer();
  String ts(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true).toIso8601String() : '?';
  void section(String title, Object? v) {
    if (v == null) return;
    if (v is Map && v.isEmpty) return;
    b.writeln('## $title');
    if (v is Map) {
      for (final e in v.entries) {
        final x = e.value;
        if (x == null) continue;
        b.writeln('${e.key}: ${x is Map || x is List ? jsonEncode(x) : x}');
      }
    } else {
      b.writeln('$v');
    }
    b.writeln();
  }

  b.writeln('Jormungand report (format ${report['format']})');
  b.writeln('created: ${report['createdAt']}');
  b.writeln();
  section('App', report['app']);
  section('Core', report['core']);
  section('Connection', report['connection']);
  section('Settings', report['settings']);
  section('Network', report['network']);
  final counters = report['counters'];
  if (counters is Map) {
    section('TUN by application', counters['tun']);
    section('Failed connections', counters['failures']);
    section('TUN ingress', counters['tunIngress']);
    section('Rings', counters['rings']);
  }
  section('Redactions', report['redactions']);

  final events = report['events'];
  if (events is List) {
    b.writeln('## Events (${events.length})');
    for (final e in events) {
      if (e is! Map) continue;
      final data = e['data'];
      final tags = [if (e['own'] == true) 'own', if (e['bg'] == true) 'bg'];
      b.write('${ts(e['at'])} ${e['level']} ${e['cat']}/${e['type']}');
      if (tags.isNotEmpty) b.write(' (${tags.join(', ')})');
      if (e['log'] != null) b.write(' #${e['log']}');
      if (data is Map && data.isNotEmpty) b.write(' ${jsonEncode(data)}');
      b.writeln();
    }
    b.writeln();
  }

  final raw = report['raw'];
  if (raw is List) {
    b.writeln('## Raw log (${raw.length} lines)');
    for (final l in raw) {
      if (l is! Map) continue;
      b.writeln('${l['n']} ${ts(l['t'])} ${l['src']} ${l['lvl']} ${l['msg']}');
    }
  }
  return b.toString();
}
