/// The win32 half of killjob.dart. Reached only behind `Platform.isWindows` (killjob.dart), so on
/// Android / Linux / macOS nothing here runs. win32 6.x binds every function lazily — a
/// top-level `final _X = _kernel32.lookupFunction(...)` is initialised on first use, and
/// `_kernel32` (`DynamicLibrary.open('kernel32.dll')`) too — so merely linking this file
/// opens no library and looks up no symbol.
library;

import 'dart:ffi';

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

/// See `bindToUs` in killjob.dart. Windows only.
String? bindToUsWindows(int pid) {
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
}
