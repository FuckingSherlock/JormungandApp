/// sing-box's API service (1.14+): a gRPC server in the config (`services: [{type: api}]`)
/// with the interface the official clients use. The messages are generated from sing-box's
/// own `daemon/started_service.proto` (tool/gen_sbapi.sh, pinned to the sing-box release
/// in tool/bin). It is the core's only line to a running sing-box (no Clash API):
///
/// - streams it keeps open while sing-box runs: connections (a live table: every open
///   connection with its server, app and byte counters; the closed ones as events),
///   groups (which server each selector / urltest uses, urltest results — pushed after
///   every urltest round) and status (speed, session totals, memory);
/// - commands: select in a selector, urltest a group, close connections, the service
///   state (started / fatal with the reason) and the config's deprecation warnings;
/// - Speed Test through one outbound (sing-box's network quality test).
library;

import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart';

import 'sbapi/started_service.pbgrpc.dart';

export 'sbapi/started_service.pb.dart' show Connection, ConnectionEvent, ConnectionEvents, NetworkQualityTestProgress, Status;
export 'sbapi/started_service.pbenum.dart' show ConnectionEventType;

/// A connection sing-box closed, as the core judges request failures by it.
class ClosedConnection {
  const ClosedConnection(
      {required this.outbound, required this.chain, required this.destination, required this.up, required this.down, this.rule = '', this.process = ''});

  /// The server's outbound tag (the leaf, e.g. `route0/<key>`); [chain] = leaf … `proxy`.
  final String outbound;
  final List<String> chain;
  final String destination; // host:port (the domain when there is one)
  final int up, down; // bytes in total

  /// The rule sing-box matched, as it reports it (see rulenames.dart; '' = none, the final route) and
  /// the path of the app that made the request ('' = unknown).
  final String rule, process;

  factory ClosedConnection.of(Connection c) => ClosedConnection(
        outbound: c.outbound,
        chain: List.of(c.chainList),
        destination: _dest(c),
        up: c.uplinkTotal.toInt(),
        down: c.downlinkTotal.toInt(),
        rule: c.rule,
        process: c.hasProcessInfo() ? c.processInfo.processPath : '',
      );
}

String _dest(Connection c) =>
    c.domain.isNotEmpty && !c.destination.startsWith(c.domain) ? '${c.domain}:${c.destination.split(':').last}' : c.destination;

/// An open connection as the connections stream keeps it.
class LiveConnection {
  LiveConnection(this.c)
      : up = c.uplinkTotal.toInt(),
        down = c.downlinkTotal.toInt();

  final Connection c;
  String get id => c.id;
  String get outbound => c.outbound; // the server (leaf)
  List<String> get chain => c.chainList; // leaf … the group the rule picked
  String get network => c.network;
  String get rule => c.rule;
  String get process => c.hasProcessInfo() ? c.processInfo.processPath : '';
  DateTime get start => DateTime.fromMillisecondsSinceEpoch(c.createdAt.toInt());

  /// host (the domain when there is one) and port.
  (String, String) get hostPort {
    final d = _dest(c), i = d.lastIndexOf(':');
    return i > 0 ? (d.substring(0, i).replaceAll(RegExp(r'^\[|\]$'), ''), d.substring(i + 1)) : (d, '');
  }

  int up, down; // bytes so far
  int upRate = 0, downRate = 0; // B/s over the last interval
}

/// A group as the groups stream shows it: the member in use, urltest results per member.
class BoxGroup {
  BoxGroup(this.tag, this.selected, this.members, this.results);
  BoxGroup.of(Group g)
      : tag = g.tag,
        selected = g.selected,
        members = [for (final i in g.items) i.tag],
        results = {for (final i in g.items) if (i.urlTestTime > 0) i.tag: (ms: i.urlTestDelay, at: i.urlTestTime.toInt())};
  final String tag, selected;
  final List<String> members;

  /// member tag → the last urltest (ms, at = Unix seconds); a member that failed has none.
  final Map<String, ({int ms, int at})> results;
}

/// What AutoService (auto.dart) asks of a running sing-box; a fake in tests.
abstract interface class BoxControl {
  /// group tag → the member it uses now; empty until the groups stream first answered.
  Map<String, String> get selected;

  /// A push of the groups stream (a urltest round, a pick): [selected] may have changed.
  Stream<void> get groupsChanged;

  /// Switches the selector [group] to [outbound]; false when sing-box refused or is gone.
  Future<bool> select(String group, String outbound);

  /// Has the urltest [group] test all its members and pick again; waits until it moved off
  /// [leaving] or every member has a fresh result, [timeout] at most. Member tag → ms of
  /// the ones that answered this time; null when sing-box refused.
  Future<Map<String, int>?> testGroup(String group, {String? leaving, required Duration timeout});

  /// The open connections now.
  Iterable<LiveConnection> get connections;

  Future<bool> closeConnection(String id);
}

class SingBoxApi implements BoxControl {
  SingBoxApi(int port, String secret)
      : _ch = ClientChannel('127.0.0.1', port: port, options: const ChannelOptions(credentials: ChannelCredentials.insecure())) {
    _c = StartedServiceClient(_ch, options: CallOptions(metadata: {'authorization': 'Bearer $secret'}));
  }

  final ClientChannel _ch;
  late final StartedServiceClient _c;
  bool _closed = false;
  final _subs = <StreamSubscription<Object?>>[];

  /// The service state: null = started; a message = it failed to start (FATAL); throws
  /// while the API does not answer yet (and for any other state).
  Future<String?> serviceState() async {
    final s = await _c.subscribeServiceStatus(Empty()).first.timeout(const Duration(seconds: 2));
    if (s.status == ServiceStatus_Type.STARTED) return null;
    if (s.status == ServiceStatus_Type.FATAL) return s.errorMessage.isEmpty ? 'sing-box failed to start' : s.errorMessage;
    throw StateError('sing-box is ${s.status.name}');
  }

  /// What sing-box says will break in the config with a later release.
  Future<List<String>> deprecatedWarnings() async {
    final w = await _c.getDeprecatedWarnings(Empty()).timeout(const Duration(seconds: 2));
    return [for (final x in w.warnings) [x.message, if (x.migrationLink.isNotEmpty) x.migrationLink].join(' — ')];
  }

  // ── the streams, opened by watch() ─────────────────────────────────────────

  static const interval = Duration(seconds: 1);
  static final _intervalNs = Int64(interval.inMicroseconds * 1000);

  final _conns = <String, LiveConnection>{};
  final _closedCtl = StreamController<ClosedConnection>.broadcast();
  final _groupsCtl = StreamController<void>.broadcast();
  Map<String, BoxGroup> _groups = {};
  Status? status;

  /// Opens the streams (again after an error, while not closed).
  void watch() {
    _keep(() => _c.subscribeConnections(SubscribeConnectionsRequest(interval: _intervalNs)), _onConnections);
    _keep(() => _c.subscribeGroups(Empty()), (Groups g) {
      _groups = {for (final x in g.group) x.tag: BoxGroup.of(x)};
      _groupsCtl.add(null);
    });
    _keep(() => _c.subscribeStatus(SubscribeStatusRequest(interval: _intervalNs)), (Status s) => status = s);
  }

  void _keep<T>(Stream<T> Function() open, void Function(T) on) {
    void go() {
      if (_closed) return;
      late StreamSubscription<T> sub;
      sub = open().listen(on, onError: (Object _) {}, onDone: () {
        _subs.remove(sub);
        Timer(const Duration(seconds: 1), go);
      }, cancelOnError: true);
      _subs.add(sub);
    }

    go();
  }

  void _onConnections(ConnectionEvents b) {
    if (b.reset) _conns.clear();
    final per = interval.inMilliseconds / 1000;
    for (final e in b.events) {
      switch (e.type) {
        case ConnectionEventType.CONNECTION_EVENT_NEW when e.hasConnection():
          _conns[e.id.isEmpty ? e.connection.id : e.id] = LiveConnection(e.connection);
        case ConnectionEventType.CONNECTION_EVENT_UPDATE:
          final c = _conns[e.id];
          if (c == null) break;
          c.up += e.uplinkDelta.toInt();
          c.down += e.downlinkDelta.toInt();
          c.upRate = (e.uplinkDelta.toInt() / per).round();
          c.downRate = (e.downlinkDelta.toInt() / per).round();
        case ConnectionEventType.CONNECTION_EVENT_CLOSED:
          final c = _conns.remove(e.id.isEmpty ? e.connection.id : e.id);
          // the history sent first (reset) is not news
          if (b.reset) break;
          if (e.hasConnection()) {
            _closedCtl.add(ClosedConnection.of(e.connection));
          } else if (c != null) {
            _closedCtl.add(ClosedConnection(outbound: c.outbound, chain: c.chain, destination: _dest(c.c), up: c.up, down: c.down, rule: c.rule, process: c.process));
          }
        default:
      }
    }
  }

  /// Every connection that closes from now on (watch() must be running).
  Stream<ClosedConnection> closedConnections() => _closedCtl.stream;

  @override
  Iterable<LiveConnection> get connections => _conns.values;

  Map<String, BoxGroup> get groups => _groups;

  @override
  Map<String, String> get selected => {for (final g in _groups.values) g.tag: g.selected};

  @override
  Stream<void> get groupsChanged => _groupsCtl.stream;

  // ── commands ─────────────────────────────────────────────────────────────────

  Future<bool> _ok(Future<Object?> f) async {
    try {
      await f.timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> select(String group, String outbound) async {
    final ok = await _ok(_c.selectOutbound(SelectOutboundRequest(groupTag: group, outboundTag: outbound)));
    // sing-box pushes groups on urltest results only: keep [selected] true at once
    final g = _groups[group];
    if (ok && g != null) {
      _groups = {..._groups, group: BoxGroup(g.tag, outbound, g.members, g.results)};
    }
    return ok;
  }

  @override
  Future<Map<String, int>?> testGroup(String group, {String? leaving, required Duration timeout}) async {
    final from = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final members = _groups[group]?.members;
    if (!await _ok(_c.uRLTest(URLTestRequest(outboundTag: group)))) return null;
    Map<String, int> fresh() => {
          for (final e in (_groups[group]?.results ?? const <String, ({int ms, int at})>{}).entries)
            if (e.value.at >= from) e.key: e.value.ms,
        };
    bool done() {
      final g = _groups[group];
      if (g == null) return false;
      if (leaving != null && g.selected != leaving) return true;
      return members != null && members.isNotEmpty && members.every(fresh().containsKey);
    }

    if (!done()) {
      await groupsChanged.firstWhere((_) => done()).timeout(timeout, onTimeout: () {});
    }
    return fresh();
  }

  @override
  Future<bool> closeConnection(String id) => _ok(_c.closeConnection(CloseConnectionRequest(id: id)));

  Future<bool> closeAllConnections() => _ok(_c.closeAllConnections(Empty()));

  /// Switches sing-box's clash mode (the DNS rules with `clash_mode` follow it, see
  /// routing.dart); false when sing-box refused or is gone.
  Future<bool> setClashMode(String mode) => _ok(_c.setClashMode(ClashMode(mode: mode)));

  /// The clash mode in use and the ones the config knows; null when sing-box refused.
  Future<({String current, List<String> modes})?> clashMode() async {
    try {
      final s = await _c.getClashModeStatus(Empty()).timeout(const Duration(seconds: 3));
      return (current: s.currentMode, modes: List.of(s.modeList));
    } catch (_) {
      return null;
    }
  }

  /// Speed Test through [outbound]: progress as it goes, the last one `isFinal` (with
  /// `error` when it failed). [configUrl] empty = sing-box's default (Apple's servers).
  Stream<NetworkQualityTestProgress> speedTest(String outbound, {String configUrl = '', int maxSeconds = 0}) =>
      _c.startNetworkQualityTest(NetworkQualityTestRequest(outboundTag: outbound, configURL: configUrl, maxRuntimeSeconds: maxSeconds));

  Future<void> close() async {
    _closed = true;
    for (final s in [..._subs]) {
      unawaited(s.cancel());
    }
    _subs.clear();
    await _closedCtl.close();
    await _groupsCtl.close();
    await _ch.shutdown();
  }
}
