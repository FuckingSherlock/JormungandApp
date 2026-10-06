/// The settings objects of the snapshot that the connect plan reads: `segState` (Home
/// segments), `connCfg` (Settings → Connection), `autoCfg` (Settings → Auto mode).
/// Like the mockup's `Object.assign(cfg, snapshot.cfg)` on load, a missing key takes the
/// default, and the whole object is written back.
///
/// Not ported: `genCfg`, `notifCfg`, `logCfg` (UI settings, no part in the plan) — the
/// [Catalog] keeps them as they were, in its `unknown` map.
library;

import '../config.dart' show defaultCheckers;
import 'json_util.dart';

T _get<T>(Json j, String k, T def) => j[k] is T ? j[k] as T : def;

/// Home segments (`segState`): `mode` proxy | tun, `route` rules | global, `sys` (system
/// proxy) on | off.
class SegState with RoundTrip {
  SegState({this.mode = 'proxy', this.route = 'rules', this.sys = 'off'});

  factory SegState.fromJson(Json j) {
    final s = SegState(mode: _get(j, 'mode', 'proxy'), route: _get(j, 'route', 'rules'), sys: _get(j, 'sys', 'off'));
    s.capture(j, _known);
    return s;
  }

  static const _known = {'mode', 'route', 'sys'};

  String mode;
  String route;
  String sys;

  bool get tun => mode == 'tun';
  bool get global => route == 'global';
  bool get systemProxy => sys == 'on';

  Json toJson() => {'mode': mode, 'route': route, 'sys': sys, ...deepCopy(unknown) as Json};
}

/// Settings → Connection. Kill-switch fields only travel with the snapshot (the core reads
/// them from the connect body, not from the plan); the plan reads `port`, `proxyAuth` /
/// `proxyUser` / `proxyPass`, `testUrl`, `checkers`, `tunStack`, `ipv6`.
class ConnCfg with RoundTrip {
  ConnCfg({
    this.sysProxy = false,
    this.killSwitch = false,
    this.killOnDisconnect = false,
    this.killWhileClosed = false,
    this.downProxy = 'remove',
    this.port = 2080,
    this.proxyAuth = false,
    this.proxyUser = '',
    this.proxyPass = '',
    this.testUrl = '',
    List<String>? checkers,
    this.tunStack = 'mixed',
    this.ipv6 = false,
  }) : checkers = checkers ?? [...defaultCheckers];

  factory ConnCfg.fromJson(Json j) {
    final c = ConnCfg(
      sysProxy: _get(j, 'sysProxy', false),
      killSwitch: _get(j, 'killSwitch', false),
      killOnDisconnect: _get(j, 'killOnDisconnect', false),
      killWhileClosed: _get(j, 'killWhileClosed', false),
      downProxy: _get(j, 'downProxy', 'remove'),
      port: j['port'] is num ? (j['port'] as num).toInt() : 2080,
      proxyAuth: _get(j, 'proxyAuth', false),
      proxyUser: _get(j, 'proxyUser', ''),
      proxyPass: _get(j, 'proxyPass', ''),
      testUrl: _get(j, 'testUrl', ''),
      checkers: j['checkers'] is List ? strList(j['checkers']) : null,
      tunStack: _get(j, 'tunStack', 'mixed'),
      ipv6: _get(j, 'ipv6', false),
    );
    c.capture(j, _known);
    return c;
  }

  static const _known = {
    'sysProxy', 'killSwitch', 'killOnDisconnect', 'killWhileClosed', 'downProxy', 'port', 'proxyAuth', 'proxyUser', 'proxyPass', //
    'testUrl', 'checkers', 'tunStack', 'ipv6',
  };

  bool sysProxy;
  bool killSwitch;
  bool killOnDisconnect;
  bool killWhileClosed;
  String downProxy;
  int port;
  bool proxyAuth;
  String proxyUser;
  String proxyPass;

  /// Latency test URL; empty = the core's default.
  String testUrl;

  /// Backup checks (URLs).
  List<String> checkers;
  String tunStack;

  /// IPv6 through the tunnel (TUN address and AAAA answers); off by default.
  bool ipv6;

  Json toJson() => {
        'sysProxy': sysProxy,
        'killSwitch': killSwitch,
        'killOnDisconnect': killOnDisconnect,
        'killWhileClosed': killWhileClosed,
        'downProxy': downProxy,
        'port': port,
        'proxyAuth': proxyAuth,
        'proxyUser': proxyUser,
        'proxyPass': proxyPass,
        'testUrl': testUrl,
        'checkers': [...checkers],
        'tunStack': tunStack,
        'ipv6': ipv6,
        ...deepCopy(unknown) as Json,
      };
}

/// Settings → Auto mode (docs/connect-model.md → «Auto / Manual»). Times in seconds,
/// except `flapMax` / `flapReset` (minutes) as in the table there.
class AutoCfg with RoundTrip {
  AutoCfg({
    this.threshold = 50,
    this.checkEvery = 60,
    this.failAfter = 2,
    this.standby = 2,
    this.warmEvery = 60,
    this.retryPause = 0.5,
    this.returnTo = 'always',
    this.flapGuard = true,
    this.flapMax = 30,
    this.flapReset = 15,
    this.siteRetry = '3',
    this.pauseScreenOff = true,
    this.speedOnFail = false,
    this.subsEvery = 12 * 3600,
  });

  factory AutoCfg.fromJson(Json j) {
    final c = AutoCfg(
      threshold: _get<num>(j, 'threshold', 50),
      checkEvery: _get<num>(j, 'checkEvery', 60),
      failAfter: _get<num>(j, 'failAfter', 2),
      standby: _get<num>(j, 'standby', 2),
      warmEvery: _get<num>(j, 'warmEvery', 60),
      retryPause: _get<num>(j, 'retryPause', 0.5),
      returnTo: _get(j, 'returnTo', 'always'),
      flapGuard: _get(j, 'flapGuard', true),
      flapMax: _get<num>(j, 'flapMax', 30),
      flapReset: _get<num>(j, 'flapReset', 15),
      siteRetry: j['siteRetry'] == null ? '3' : '${j['siteRetry']}',
      pauseScreenOff: _get(j, 'pauseScreenOff', true),
      speedOnFail: _get(j, 'speedOnFail', false),
      subsEvery: _get<num>(j, 'subsEvery', 12 * 3600),
    );
    c.capture(j, _known);
    return c;
  }

  static const _known = {
    'threshold', 'checkEvery', 'failAfter', 'standby', 'warmEvery', 'retryPause', 'returnTo', 'flapGuard', 'flapMax', 'flapReset', //
    'siteRetry', 'pauseScreenOff', 'speedOnFail', 'subsEvery',
  };

  num threshold;
  num checkEvery;
  num failAfter;
  num standby;
  num warmEvery;
  num retryPause;

  /// `always` | `faster` | `never`.
  String returnTo;
  bool flapGuard;
  num flapMax;
  num flapReset;

  /// `off` | `3` | `all`.
  String siteRetry;
  bool pauseScreenOff;
  bool speedOnFail;
  num subsEvery;

  Json toJson() => {
        'threshold': threshold,
        'checkEvery': checkEvery,
        'failAfter': failAfter,
        'standby': standby,
        'warmEvery': warmEvery,
        'retryPause': retryPause,
        'returnTo': returnTo,
        'flapGuard': flapGuard,
        'flapMax': flapMax,
        'flapReset': flapReset,
        'siteRetry': siteRetry,
        'pauseScreenOff': pauseScreenOff,
        'speedOnFail': speedOnFail,
        'subsEvery': subsEvery,
        ...deepCopy(unknown) as Json,
      };
}
