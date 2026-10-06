import 'dart:async';
import 'dart:ui' show VoidCallback;

import '../platform/tile_channel.dart';
import 'core_host.dart';

/// What the Quick Settings tile shows as the connection's name: a chain by its name, anything
/// else by the server traffic leaves through (`flag name`), falling back to the entry's name;
/// empty when the dock has no entry.
String tileName(DockSummary s) {
  if (!s.hasEntry) return '';
  if (s.isChain) return s.name;
  final n = s.node;
  return n == null ? s.name : '${n.flag} ${n.name}'.trim();
}

/// Android Quick Settings tile <-> the core (docs/platforms.md, "Плитка быстрых настроек").
///
/// Pushes the phase and the name to the native side on every change of the host, and does what a
/// tap asks: the same `connect` / `disconnect` as the dock's power button. A connect the tile
/// started the app for (`launch`) sends the app behind again once it is through.
class TileSync {
  TileSync(this.host, this.port, {this.onHome});

  final CoreHost host;
  final TilePort port;

  /// Long-press on the tile (action `home`): the app shows Home with no sheet open.
  final VoidCallback? onHome;

  StreamSubscription<TileAction>? _sub;
  TileState? _last;
  bool _disposed = false;

  void start() {
    host.addListener(_sync);
    // listen first: that is the "Dart is alive" mark of the native side
    _sub = port.actions.listen(_onAction, onError: (Object _) {});
    unawaited(_boot());
  }

  void dispose() {
    _disposed = true;
    host.removeListener(_sync);
    _sub?.cancel();
  }

  Future<void> _boot() async {
    await host.init();
    if (_disposed) return;
    _sync();
    final launched = await port.takeLaunchAction();
    if (launched != null) await _run(TileAction(launched, launch: true));
  }

  static String _phase(ConnectionPhase p) => switch (p) {
    ConnectionPhase.disconnected => 'off',
    ConnectionPhase.connecting => 'connecting',
    ConnectionPhase.disconnecting => 'disconnecting',
    ConnectionPhase.connected || ConnectionPhase.down => 'on',
  };

  void _sync() {
    if (_disposed || !host.ready) return;
    final dock = host.dock;
    final s = TileState(_phase(host.phase), tileName(dock), dock.hasEntry);
    if (s == _last) return;
    _last = s;
    unawaited(port.push(s).catchError((Object _) {}));
  }

  Future<void> _onAction(TileAction a) async {
    if (a.action == 'home') return _run(a); // no core needed
    await host.init();
    if (_disposed) return;
    await _run(a);
  }

  Future<void> _run(TileAction a) async {
    switch (a.action) {
      case 'home':
        onHome?.call();
      case 'connect':
        // a tap is "turn on", never "reconnect": an app that is on or busy leaves it be
        if (host.isOn || host.busy) return;
        final r = await host.connect();
        if (a.launch && r.started && !_disposed) await port.moveToBack();
      case 'disconnect':
        if (host.phase == ConnectionPhase.disconnected) return;
        await host.disconnect();
    }
  }
}
