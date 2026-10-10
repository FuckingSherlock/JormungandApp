import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:jormungand_core/jormungand_core.dart' show Catalog, CatalogPlan;

import 'core_host.dart';
import 'settings_model.dart';

/// The `appInfo` of the support report (docs/logs.md → Отчёт): what only the app and the phone
/// know and the core never guesses. [build] gathers it from the host (version, commit, the catalog's
/// names, the app's own settings) and from the platform through the closures below; every platform
/// answer is optional and bounded by [timeout], so a stuck channel costs a field, not the report.
///
/// Reserved keys the report puts in their own places (docs/logs.md): `libbox`, `planSig`, `names`,
/// `network`, `settings`. Everything else lands in the report's `app`.
///
/// Nothing secret goes in: settings are the toggles of Settings (no logins, no subscription URLs),
/// `names` are display names of the plan's routes and servers.
class ReportInfo {
  const ReportInfo({
    this.device,
    this.abis,
    this.libbox,
    this.vpnUp,
    this.networkType,
    this.metered,
    this.now,
    this.systemLocale,
    this.timeout = const Duration(seconds: 2),
  });

  /// `VpnChannel.deviceInfo`: `{model, manufacturer, brand, androidApi, androidRelease}`.
  final Future<Map<String, dynamic>> Function()? device;

  /// The ABIs of the device, best first.
  final Future<List<String>> Function()? abis;

  /// The sing-box version inside libbox.
  final Future<String?> Function()? libbox;

  /// Whether the VPN service is up (the platform's answer, not the core's).
  final Future<bool> Function()? vpnUp;

  /// `wifi` | `ethernet` | `mobile` | `other` | `none` | `unknown`.
  final Future<String> Function()? networkType;

  /// Whether the network the phone really uses is metered.
  final Future<bool> Function()? metered;

  /// The clock (tests).
  final DateTime Function()? now;

  /// The phone's language tag (`ru-RU`); default the platform dispatcher's.
  final String Function()? systemLocale;

  final Duration timeout;

  Future<T?> _ask<T>(Future<T> Function()? f) async {
    if (f == null) return null;
    try {
      return await f().timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// The map the core's `report` / `sendReport` take as `appInfo`. [planSig]: the signature of the plan
  /// the core runs (the host's), else the one the catalog would build now.
  Future<Map<String, dynamic>> build(CoreHost host, {String? planSig}) async {
    final results = await Future.wait<Object?>([
      _ask<Map<String, dynamic>>(device),
      _ask<List<String>>(abis),
      _ask<String?>(libbox),
      _ask<bool>(vpnUp),
      _ask<String>(networkType),
      _ask<bool>(metered),
    ]);
    final dev = (results[0] as Map<String, dynamic>?) ?? const {};
    final abiList = results[1] as List<String>?;
    final libboxVersion = results[2] as String?;
    final vpn = results[3] as bool?;
    final netType = results[4] as String?;
    final isMetered = results[5] as bool?;

    final at = (now ?? DateTime.now)();
    final off = at.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final abs = off.abs();
    String two(int n) => n.toString().padLeft(2, '0');

    final model = '${dev['model'] ?? ''}'.trim();
    final maker = '${dev['manufacturer'] ?? ''}'.trim();
    final sig = planSig ?? _safe(() => host.catalog.planSig());

    return {
      'version': host.appVersion,
      'versionCode': host.appBuild,
      if (host.appCommit.isNotEmpty) 'commit': host.appCommit,
      'platform': host.isAndroid ? 'android' : Platform.operatingSystem,
      if (dev['androidApi'] != null) 'androidApi': dev['androidApi'],
      if (dev['androidRelease'] != null) 'androidRelease': dev['androidRelease'],
      if (model.isNotEmpty || maker.isNotEmpty)
        'device': {
          if (model.isNotEmpty) 'model': model,
          if (maker.isNotEmpty) 'manufacturer': maker,
          if ('${dev['brand'] ?? ''}'.isNotEmpty) 'brand': dev['brand'],
        },
      if (abiList != null && abiList.isNotEmpty) 'abis': abiList,
      'locale': (systemLocale ?? () => PlatformDispatcher.instance.locale.toLanguageTag())(),
      'timezone': at.timeZoneName,
      'utcOffset': '$sign${two(abs.inHours)}:${two(abs.inMinutes.remainder(60))}',
      if (libboxVersion != null && libboxVersion.isNotEmpty) 'libbox': libboxVersion,
      if (sig != null && sig.isNotEmpty) 'planSig': sig,
      'names': _names(host.catalog),
      'network': {
        'type': ?netType,
        'vpnService': ?vpn,
        'metered': ?isMetered,
      },
      'settings': appSettings(host),
    };
  }

  static T? _safe<T>(T? Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }
}

/// The app's own settings as the report carries them (`settings.app`): the look, the language, the
/// startup and update options, the notification toggles. Read without creating the slots in the
/// catalog. Never anything that holds a credential.
Map<String, dynamic> appSettings(CoreHost host) {
  Map<String, dynamic> slot(String key) {
    final v = host.catalog.unknown[key];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  final gen = GenCfg(slot('genCfg'));
  final notif = NotifCfg(slot('notifCfg'));
  return {
    'language': gen.lang ?? 'system',
    'theme': gen.theme ?? 'default',
    'textScale': gen.uiScale ?? 1.0,
    'connectOnLaunch': gen.connectOnLaunch,
    'pingOnLaunch': gen.pingOnLaunch,
    'clipboard': gen.clipboard,
    if (!host.isAndroid) 'launchAtStartup': gen.launchAtStartup,
    if (!host.isAndroid) 'startMinimized': gen.startMinimized,
    'updates': gen.updates,
    'updChannel': gen.updChannel,
    'updAutoDownload': gen.updAutoDownload,
    'notifications': {
      'enabled': notif.enabled,
      'bgErrors': notif.bgErrors,
      for (final k in NotifCfg.allKeys) k: notif.flag(k),
      if (!host.isAndroid) 'desktopStyle': notif.desktopStyle,
    },
  };
}

/// Route id → name of its Route entry (profile / chain / source) and server key (`sid::nid`) → the
/// server's name, for the routes and servers of the plan the catalog builds now (docs/logs.md,
/// reserved key `names`). Empty when there is no plan.
Map<String, String> _names(Catalog c) {
  final out = <String, String>{};
  try {
    final plan = c.livePlan(c.liveSigAnchor());
    String? serverName(String key) {
      final i = key.indexOf('::');
      if (i < 0) return null;
      final src = c.sourcesData[key.substring(0, i)];
      final nid = key.substring(i + 2);
      if (src == null) return null;
      for (final n in src.nodes) {
        if (n.id == nid) return n.name.trim().isEmpty ? null : n.name.trim();
      }
      return null;
    }

    for (final r in (plan['routes'] as List? ?? const [])) {
      if (r is! Map) continue;
      final id = '${r['id']}';
      final entry = c.connectEntry(id);
      if (entry != null && entry.name.isNotEmpty) out[id] = entry.name;
      for (final g in [r['main'], r['entry']]) {
        if (g is! Map) continue;
        for (final n in (g['nodes'] as List? ?? const [])) {
          if (n is! Map || n['key'] is! String) continue;
          final key = n['key'] as String;
          final name = serverName(key);
          if (name != null) out[key] = name;
        }
      }
    }
  } catch (_) {
    // no plan to build (nothing to connect): no names, the report says keys
  }
  return out;
}
