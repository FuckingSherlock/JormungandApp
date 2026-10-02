/// TUN needs administrator rights (Windows: a wintun adapter and routes; elsewhere root).
/// The core only checks and says so clearly; relaunching elevated is the app's job.
library;

import 'dart:io';

// The win32 code lives in elevation_win.dart and runs only behind Platform.isWindows below.
import 'elevation_win.dart';

/// TUN cannot start: the process is not elevated (checked before sing-box starts), or sing-box
/// itself failed on a permission ([detail] = its words). The daemon turns it into the journal
/// event `core/tunNeedsAdmin` and a failed connect with a message the user can act on.
class TunNeedsAdmin implements Exception {
  TunNeedsAdmin([this.detail]);

  /// What sing-box said, when it was the one that refused.
  final String? detail;

  static const message = 'TUN needs administrator rights: run the app as administrator, or switch to Proxy mode';

  @override
  String toString() => message;
}

/// Whether this process runs elevated: Windows, the token's `TokenIsElevated`; elsewhere
/// root (`id -u` = 0). A check that cannot be made says "not elevated": better a clear error
/// than a TUN that half starts.
bool processIsElevated() {
  try {
    if (Platform.isWindows) return windowsElevated();
    return '${Process.runSync('id', ['-u']).stdout}'.trim() == '0';
  } catch (_) {
    return false;
  }
}

/// Whether sing-box's start error of a TUN config is a missing permission (wintun adapter,
/// routes, the firewall rules of strict_route) — the same advice as not being elevated.
bool tunAccessDenied(String error) => RegExp(
        r'access is denied|access denied|permission denied|operation not permitted|privilege|administrator|elevat|not permitted',
        caseSensitive: false)
    .hasMatch(error);
