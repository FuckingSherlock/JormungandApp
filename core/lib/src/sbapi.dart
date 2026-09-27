/// sing-box's API service (1.14+): a gRPC server in the config (`services: [{type: api}]`)
/// with the interface the official clients use — streams of connections, groups, logs,
/// status, and commands (select, URL test, close connections, clash mode). The messages
/// are generated from sing-box's own `daemon/started_service.proto` (tool/gen_sbapi.sh,
/// pinned to the sing-box release in tool/bin). The core listens to its streams instead of
/// polling or reading log lines; the Clash API still does the rest (docs/core.md).
library;

import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import 'sbapi/started_service.pbgrpc.dart';

export 'sbapi/started_service.pb.dart' show Connection, ConnectionEvent, ConnectionEvents;
export 'sbapi/started_service.pbenum.dart' show ConnectionEventType;

/// A connection sing-box closed, as the core judges request failures by it.
class ClosedConnection {
  const ClosedConnection({required this.outbound, required this.chain, required this.destination, required this.up, required this.down});

  /// The server's outbound tag (the leaf, e.g. `route0/<key>`); [chain] = leaf … `proxy`.
  final String outbound;
  final List<String> chain;
  final String destination; // host:port (the domain when there is one)
  final int up, down; // bytes in total

  factory ClosedConnection.of(Connection c) => ClosedConnection(
        outbound: c.outbound,
        chain: List.of(c.chainList),
        destination: c.domain.isNotEmpty && !c.destination.startsWith(c.domain) ? '${c.domain}:${c.destination.split(':').last}' : c.destination,
        up: c.uplinkTotal.toInt(),
        down: c.downlinkTotal.toInt(),
      );
}

class SingBoxApi {
  SingBoxApi(int port, String secret)
      : _ch = ClientChannel('127.0.0.1', port: port, options: const ChannelOptions(credentials: ChannelCredentials.insecure())),
        _opts = CallOptions(metadata: {'authorization': 'Bearer $secret'}) {
    _c = StartedServiceClient(_ch, options: _opts);
  }

  final ClientChannel _ch;
  final CallOptions _opts;
  late final StartedServiceClient _c;

  /// Every connection that closes from now on (the history sent first is skipped). The
  /// stream ends when sing-box stops or [close] is called; errors end it too.
  Stream<ClosedConnection> closedConnections() {
    // traffic updates are not needed here: a long interval keeps them rare
    final req = SubscribeConnectionsRequest(interval: Int64(const Duration(minutes: 10).inMicroseconds * 1000));
    return _c
        .subscribeConnections(req)
        .where((b) => !b.reset)
        .expand((b) => b.events)
        .where((e) => e.type == ConnectionEventType.CONNECTION_EVENT_CLOSED && e.hasConnection())
        .map((e) => ClosedConnection.of(e.connection));
  }

  Future<void> close() => _ch.shutdown();
}
