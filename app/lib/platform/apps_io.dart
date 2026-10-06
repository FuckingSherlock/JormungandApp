import 'package:flutter/services.dart';

/// One installed app as the platform lists it.
typedef AppEntry = ({String pkg, String name, bool system});

/// The apps installed on the device (Rules -> Per-app routing): the list and the icons. Android
/// answers through the `jormungand/apps` channel (Kotlin: android_overlay/kotlin/AppsChannel.kt.tmpl);
/// anywhere else the list is empty. Tests put a fake into [current].
abstract class AppsIo {
  static AppsIo current = const ChannelAppsIo();

  /// Every installed app (without this one): package, label, system or not. Empty off Android.
  Future<List<AppEntry>> list();

  /// An app's icon as PNG bytes; null when it has none (or off Android).
  Future<Uint8List?> icon(String pkg);
}

class ChannelAppsIo implements AppsIo {
  const ChannelAppsIo();

  static const MethodChannel _channel = MethodChannel('jormungand/apps');

  @override
  Future<List<AppEntry>> list() async {
    try {
      final l = await _channel.invokeListMethod<Map<Object?, Object?>>('list');
      return [
        for (final m in l ?? const <Map<Object?, Object?>>[])
          if (m['pkg'] is String)
            (
              pkg: m['pkg'] as String,
              name: '${m['name'] ?? m['pkg']}',
              system: m['system'] == true,
            ),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<Uint8List?> icon(String pkg) async {
    try {
      return await _channel.invokeMethod<Uint8List>('icon', <String, Object?>{
        'pkg': pkg,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
