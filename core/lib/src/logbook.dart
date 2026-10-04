import 'dart:async';
import 'dart:collection';
import 'dart:io';

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

/// The log the Logs tab shows: sing-box's output and the core's own notes (connect,
/// disconnect, failed requests), in one numbered sequence, newest last. Keeps the last
/// [cap] lines. The UI polls [since] with the `next` of its previous answer, so every
/// line reaches it once; [clear] empties the book, numbering goes on.
class LogBook {
  LogBook({this.cap = 2000});

  final int cap;
  final _lines = ListQueue<Map<String, Object>>();
  int _next = 0;

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
    final m = _stamped.firstMatch(raw) ?? _bare.firstMatch(raw);
    final text = m == null ? raw : m[2]!;
    _add('sing-box', m == null ? 'info' : _level(m[1]!), tag == null ? text : '[$tag] $text');
  }

  /// A line of the core's own: [level] is debug, info, warn or error.
  void note(String level, String text) => _add('core', level, text);

  void _add(String src, String level, String text) {
    final line = <String, Object>{'n': _next++, 't': DateTime.now().millisecondsSinceEpoch, 'src': src, 'lvl': level, 'msg': text};
    _lines.add(line);
    while (_lines.length > cap) {
      _lines.removeFirst();
    }
    if (!_added.isClosed) _added.add(line);
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
  /// line will get.
  Map<String, Object> since(int? from) => {
        'lines': [for (final l in _lines) if (from == null || (l['n'] as int) >= from) l],
        'next': _next,
      };

  void clear() => _lines.clear();

  /// The number of the line written last (null before any): what an event links to.
  int? get last => _next == 0 ? null : _next - 1;
}
