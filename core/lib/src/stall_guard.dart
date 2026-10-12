/// "No bytes for this long = the way is dead": the one stall rule of the core's own transfers
/// (the report upload, report_upload.dart; the service fetch, svc_fetch.dart). A connection that a DPI
/// cuts after the first kilobytes does not close, it just goes quiet — waiting for an overall cap
/// costs minutes, a stall limit decides in seconds.
library;

import 'dart:async';

/// A span for a message: whole seconds as «3 s», else milliseconds.
String spanText(Duration d) => d.inMilliseconds % 1000 == 0 ? '${d.inSeconds} s' : '${d.inMilliseconds} ms';

/// [step] (one flush of an upload, one read of a download) must end within [stall]; else a
/// [TimeoutException] with [message].
Future<T> stallWatch<T>(Future<T> step, Duration stall, String message) =>
    step.timeout(stall, onTimeout: () => throw TimeoutException(message));

/// [source] with the same limit between events: no event for [stall] → a [TimeoutException] with
/// [message] is the stream's error and the source is cancelled.
Stream<List<int>> stallGuard(Stream<List<int>> source, Duration stall, String message) =>
    source.timeout(stall, onTimeout: (sink) {
      sink.addError(TimeoutException(message));
      sink.close();
    });
