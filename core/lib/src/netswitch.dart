/// The network the platform reports right now (what the phone is connected through).
/// [type]: `wifi`, `mobile`, `ethernet` (anything else is kept as is). [id] tells two networks of one type apart
/// (Wi-Fi BSSID / network id), null when the platform gives none. [operator]: the SIM operator of a mobile network.
class NetInfo {
  final String type;
  final String? id;
  final String? operator;
  final bool? metered;
  const NetInfo({required this.type, this.id, this.operator, this.metered});
}

/// A network switch found at a settle: [data] is what `net/switched` holds at once (no provider of the new network),
/// [completed] ends with the full `data` once the ISP lookup is through, or null when it added nothing.
class NetSwitch {
  final Map<String, Object?> data;
  final Future<Map<String, Object?>?> completed;
  NetSwitch(this.data, this.completed);
}

/// Notices that the network changed (docs/logs.md "Смена сети") and builds the `data` of `net/switched`.
/// Pure logic, no I/O: the caller feeds every platform change into [onNetwork] and asks [onSettled] when the new
/// network has settled (failures.md "Смена сети: возмущение, ворота, устойчивость"); the ISP lookup is passed in.
class NetSwitchTracker {
  /// The machine's direct public IP and ISP (`directIsp`); null when nobody answered.
  final Future<({String ip, String? org})?> Function() lookup;

  /// The "detect the network provider" setting, read at the moment of each settle.
  final bool Function() providerEnabled;

  /// [now] is accepted for the owner's convenience; event times come from [onNetwork]'s `at`.
  NetSwitchTracker({required this.lookup, required this.providerEnabled, DateTime Function()? now});

  NetInfo? _current; // what the platform reports now; null = no network
  NetInfo? _settled; // the last network that settled
  bool _hasSettled = false;

  // time without any network since the last settle: finished intervals plus the one running
  Duration _down = Duration.zero;
  DateTime? _downSince;
  bool _wasDown = false;

  // ISP per network: where it was seen last (IP) and the organisation
  final Map<String, ({String ip, String? org})> _isp = {};

  /// Every network change from the platform; [net] null = no network.
  void onNetwork(NetInfo? net, DateTime at) {
    _current = net;
    if (net == null) {
      if (_downSince == null) {
        _downSince = at;
        _wasDown = true;
      }
    } else if (_downSince != null) {
      final d = at.difference(_downSince!);
      if (!d.isNegative) _down += d;
      _downSince = null;
    }
  }

  // the lookup for the first network (not a switch): its provider is remembered for the next "from"
  Future<void> _baseline = Future.value();

  /// The network has settled: the switch to tell, or null when it is not one (the first network after start, no
  /// network at all, a gap with a return to the same network). The switch is known at once ([NetSwitch.data], without
  /// the new network's provider); the ISP lookup of a new Wi-Fi / Ethernet network (when [providerEnabled]) runs on
  /// and ends in [NetSwitch.completed].
  NetSwitch? onSettled() {
    final to = _current;
    if (to == null) return null; // still no network: conn/offline says it, the gap stays counted
    final from = _settled;
    final hadSettled = _hasSettled;
    final downMs = _wasDown ? _down.inMilliseconds : null;
    _settled = to;
    _hasSettled = true;
    _down = Duration.zero;
    _wasDown = false;

    final enabled = providerEnabled();
    if (!hadSettled || from == null) {
      if (enabled && _hasIsp(to)) _baseline = _lookupIsp(to).then((_) {});
      return null;
    }
    if (!_differs(from, to)) return null;

    final pending = _baseline;
    final withIsp = enabled && _hasIsp(to);
    final fromIsp = enabled && _hasIsp(from);
    final knownFrom = fromIsp ? _isp[_key(from)]?.org : null;
    Map<String, Object?> build(String? fromProvider, String? toProvider) => {
          'from': _side(from, fromProvider),
          'to': _side(to, toProvider),
          'downMs': ?downMs,
        };
    Future<Map<String, Object?>?> finish() async {
      await pending;
      final toProvider = withIsp ? await _lookupIsp(to) : null;
      final fromProvider = fromIsp ? _isp[_key(from)]?.org : null;
      return toProvider == null && fromProvider == knownFrom ? null : build(fromProvider, toProvider);
    }

    return NetSwitch(build(knownFrom, null), finish());
  }

  /// Another type, or another id of the same type; an unknown id (null) never makes a difference by itself.
  static bool _differs(NetInfo a, NetInfo b) =>
      a.type != b.type || (a.id != null && b.id != null && a.id != b.id);

  static bool _hasIsp(NetInfo n) => n.type == 'wifi' || n.type == 'ethernet';

  static String _key(NetInfo n) => '${n.type}:${n.id ?? ''}';

  Map<String, Object?> _side(NetInfo n, String? provider) => {
        'type': n.type,
        'provider': ?provider,
        'operator': ?(_nonEmpty(n.operator)),
        'metered': ?n.metered,
      };

  static String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

  /// Asks for the ISP of [n]. The cache keeps the IP of the last answer per network: an answer with the same
  /// IP and no organisation keeps the known one; a failed lookup falls back to what is remembered for this network.
  Future<String?> _lookupIsp(NetInfo n) async {
    final key = _key(n);
    final known = n.id == null ? null : _isp[key];
    ({String ip, String? org})? got;
    try {
      got = await lookup();
    } catch (_) {
      got = null;
    }
    if (got == null) return _nonEmpty(known?.org);
    final org = _nonEmpty(got.org) ?? (known?.ip == got.ip ? _nonEmpty(known?.org) : null);
    if (n.id != null) _isp[key] = (ip: got.ip, org: org);
    return org;
  }
}
