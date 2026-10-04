import 'dart:math' as math;

import 'package:jormungand_core/jormungand_core.dart'
    show Catalog, DnsServerCfg;

import '../l10n/l10n.dart';
import 'core_host.dart';

/// The pure part of the Settings tab: typed views over the settings the catalog keeps as plain
/// maps (`genCfg`, `notifCfg` live in [Catalog.unknown], the core only carries them), the
/// validation of the typed fields and the DNS list rules. The mockup's 55-automode.js,
/// 56-dns.js, 57-general.js, 58-notif.js and 59-data.js, without the HTML.

// ───────────────────────────── genCfg / notifCfg ─────────────────────────────

/// A map of [Catalog.unknown] that is created on the first write.
Map<String, dynamic> _slot(Catalog c, String key) {
  final v = c.unknown[key];
  if (v is Map<String, dynamic>) return v;
  final m = v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  c.unknown[key] = m;
  return m;
}

/// `genCfg`: Language, startup, clipboard, the app update options, the Nodes sort, and the look
/// (the mockup keeps theme / text size in the browser; the app keeps them here, so a backup
/// carries them). A missing key reads as its default.
class GenCfg {
  GenCfg(this._m);

  final Map<String, dynamic> _m;

  /// `en` | `ru`; null = never chosen (the system language decides).
  String? get lang => _m['lang'] is String ? _m['lang'] as String : null;
  set lang(String? v) => _m['lang'] = v;

  bool get launchAtStartup => _m['launchAtStartup'] == true;
  set launchAtStartup(bool v) => _m['launchAtStartup'] = v;

  /// Desktop: start in the tray.
  bool get startMinimized => _m['startMinimized'] != false;
  set startMinimized(bool v) => _m['startMinimized'] = v;

  bool get connectOnLaunch => _m['connectOnLaunch'] == true;
  set connectOnLaunch(bool v) => _m['connectOnLaunch'] = v;

  bool get pingOnLaunch => _m['pingOnLaunch'] != false;
  set pingOnLaunch(bool v) => _m['pingOnLaunch'] = v;

  /// Offer to import a subscription / server link found in the clipboard.
  bool get clipboard => _m['clipboard'] != false;
  set clipboard(bool v) => _m['clipboard'] = v;

  /// Auto-check for app updates.
  bool get updates => _m['updates'] != false;
  set updates(bool v) => _m['updates'] = v;

  /// `stable` | `beta`.
  String get updChannel => _m['updChannel'] == 'beta' ? 'beta' : 'stable';
  set updChannel(String v) => _m['updChannel'] = v;

  /// Theme id (`AppThemeId.name`); null = never chosen.
  String? get theme => _m['theme'] is String ? _m['theme'] as String : null;
  set theme(String? v) => _m['theme'] = v;

  /// Text size 0.9-1.2; null = never chosen.
  double? get uiScale => _m['uiScale'] is num ? (_m['uiScale'] as num).toDouble() : null;
  set uiScale(double? v) => _m['uiScale'] = v;
}

/// `notifCfg`: what the app may tell the user on its own (Settings -> Notifications).
class NotifCfg {
  NotifCfg(this._m);

  final Map<String, dynamic> _m;

  static const Map<String, bool> defaults = {
    'enabled': true,
    'status': true,
    'autoSwitch': true,
    'unstable': true,
    'connLost': true,
    'coreCrash': false,
    'blocked': true,
    'subUpdated': false,
    'subFailed': true,
    'ruleSets': true,
  };

  /// The toggles of the three groups, in the order of the sheet.
  static const List<String> statusKeys = ['status'];
  static const List<String> connectionKeys = [
    'autoSwitch',
    'unstable',
    'connLost',
    'coreCrash',
    'blocked',
  ];
  static const List<String> subscriptionKeys = [
    'subUpdated',
    'subFailed',
    'ruleSets',
  ];
  static const List<String> allKeys = [
    ...statusKeys,
    ...connectionKeys,
    ...subscriptionKeys,
  ];

  bool flag(String key) => _m[key] is bool ? _m[key] as bool : (defaults[key] ?? false);
  void setFlag(String key, bool v) => _m[key] = v;

  bool get enabled => flag('enabled');

  /// PC: `own` pop-ups in the corner or `system` notifications.
  String get desktopStyle => _m['desktopStyle'] == 'system' ? 'system' : 'own';
  set desktopStyle(String v) => _m['desktopStyle'] = v;

  /// How many of [allKeys] are on.
  int get onCount => allKeys.where(flag).length;
}

extension SettingsOfHost on CoreHost {
  GenCfg get gen => GenCfg(_slot(catalog, 'genCfg'));
  NotifCfg get notif => NotifCfg(_slot(catalog, 'notifCfg'));
}

// ───────────────────────────── Auto mode ─────────────────────────────

/// The ranges of the typed fields of Settings -> Auto mode.
const int autoThresholdMax = 1000;
const int autoFailAfterMin = 1;
const int autoFailAfterMax = 5;
const int autoStandbyMax = 20;

/// Typed numbers: `retryPause` in tenths of a second, the flap values in whole minutes.
class AutoNum {
  const AutoNum(this.min, this.max, this.tenths);

  final num min;
  final num max;
  final bool tenths;
}

const Map<String, AutoNum> autoNums = {
  'retryPause': AutoNum(0.1, 10, true),
  'flapMax': AutoNum(1, 60, false),
  'flapReset': AutoNum(5, 60, false),
};

/// Whole milliseconds 0..1000, else null.
int? parseThreshold(String raw) {
  final s = raw.trim();
  final v = int.tryParse(s);
  if (v == null || v < 0 || v > autoThresholdMax) return null;
  return v;
}

/// A typed [autoNums] value ([raw] may use a comma), else null.
num? parseAutoNum(String key, String raw) {
  final spec = autoNums[key];
  final s = raw.trim().replaceAll(',', '.');
  final v = double.tryParse(s);
  if (spec == null || s.isEmpty || v == null || !v.isFinite) return null;
  if (v < spec.min || v > spec.max) return null;
  if (spec.tenths) {
    if ((v * 10 - (v * 10).round()).abs() > 1e-9) return null;
    return (v * 10).round() / 10;
  }
  return v == v.roundToDouble() ? v.toInt() : null;
}

/// A number the way the field shows it: `0.5`, `30`.
String fmtNum(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

/// The dialog of a period: a number + a unit, stored in seconds.
class IntervalLimits {
  const IntervalLimits({
    required this.units,
    required this.min,
    required this.max,
    this.off = false,
  });

  /// `(l10n name, seconds)`; the first is the base unit.
  final List<(String, int)> units;
  final int min;
  final int max;

  /// 0 is allowed (off).
  final bool off;
}

const Map<String, IntervalLimits> intervals = {
  'checkEvery': IntervalLimits(
    units: [('seconds', 1), ('minutes', 60)],
    min: 10,
    max: 3600,
  ),
  'warmEvery': IntervalLimits(
    units: [('seconds', 1), ('minutes', 60)],
    min: 10,
    max: 3600,
  ),
  'subsEvery': IntervalLimits(
    units: [('seconds', 1), ('minutes', 60), ('hours', 3600), ('days', 86400)],
    min: 10,
    max: 30 * 86400,
    off: true,
  ),
};

/// The multiplier a [seconds] value opens in: the largest unit that divides it (an off value opens
/// in hours).
int intervalUnitFor(IntervalLimits c, num seconds) {
  if (seconds > 0) {
    for (final (_, m) in c.units.reversed) {
      if (seconds % m == 0) return m;
    }
  }
  for (final (_, m) in c.units) {
    if (m == 3600) return 3600;
  }
  return c.units.first.$2;
}

/// Seconds from the dialog's number + unit, or null when it is not allowed.
int? parseInterval(IntervalLimits c, String raw, int unit) {
  final s = raw.trim().replaceAll(',', '.');
  final n = double.tryParse(s);
  if (s.isEmpty || n == null || !n.isFinite) return null;
  final v = n * unit;
  if (v != v.roundToDouble()) return null;
  final i = v.round();
  if (i == 0 && c.off) return 0;
  if (i < c.min || i > c.max) return null;
  return i;
}

/// A period in seconds in the largest unit that divides it: `90 s`, `5 min`, `12 h`, `2 d`.
String fmtEvery(AppLocalizations l10n, num seconds) {
  final s = seconds.round();
  if (s > 0 && s % 86400 == 0) return l10n.d(s ~/ 86400);
  if (s > 0 && s % 3600 == 0) return l10n.h(s ~/ 3600);
  if (s > 0 && s % 60 == 0) return l10n.min(s ~/ 60);
  return l10n.s(s);
}

// ───────────────────────────── Connection ─────────────────────────────

const int proxyLoginMax = 64;
const int proxyPassMin = 4;
const int proxyPassMax = 128;

/// Ports the app itself holds (jormd, the core's Clash API): not offered to the proxy port.
const List<int> reservedPorts = [7788, 9090];

/// A port 1024..65535 from the field (digits only), else null; [reservedPorts] are not refused
/// here, the caller says which message to show.
int? parsePort(String raw) {
  final s = raw.trim();
  if (!RegExp(r'^\d+$').hasMatch(s)) return null;
  final v = int.tryParse(s);
  return v != null && v >= 1024 && v <= 65535 ? v : null;
}

enum CredProblem { empty, spaces, colon, tooLong, tooShort }

/// null = fine. [user] is the login, else the password.
CredProblem? proxyCredProblem({required bool user, required String v}) {
  if (v.isEmpty) return CredProblem.empty;
  if (RegExp(r'\s').hasMatch(v)) return CredProblem.spaces;
  if (user) {
    if (v.contains(':')) return CredProblem.colon;
    if (v.length > proxyLoginMax) return CredProblem.tooLong;
  } else {
    if (v.length < proxyPassMin) return CredProblem.tooShort;
    if (v.length > proxyPassMax) return CredProblem.tooLong;
  }
  return null;
}

String _token(int n, String alphabet, math.Random r) =>
    String.fromCharCodes([
      for (var i = 0; i < n; i++) alphabet.codeUnitAt(r.nextInt(alphabet.length)),
    ]);

String newProxyLogin([math.Random? r]) => _token(
  8,
  'abcdefghjkmnpqrstuvwxyz23456789',
  r ?? math.Random.secure(),
);
String newProxySecret([math.Random? r]) => _token(
  20,
  'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789',
  r ?? math.Random.secure(),
);

/// What a program is told to use: `socks5://login:password@127.0.0.1:port` or `http://...`
/// (credentials percent-encoded; none while the password is off).
String proxyUrl(String scheme, {required int port, String? user, String? pass}) {
  final auth = user != null && pass != null
      ? '${Uri.encodeComponent(user)}:${Uri.encodeComponent(pass)}@'
      : '';
  return '$scheme://${auth}127.0.0.1:$port';
}

/// The three TUN stacks (sing-box `tun.stack`); the names are not translated.
const List<(String, String)> tunStacks = [
  ('mixed', 'Mixed'),
  ('system', 'System'),
  ('gvisor', 'gVisor'),
];

/// Latency test URL presets: `(url, name, host hint)`; the empty URL is the core's default.
const List<(String, String, String)> testUrlPresets = [
  ('', 'Default', 'www.gstatic.com/generate_204 (Google)'),
  (
    'https://cp.cloudflare.com/generate_204',
    'Cloudflare',
    'cp.cloudflare.com/generate_204',
  ),
  (
    'http://www.msftconnecttest.com/connecttest.txt',
    'Microsoft',
    'www.msftconnecttest.com',
  ),
  (
    'http://detectportal.firefox.com/success.txt',
    'Mozilla',
    'detectportal.firefox.com',
  ),
  (
    'http://captive.apple.com/hotspot-detect.html',
    'Apple',
    'captive.apple.com',
  ),
];

/// The backup checks' presets: the test URL services, the default being Google's gstatic.
List<(String, String, String)> checkerPresets() => [
  for (final (u, name, hint) in testUrlPresets)
    (
      u.isEmpty ? 'https://www.gstatic.com/generate_204' : u,
      name == 'Default' ? 'Google' : name,
      hint.replaceFirst(' (Google)', ''),
    ),
];

final RegExp _httpUrl = RegExp(r'^https?://[^\s/?#]+\.[^\s/?#]+', caseSensitive: false);

/// An http(s) address a test URL / backup check may be.
bool validTestUrl(String v) => _httpUrl.hasMatch(v);

/// The host of an address, or [url] itself.
String hostOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.isEmpty ? url : h;
}

// ───────────────────────────── DNS ─────────────────────────────

final RegExp dnsAddrRe = RegExp(
  r'^(system|(udp|tcp|tls|https|quic)://[^\s/]+(/\S*)?|\d{1,3}(\.\d{1,3}){3}(:\d+)?)$',
);

/// `system` | `doh` | `dot` | `doq` | `tcp` | `udp` (a bare IP is UDP).
String dnsKind(String addr) {
  if (addr == 'system') return 'system';
  final m = RegExp(r'^(\w+)://').firstMatch(addr);
  return switch (m?.group(1)) {
    'https' => 'doh',
    'tls' => 'dot',
    'quic' => 'doq',
    'tcp' => 'tcp',
    _ => 'udp',
  };
}

/// The name of a server made from its address when none is typed.
String dnsNameFromAddr(String addr) =>
    addr.replaceFirst(RegExp(r'^\w+://'), '').split('/').first;

extension DnsOfCatalog on Catalog {
  /// The ticked servers in priority order.
  List<DnsServerCfg> get dnsActive => [
    for (final id in dnsOrder)
      if (dnsServers[id]?.on == true) dnsServers[id]!,
  ];

  /// The server a rule's DNS "Auto" resolves to: the first ticked one with this route.
  DnsServerCfg? dnsAutoFor(String via) {
    for (final s in dnsActive) {
      if (s.via == via) return s;
    }
    return null;
  }

  /// "Resolve for IP rules" as it works now: `off`, a ticked server's id, or `auto`.
  String get dnsResolveEff {
    final r = dnsCfg.resolve;
    if (r == 'off') return 'off';
    return dnsActive.any((s) => s.id == r) ? r : 'auto';
  }

  /// Ticks / unticks; false when it would leave no server on.
  bool dnsToggle(String id) {
    final s = dnsServers[id];
    if (s == null) return false;
    if (s.on && dnsActive.length == 1) return false;
    s.on = !s.on;
    return true;
  }

  /// Adds ([id] null) or edits a server; returns its id.
  String dnsSave(
    String? id, {
    required String name,
    required String addr,
    required String via,
  }) {
    final n = name.trim().isEmpty ? dnsNameFromAddr(addr) : name.trim();
    final s = id == null ? null : dnsServers[id];
    if (s != null) {
      s
        ..name = n
        ..addr = addr
        ..via = via;
      return s.id;
    }
    final nid = 'dns${dnsSeq++}';
    dnsServers[nid] = DnsServerCfg(id: nid, name: n, addr: addr, via: via);
    dnsOrder.add(nid);
    return nid;
  }

  /// Deletes a server; false when it is the only one on.
  bool dnsDelete(String id) {
    final s = dnsServers[id];
    if (s == null) return true;
    if (s.on && dnsActive.length == 1) return false;
    dnsServers.remove(id);
    dnsOrder.remove(id);
    return true;
  }

  void dnsReorder(List<String> order) {
    dnsOrder
      ..clear()
      ..addAll(order.where(dnsServers.containsKey));
  }
}
