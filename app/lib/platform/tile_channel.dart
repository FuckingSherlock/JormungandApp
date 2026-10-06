import 'package:flutter/services.dart';

/// What the Quick Settings tile asks the app to do: `connect` | `disconnect`. [launch] = the tile
/// started the app for it (the app goes behind again once a connect is through).
class TileAction {
  const TileAction(this.action, {this.launch = false});

  final String action;
  final bool launch;
}

/// What the tile shows, pushed to the native side on every change (it keeps the last one for when
/// the app is not running). [phase]: `off` | `on` | `connecting` | `disconnecting`; [name] the
/// current connection's name, empty = none; [canConnect] false = nothing to connect through (the
/// tile opens the app instead).
class TileState {
  const TileState(this.phase, this.name, this.canConnect);

  final String phase;
  final String name;
  final bool canConnect;

  @override
  bool operator ==(Object other) =>
      other is TileState &&
      other.phase == phase &&
      other.name == name &&
      other.canConnect == canConnect;

  @override
  int get hashCode => Object.hash(phase, name, canConnect);

  @override
  String toString() => 'TileState($phase, "$name", $canConnect)';
}

/// The seam of `TileSync` to the platform; tests give a fake.
abstract interface class TilePort {
  /// Taps on the tile. Listening is also what tells the native side that a Dart core is alive.
  Stream<TileAction> get actions;

  Future<void> push(TileState state);

  /// What the app was started for by the tile (`connect`), once; null = nothing.
  Future<String?> takeLaunchAction();

  /// The app goes behind (a connect the tile asked for is done).
  Future<void> moveToBack();
}

/// Android: MethodChannel `jormungand/tile` + EventChannel `jormungand/tile_events`
/// (Kotlin: android_overlay/kotlin/JormungandTileService.kt.tmpl, class `TileChannel`).
class TileChannel implements TilePort {
  const TileChannel();

  static const MethodChannel _channel = MethodChannel('jormungand/tile');
  static const EventChannel _events = EventChannel('jormungand/tile_events');

  @override
  Stream<TileAction> get actions => _events
      .receiveBroadcastStream()
      .where((e) => e is Map && e['type'] == 'tile' && e['action'] is String)
      .map((e) => TileAction('${(e as Map)['action']}', launch: e['launch'] == true));

  @override
  Future<void> push(TileState state) async {
    try {
      await _channel.invokeMethod<void>('state', <String, Object?>{
        'phase': state.phase,
        'name': state.name,
        'canConnect': state.canConnect,
      });
    } on MissingPluginException {
      // not Android
    }
  }

  @override
  Future<String?> takeLaunchAction() async {
    try {
      return await _channel.invokeMethod<String>('launchAction');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> moveToBack() async {
    try {
      await _channel.invokeMethod<void>('moveToBack');
    } on MissingPluginException {
      // not Android
    }
  }
}
