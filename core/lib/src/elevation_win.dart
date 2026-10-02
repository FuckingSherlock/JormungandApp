/// The win32 half of elevation.dart: reached only behind `Platform.isWindows`, so on Android and
/// the rest nothing here runs (win32 binds its functions lazily, see killjob_win.dart).
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Whether the process token has `TokenIsElevated`.
bool windowsElevated() {
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
