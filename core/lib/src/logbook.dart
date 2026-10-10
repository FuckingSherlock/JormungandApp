import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'durable.dart';
import 'ignored_sites.dart';

/// The core's own version (pubspec `version`), shown in Settings → Data → About.
const coreVersion = '0.1.0';

/// `sing-box version`'s first line without the name ("1.14.2"); null when it does not run.
Future<String?> singBoxVersion(String binary) async {
  try {
    final r = await Process.run(binary, ['version']).timeout(const Duration(seconds: 5));
    final m = RegExp(r'version\s+(\S+)').firstMatch('${r.stdout}');
    return m?[1];
  } catch (_) {
    return null;
  }
}

/// A sing-box line of a successful connection: `[id 5ms] inbound/mixed[mixed-in]: inbound connection to host:443`
/// (also `outbound connection`, `packet connection`). The one pattern for the [LogBook] and the Raw view.
final connLineRe = RegExp(r'(inbound|outbound)/[^:]*: (inbound|outbound) (packet )?connection\b');

/// The sing-box line that names the program behind a connection: `[id 5ms] router: found package name: org.x`
/// (Android), `… router: found process path: C:\…\chrome.exe` (desktop). One per connection, so as
/// loud as the connection lines.
final foundLineRe = RegExp(r'router: found (package name|process path): ');

/// A sing-box line of the flood a busy device writes: a successful connection ([connLineRe]) or the
/// program behind one ([foundLineRe]). Warnings and errors are never one (the caller checks the level).
/// The [LogBook] keeps them in the noise ring; the Raw view's «Connections» switch shows them.
bool isNoiseLine(String text) => connLineRe.hasMatch(text) || foundLineRe.hasMatch(text);

/// The log the Logs tab shows: sing-box's output and the core's own notes (connect,
/// disconnect, failed requests), in one numbered sequence, newest last. The UI polls
/// [since] with the `next` of its previous answer, so every line reaches it once; [clear]
/// empties the book, numbering goes on.
///
/// Two rings, so the flood of successful connections cannot push the rest out: those lines
/// ([isNoiseLine]: successful connections and `found package name` / `found process path`,
/// not warnings / errors) and the failed ones of [ignored] sites keep the last [noiseCap];
/// everything else keeps the last [cap]. [since] merges them by number (and with `conns: false`
/// leaves the flood out on the core's side, saying how much it left out).
///
/// With a [file] the warnings and errors are also kept on disk (JSON Lines, written behind
/// the memory: collected and appended in one write [flushEvery] after the first, and by [flush]
/// on shutdown; asynchronous, never per line). When the file passes [maxBytes] it is rewritten
/// from the newest problems, half of that size. [load] (once, at start) brings them back, so
/// the night's errors can be read after a restart or a crash; the loaded lines get new numbers
/// and keep their time. A line cut off by a crash is dropped. Disk trouble never reaches the caller.
class LogBook {
  LogBook({
    this.cap = 5000,
    this.noiseCap = 500,
    this.file,
    this.maxBytes = 1024 * 1024,
    this.flushEvery = const Duration(milliseconds: 1500),
  });

  final int cap, noiseCap;
  final File? file;
  final int maxBytes;
  final Duration flushEvery;
  final _lines = ListQueue<Map<String, Object>>();
  final _noise = ListQueue<Map<String, Object>>();

  /// The sites the user ignores: their failed-connection lines (warnings / errors that name the
  /// host or a subdomain) go to the noise ring, not the main one, so they cannot push the
  /// rest out and are not kept on disk. Applies to the lines written from now on.
  IgnoredSites ignored = IgnoredSites.empty;
  int _next = 0;
  bool _loaded = false;

  // Warnings / errors not in the file yet, the timer that writes them, the last write (the next
  // waits for it), the size of the file as far as we know, and a rewrite that is due.
  final _pending = <String>[];
  Timer? _timer;
  Future<void> _io = Future<void>.value();
  int _bytes = 0;
  bool _rewrite = false;

  /// Reads the kept warnings / errors of the file into the book. Once; call it at start.
  void load() {
    if (_loaded) return;
    _loaded = true;
    final f = file;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      if (!f.existsSync()) return;
      _bytes = f.lengthSync();
      for (final text in f.readAsLinesSync(encoding: const Utf8Codec(allowMalformed: true))) {
        try {
          final j = jsonDecode(text);
          if (j is! Map || j['t'] is! int || j['lvl'] is! String || j['msg'] is! String) continue;
          _lines.add({'n': _next++, 't': j['t'] as int, 'src': '${j['src'] ?? 'sing-box'}', 'lvl': j['lvl'] as String, 'msg': j['msg'] as String});
        } catch (_) {}
      }
      while (_lines.length > cap) {
        _lines.removeFirst();
      }
    } on FileSystemException {
      return;
    }
  }

  // sing-box with `timestamp: true`: "+0300 2026-09-26 14:02:11 INFO [2831706842 0ms] router: …";
  // fatal start errors on stderr: "FATAL[0000] start service: …".
  static final _stamped = RegExp(r'^[+-]\d{4} \d{4}-\d\d-\d\d \d\d:\d\d:\d\d (TRACE|DEBUG|INFO|WARN|ERROR|FATAL|PANIC) (.*)$');
  static final _bare = RegExp(r'^(TRACE|DEBUG|INFO|WARN|ERROR|FATAL|PANIC)\[\d+\] ?(.*)$');

  // libbox hands its lines over coloured ("\x1b[33mWARN\x1b[0m[0003] …"): the colours go, the level stays
  static final _ansi = RegExp(r'\x1B\[[0-9;]*m');

  /// A line sing-box wrote; the runtime's own lines ("[jormd] …") count as the core's.
  /// [tag]: whose sing-box it is when it is not the main one ("ping", "speed"): shown before the text.
  void singBox(String raw, {String? tag}) {
    if (raw.contains('\x1B')) raw = raw.replaceAll(_ansi, '');
    if (raw.startsWith('[jormd] ')) return note('warn', raw.substring(8));
    // the stamped form starts with a zone sign: a line of any other form skips that regex
    final c = raw.isEmpty ? 0 : raw.codeUnitAt(0);
    final m = (c == 0x2B || c == 0x2D ? _stamped.firstMatch(raw) : null) ?? _bare.firstMatch(raw);
    final text = m == null ? raw : m[2]!;
    _add('sing-box', m == null ? 'info' : _level(m[1]!), tag == null ? text : '[$tag] $text');
  }

  /// A line of the core's own: [level] is debug, info, warn or error.
  void note(String level, String text) => _add('core', level, text);

  void _add(String src, String level, String text) {
    load();
    final line = <String, Object>{'n': _next++, 't': DateTime.now().millisecondsSinceEpoch, 'src': src, 'lvl': level, 'msg': text};
    final problem = level == 'warn' || level == 'error';
    // a failed request to an ignored site is noise too: its own ring, nothing for the disk
    final quiet = problem && !ignored.isEmpty && ignored.matchesText(text);
    if (quiet || (!problem && src == 'sing-box' && isNoiseLine(text))) {
      _noise.add(line);
      while (_noise.length > noiseCap) {
        _noise.removeFirst();
      }
    } else {
      _lines.add(line);
      while (_lines.length > cap) {
        _lines.removeFirst();
      }
      if (problem && file != null) {
        final s = '${jsonEncode({'t': line['t'], 'src': src, 'lvl': level, 'msg': text})}\n';
        _pending.add(s);
        _bytes += utf8.encode(s).length;
        _timer ??= Timer(flushEvery, () {
          _timer = null;
          unawaited(flush());
        });
      }
    }
    if (!_added.isClosed) _added.add(line);
  }

  /// Puts the warnings / errors that wait in memory into the file now (an append, or the rewrite
  /// when the file grew past [maxBytes]). Completes when written. The owner calls it on shutdown.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final f = file;
    if (f == null) return _io;
    final whole = _rewrite || _bytes > maxBytes;
    if (_pending.isEmpty && !whole) return _io;
    final String text;
    if (whole) {
      // the newest problems that fit in half of the limit
      final keep = <String>[];
      var size = 0;
      for (var i = _lines.length - 1; i >= 0; i--) {
        final l = _lines.elementAt(i);
        if (l['lvl'] != 'warn' && l['lvl'] != 'error') continue;
        final s = '${jsonEncode({'t': l['t'], 'src': l['src'], 'lvl': l['lvl'], 'msg': l['msg']})}\n';
        size += utf8.encode(s).length;
        if (size > maxBytes ~/ 2) break;
        keep.add(s);
      }
      text = keep.reversed.join();
      _bytes = utf8.encode(text).length;
      _rewrite = false;
    } else {
      text = _pending.join();
    }
    _pending.clear();
    return _io = _io.then((_) async {
      try {
        if (whole) {
          await writeFileDurable(f, text);
        } else {
          await f.writeAsString(text, mode: FileMode.append, flush: true);
        }
      } catch (_) {
        _rewrite = true; // memory keeps it; the next write puts the kept problems back
      }
    });
  }

  final _added = StreamController<Map<String, Object>>.broadcast();

  /// Every line as it is written (the app's live Logs view, instead of polling [since]).
  Stream<Map<String, Object>> get stream => _added.stream;

  /// Ends [stream]; lines written later are still kept.
  void close() {
    if (!_added.isClosed) unawaited(_added.close());
  }

  static String _level(String l) => switch (l) {
        'TRACE' || 'DEBUG' => 'debug',
        'WARN' => 'warn',
        'ERROR' || 'FATAL' || 'PANIC' => 'error',
        _ => 'info',
      };

  /// Lines numbered [from] and later (all kept ones without it), and the number the next
  /// line will get. The numbers only grow along the queue, so the start is found by a binary
  /// search: the cost is the size of the answer, not of the book (the app asks after every burst).
  ///
  /// With [conns] off the flood ([isNoiseLine]: successful connections, `found package name`) is
  /// left out here, at the source, and the answer says how much it left out: `hidden` = the number
  /// of such lines among the numbers it covers (only present with [conns] off). The failed
  /// connection lines of ignored sites also live in the noise ring, but they are warnings /
  /// errors and still come (the UI's «Ignored sites» switch sorts those). [next] and the numbers
  /// are the same either way, so a later request with [conns] on and the same [from] brings
  /// the left-out lines. [stream] is not filtered.
  Map<String, Object> since(int? from, {bool conns = true}) {
    load();
    // index of the first line numbered [from] or later in [q]
    int start(ListQueue<Map<String, Object>> q) {
      var i = 0;
      if (from == null) return 0;
      var hi = q.length;
      if (from >= _next) return hi; // nothing new: the usual answer of a poll
      while (i < hi) {
        final mid = (i + hi) >> 1;
        if ((q.elementAt(mid)['n'] as int) < from) {
          i = mid + 1;
        } else {
          hi = mid;
        }
      }
      return i;
    }

    var a = start(_lines), b = start(_noise);
    final out = <Map<String, Object>>[];
    var hidden = 0;
    while (a < _lines.length || b < _noise.length) {
      if (b >= _noise.length || (a < _lines.length && (_lines.elementAt(a)['n'] as int) < (_noise.elementAt(b)['n'] as int))) {
        out.add(_lines.elementAt(a++));
      } else {
        final l = _noise.elementAt(b++);
        if (!conns && l['lvl'] != 'warn' && l['lvl'] != 'error') {
          hidden++;
        } else {
          out.add(l);
        }
      }
    }
    return {'lines': out, 'next': _next, if (!conns) 'hidden': hidden};
  }

  /// Empties the book and the file; numbering goes on.
  void clear() {
    _lines.clear();
    _noise.clear();
    _pending.clear();
    if (file != null) {
      _rewrite = true;
      unawaited(flush());
    }
  }

  /// The number of the line written last (null before any): what an event links to.
  int? get last => _next == 0 ? null : _next - 1;
}
