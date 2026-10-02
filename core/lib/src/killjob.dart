import 'dart:io';

// The win32 code lives in killjob_win.dart and runs only behind Platform.isWindows below.
import 'killjob_win.dart';

/// Kills sing-box processes left over from older runs: the executable is exactly
/// [binary] (any other sing-box, the user's Karing, is never touched) and the parent
/// process is gone. Returns the pids it killed; failures give an empty list. Windows only.
Future<List<int>> killOrphans(String binary) async {
  if (!Platform.isWindows) return const [];
  try {
    final file = File(binary);
    if (!file.existsSync()) return const []; // from PATH: which one is ours is unknown
    const script = r'''
$bin = [IO.Path]::GetFullPath($env:JORM_SB)
$alive = @{}
Get-Process | ForEach-Object { $alive[$_.Id] = 1 }
Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" | Where-Object {
  $_.ExecutablePath -and [string]::Equals([IO.Path]::GetFullPath($_.ExecutablePath), $bin, 'OrdinalIgnoreCase') -and -not $alive.ContainsKey([int]$_.ParentProcessId)
} | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  $_.ProcessId
}
''';
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      environment: {'JORM_SB': file.absolute.path},
    ).timeout(const Duration(seconds: 20));
    return [
      for (final l in '${r.stdout}'.split(RegExp(r'\s+')))
        if (int.tryParse(l) != null) int.parse(l),
    ];
  } catch (_) {
    return const [];
  }
}

/// Ties the child process [pid] (sing-box) to ours: it dies whenever we die, however we
/// die (taskkill /F, a crash, a killed test runner), not only on a graceful stop. A Windows
/// Job Object with kill-on-close, created once; only the child goes into it, never our own
/// process, so whatever we launch for the user (a browser) outlives us.
///
/// No-op off Windows. Never throws: returns null when bound, else the reason it was not
/// (the child keeps running, just not tied to us).
String? bindToUs(int pid) {
  if (!Platform.isWindows) return null;
  try {
    return bindToUsWindows(pid);
  } catch (e) {
    return 'job object: $e';
  }
}
