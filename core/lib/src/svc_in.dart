/// The inbound the core's own service traffic (subscriptions, rule lists, app updates, the report)
/// goes out through, so that one request can be raced over several paths ([ServiceFetch], svc_fetch.dart).
///
/// `svc-in` is a loopback `mixed` inbound of the main config. Every path is a user of it: the login is
/// an opaque `u0`, `u1`, … (a tag holds `:` `/` `[`, which break a proxy URL), the password is random
/// per start, so no other program on the machine can use the inbound. A route rule per user, first of
/// all in `route.rules` (like the probe's, probe.dart), sends the user's connections to its outbound:
/// `direct`, the main flow `proxy` (the route Auto is on) or one route group `route<i>` — past every
/// rule of the user, the same as `tunnel-in`. The table login → path is made with the config; the port,
/// the secret and the table are kept with the adoptable runner's record, so an adopted sing-box keeps working.
library;

import 'dart:math';

const svcInboundTag = 'svc-in';

/// Where a path leads.
enum SvcKind {
  /// Out of the core's sing-box straight to the Internet, past the tunnel.
  direct,

  /// The main flow (the selector Auto moves between the routes): what a rule "via VPN" means.
  main,

  /// One route (a group of the plan) by itself, whatever Auto has picked.
  route,
}

/// One way out of [SvcIn]: [id] is stable (`direct`, `main`, `route0`), [tag] the sing-box outbound,
/// [login] the user name of the inbound.
class SvcPath {
  const SvcPath(this.id, this.kind, this.tag, this.login);

  final String id;
  final SvcKind kind;
  final String tag;
  final String login;

  /// Through the core's sing-box into the tunnel (anything but direct).
  bool get tunnel => kind != SvcKind.direct;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind.name, 'tag': tag, 'login': login};

  static SvcPath fromJson(Map j) => SvcPath(
        '${j['id']}',
        SvcKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => SvcKind.route),
        '${j['tag']}',
        '${j['login']}',
      );

  @override
  String toString() => 'SvcPath($id)';
}

class SvcIn {
  SvcIn(this.port, [String? secret, List<SvcPath>? paths])
      : secret = secret ?? _newSecret(),
        paths = paths ?? [];

  final int port;
  final String secret;

  /// The table, filled by [inbound] (and by [fromJson]); empty = the inbound has no users.
  List<SvcPath> paths;

  /// The inbound and its route rules (to go first). [routes]: the tags of the route groups, in order;
  /// path ids are `route<i>` by position, so they are stable while the plan keeps its routes.
  ({Map<String, dynamic> inbound, List<Map<String, dynamic>> rules}) inbound({required String direct, required String main, required List<String> routes}) {
    final all = <SvcPath>[];
    String login() => 'u${all.length}';
    all.add(SvcPath('direct', SvcKind.direct, direct, login()));
    all.add(SvcPath('main', SvcKind.main, main, login()));
    for (var i = 0; i < routes.length; i++) {
      all.add(SvcPath('route$i', SvcKind.route, routes[i], login()));
    }
    paths = all;
    return (
      inbound: {
        'type': 'mixed',
        'tag': svcInboundTag,
        'listen': '127.0.0.1',
        'listen_port': port,
        'users': [for (final p in all) {'username': p.login, 'password': secret}],
      },
      rules: [
        for (final p in all) {'inbound': [svcInboundTag], 'auth_user': [p.login], 'action': 'route', 'outbound': p.tag},
      ],
    );
  }

  /// The `findProxy` answer that sends a request through [path].
  String proxyFor(SvcPath path) => 'PROXY ${path.login}:$secret@127.0.0.1:$port';

  SvcPath? path(String id) {
    for (final p in paths) {
      if (p.id == id) return p;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {'port': port, 'secret': secret, 'paths': [for (final p in paths) p.toJson()]};

  /// The record of [toJson]; null when it holds no usable inbound (a record of a core before this existed).
  static SvcIn? fromJson(Object? j) {
    if (j is! Map || j['port'] is! num || j['secret'] is! String) return null;
    final paths = [for (final p in (j['paths'] as List? ?? const [])) if (p is Map) SvcPath.fromJson(p)];
    return SvcIn((j['port'] as num).toInt(), j['secret'] as String, paths);
  }

  static String _newSecret() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}
