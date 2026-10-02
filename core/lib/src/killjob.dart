import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: the system kills every process of the job when its
/// last handle closes, and a dying process closes all its handles.
const _killOnJobClose = 0x2000;

/// sizeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) on x64 (win32 has no struct for it):
/// JOBOBJECT_BASIC_LIMIT_INFORMATION 64 + IO_COUNTERS 48 + four SIZE_T 32. LimitFlags
/// sits at offset 16.
const _extLimitSize = 144;
const _limitFlagsOffset = 16;

HANDLE? _job; // held for the whole life of the process, never closed on purpose
String? _jobError;

HANDLE? _makeJob() {
  final job = CreateJobObject(null, null).value;
  if (job.isNull) {
    _jobError = 'CreateJobObject failed';
    return null;
  }
  final info = calloc<Uint8>(_extLimitSize);
  try {
    (info + _limitFlagsOffset).cast<Uint32>().value = _killOnJobClose;
    final r = SetInformationJobObject(job, JobObjectExtendedLimitInformation, info, _extLimitSize);
    if (!r.value) {
      _jobError = 'SetInformationJobObject failed (error ${r.error})';
      CloseHandle(job);
      return null;
    }
  } finally {
    calloc.free(info);
  }
  return job;
}

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
    final job = _job ??= _makeJob();
    if (job == null) return _jobError;
    final proc = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid).value;
    if (proc.isNull) return 'OpenProcess($pid) failed';
    try {
      final r = AssignProcessToJobObject(job, proc);
      return r.value ? null : 'AssignProcessToJobObject failed (error ${r.error})';
    } finally {
      CloseHandle(proc);
    }
  } catch (e) {
    return 'job object: $e';
  }
}
