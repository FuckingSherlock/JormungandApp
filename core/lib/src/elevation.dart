/// TUN needs administrator rights (Windows: a wintun adapter and routes; elsewhere root).
/// The core only checks and says so clearly; relaunching elevated is the app's job.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

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
    if (Platform.isWindows) return _windowsElevated();
    return '${Process.runSync('id', ['-u']).stdout}'.trim() == '0';
  } catch (_) {
    return false;
  }
}

bool _windowsElevated() {
  final token = calloc<Pointer>();
  final info = calloc<Uint32>();
  final size = calloc<Uint32>();
  try {
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, token).value) return false;
    final h = HANDLE(token.value);
    try {
      final r = GetTokenInformation(h, TokenElevation, info, sizeOf<Uint32>(), size);
      return r.value && info.value != 0;
    } finally {
      CloseHandle(h);
    }
  } finally {
    calloc.free(token);
    calloc.free(info);
    calloc.free(size);
  }
}

/// Whether sing-box's start error of a TUN config is a missing permission (wintun adapter,
/// routes, the firewall rules of strict_route) — the same advice as not being elevated.
bool tunAccessDenied(String error) => RegExp(
        r'access is denied|access denied|permission denied|operation not permitted|privilege|administrator|elevat|not permitted',
        caseSensitive: false)
    .hasMatch(error);
