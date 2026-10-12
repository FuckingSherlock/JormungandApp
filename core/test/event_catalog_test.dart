// A guard on the events catalog (`eventCats`, docs/logs.md → События): every (cat, type) the core
// or the app writes into the journal is in the catalog, and every catalog type has its words in the
// app. Added to after two types (`conn/failing`, `core/tunTcpDead`, the whole `core/update*` family)
// reached the journal with no entry anywhere and showed up as «core / updateFailed».
//
// It reads the sources: the emit sites in core/lib/src and app/lib are found by pattern, so a new
// way of writing an event is a failure here ("dynamic site"), not a silent gap. The app's tree is
// skipped when it is not next to the core (the core published alone).
import 'dart:io';

import 'package:jormungand_core/jormungand_core.dart';
import 'package:test/test.dart';

/// The catalog types the app has no words for yet (`typeLabel` in app/lib/core/event_text.dart):
/// a debt for the Flutter stage (label + ARB en / ru + the sentence of the event), not a state to
/// keep. A type that gets its label must leave this list (the test says so).
const pendingLabels = <String>{'dns/failed'};

/// Types in the catalog that no code of this repository writes: the mockup writes them.
const mockupOnly = <String>{'sub/dead'};

/// Emit sites whose type (or category) is a variable, by `file|call|first argument|second argument`.
/// What they can write is found by the other patterns (below), so the entry only says "known":
/// a new variable site must be added here on purpose, with where its values come from.
const dynamicSites = <String, String>{
  // the snapshot store's recovery notes (state.dart `_report('stateRestored' | 'stateLost')`)
  'service.dart|_event|core|type': 'state.dart _report(…) and appupdate.dart _event(…): category core',
  // the subscription updater's `onEvent('updated' | 'failed', …)` (updater.dart)
  'service.dart|_event|sub|type': 'updater.dart onEvent(…): category sub',
  // what the app / the page posts (POST /api/events): validated at run time (EventBook.cats, level, shape)
  'service.dart|eventBook.add|cat|type': 'postEvent: whatever the UI posted',
};

final _levels = {'info', 'warn', 'error'};

void main() {
  final coreSrc = Directory('lib/src');
  final appLib = Directory('../app/lib');

  group('events catalog', () {
    final catalog = <String>{
      for (final (cat, types) in eventCats)
        for (final t in types) '$cat/$t',
    };

    test('every event the core writes is in eventCats', () {
      final found = _coreEmits(coreSrc);
      expect(found.sites, greaterThan(0), reason: 'the scanner found no emit site: the patterns went stale');
      final missing = <String>[];
      for (final e in found.pairs.entries) {
        final (cat, type) = e.key;
        if (cat == 'user') continue; // the app's own actions: outside the catalog by design
        if (!catalog.contains('$cat/$type')) missing.add('$cat/$type  (${e.value.join(', ')})');
      }
      expect(missing, isEmpty, reason: _howToAdd(missing));
    });

    test('variable emit sites are the known ones', () {
      final found = _coreEmits(coreSrc);
      final unknown = [for (final d in found.dynamicSites) if (!dynamicSites.containsKey(d)) d];
      expect(unknown, isEmpty,
          reason: 'A call that writes an event with a type in a variable is not covered by the scan: '
              'add it to `dynamicSites` in core/test/event_catalog_test.dart with where its values come from, '
              'and make sure those values are literals the scan reads (or list them as literals).');
      final stale = [for (final k in dynamicSites.keys) if (!found.dynamicSites.contains(k)) k];
      expect(stale, isEmpty, reason: 'dynamicSites lists a site that is gone: remove it');
    });

    test('every type of the catalog is written somewhere (or is the mockup\'s)', () {
      if (!appLib.existsSync()) {
        markTestSkipped('no ../app/lib next to the core: the app writes some of the types');
        return;
      }
      final written = {
        for (final k in _coreEmits(coreSrc).pairs.keys) '${k.$1}/${k.$2}',
        for (final k in _appEmits(appLib).pairs.keys) '${k.$1}/${k.$2}',
      };
      final never = [for (final k in catalog) if (!written.contains(k) && !mockupOnly.contains(k)) k];
      expect(never, isEmpty, reason: 'in eventCats but written by no code here: a stale entry, or an emit site the scan cannot read');
      final stale = [for (final k in mockupOnly) if (written.contains(k)) k];
      expect(stale, isEmpty, reason: 'now written by the core: remove it from mockupOnly');
    });

    test('every event the app posts is in eventCats', () {
      if (!appLib.existsSync()) {
        markTestSkipped('no ../app/lib next to the core');
        return;
      }
      final found = _appEmits(appLib);
      expect(found.sites, greaterThan(0), reason: 'the scanner found no emit site in the app: the patterns went stale');
      expect(found.dynamicSites, isEmpty,
          reason: 'the app writes an event whose type / category is a variable: ${found.dynamicSites.join(', ')} — write it as literals');
      final missing = <String>[];
      for (final e in found.pairs.entries) {
        final (cat, type) = e.key;
        if (cat == 'user') continue;
        if (!catalog.contains('$cat/$type')) missing.add('$cat/$type  (${e.value.join(', ')})');
      }
      expect(missing, isEmpty, reason: _howToAdd(missing));
    });

    test('every type of the catalog has its words in the app (or is a known debt)', () {
      final text = File('../app/lib/core/event_text.dart');
      if (!text.existsSync()) {
        markTestSkipped('no ../app/lib next to the core');
        return;
      }
      final labelled = {for (final m in RegExp(r"'([a-z]+/[A-Za-z]+)'\s*=>").allMatches(text.readAsStringSync())) m[1]!};
      final noWords = [for (final k in catalog) if (!labelled.contains(k) && !pendingLabels.contains(k)) k];
      expect(noWords, isEmpty,
          reason: 'No label in app/lib/core/event_text.dart `typeLabel` (and a sentence in the event\'s description, '
              'strings in app/lib/l10n en + ru via app/tool/i18n_extra.json): ${noWords.join(', ')}');
      final paid = [for (final k in pendingLabels) if (labelled.contains(k)) k];
      expect(paid, isEmpty, reason: 'has its label now: remove from `pendingLabels`: ${paid.join(', ')}');
      final gone = [for (final k in pendingLabels) if (!catalog.contains(k)) k];
      expect(gone, isEmpty, reason: 'not in eventCats any more: remove from `pendingLabels`: ${gone.join(', ')}');
    });

    test('the catalog itself: no repeats, every cat is one the journal accepts', () {
      expect(catalog.length, eventCats.fold(0, (a, c) => a + c.$2.length), reason: 'a type listed twice');
      for (final (cat, _) in eventCats) {
        expect(EventBook.cats, contains(cat));
      }
    });
  });

  group('the scanner', () {
    test('reads literal calls, tuples, balanced arguments and named cat', () {
      const src = r'''
        void run() {
          _event('core', 'down', 'error', {'a': 1});
          eventBook.add('conn',
              'connected', 'info', data: {'x': '${m['k']}'});
          _journal('pin', {'x': 'a, b'}, cat: 'sub', level: 'warn');
          // _event('core', 'commented', 'info', {});
        }
      ''';
      expect(_args(src, src.indexOf('_event(') + 6)!.split(',').first, "'core'");
      final j = src.indexOf('_journal(') + 8;
      expect(_splitArgs(_args(src, j)!), ["'pin'", "{'x': 'a, b'}", "cat: 'sub'", "level: 'warn'"]);
    });
  });
}

String _howToAdd(List<String> missing) =>
    'Not in eventCats (core/lib/src/log_view.dart): ${missing.join('; ')}.\n'
    'A new event goes in one commit into: eventCats, the label in app/lib/core/event_text.dart (`typeLabel`) '
    'with its strings in app/lib/l10n (en + ru, app/tool/i18n_extra.json), and the table in docs/logs.md '
    '(→ События). If the pair is the app\'s own action, its category is `user`.';

class _Found {
  /// (cat, type) → where (file:line).
  final pairs = <(String, String), List<String>>{};

  /// `file|call|first|second` of calls whose type or category is a variable.
  final dynamicSites = <String>{};
  int sites = 0;

  void add(String cat, String type, String where) {
    sites++;
    (pairs[(cat, type)] ??= []).add(where);
  }
}

// `//` comments out (not the `//` of a URL in a string: it follows a colon)
String _code(String s) => s.replaceAll(RegExp(r'(?<!:)//.*$', multiLine: true), '');

int _line(String s, int at) => '\n'.allMatches(s.substring(0, at)).length + 1;

// Where a string literal that starts at [i] ends (after the closing quote): escapes and `${…}` honoured.
int _skipString(String s, int i) {
  final q = s[i];
  i++;
  while (i < s.length) {
    final c = s[i];
    if (c == r'\') {
      i += 2;
    } else if (c == r'$' && i + 1 < s.length && s[i + 1] == '{') {
      i = _skipBraces(s, i + 1);
    } else if (c == q) {
      return i + 1;
    } else {
      i++;
    }
  }
  return s.length;
}

// [i] is a `{`: where its matching `}` ends
int _skipBraces(String s, int i) {
  var depth = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '{') depth++;
    if (c == '}' && --depth == 0) return i + 1;
    i++;
  }
  return s.length;
}

/// The text inside the parentheses that open at [open] (the index of `(`), or null when unbalanced.
String? _args(String s, int open) {
  var depth = 0;
  var i = open;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return s.substring(open + 1, i);
    i++;
  }
  return null;
}

/// [args] cut at the commas of its top level, each trimmed.
List<String> _splitArgs(String args) {
  final out = <String>[];
  var depth = 0, start = 0, i = 0;
  while (i < args.length) {
    final c = args[i];
    if (c == "'" || c == '"') {
      i = _skipString(args, i);
      continue;
    }
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if (c == ',' && depth == 0) {
      out.add(args.substring(start, i).trim());
      start = i + 1;
    }
    i++;
  }
  final last = args.substring(start).trim();
  if (last.isNotEmpty) out.add(last);
  return out;
}

String? _literal(String arg) {
  final m = RegExp(r"^'([A-Za-z0-9_]+)'$").firstMatch(arg);
  return m?[1];
}

bool _isIdent(String arg) => RegExp(r'^[a-z][A-Za-z0-9_]*$').hasMatch(arg);

Iterable<File> _dartFiles(Directory d) => d.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));

String _name(File f) => f.path.replaceAll('\\', '/').split('/').last;

// ── the core ──

// A file that writes events with the category implied: `_event('type', 'level', data)` (appupdate.dart),
// `_report('type', 'level', …)` (state.dart), `onEvent('type', data)` (updater.dart).
final _implied = <String, (String cat, RegExp call)>{
  'appupdate.dart': ('core', RegExp(r'(?<![A-Za-z0-9_])_event\(')),
  'state.dart': ('core', RegExp(r'(?<![A-Za-z0-9_])_report\(')),
  'updater.dart': ('sub', RegExp(r'(?<![A-Za-z0-9_])onEvent(?:!\(|\?\.call\()')),
};

// `SuspicionEvent('cat', 'type', …)`: the event a detector hands to the Sentinel, which writes it with its verdict
// `_siteKind('cat', 'type')`: the (cat, type) a verdict of the site judge (service.dart) picks for its SuspicionEvent
final _withCat = RegExp(r'(?<![A-Za-z0-9_.])(_event|eventBook\.add|SuspicionEvent|_siteKind)\(');

_Found _coreEmits(Directory dir) {
  final f = _Found();
  for (final file in _dartFiles(dir)) {
    final path = file.path.replaceAll('\\', '/');
    if (path.contains('/sbapi/')) continue;
    final name = _name(file);
    if (name == 'eventbook.dart') continue; // the book's own internals
    final src = _code(file.readAsStringSync());

    for (final m in _withCat.allMatches(src)) {
      final before = src.substring(0, m.start).trimRight();
      // `int _event(String cat, …` / `void _event(…`: the definition
      if (before.endsWith(' int') || before.endsWith(' void') || before.endsWith('\nint') || before.endsWith('\nvoid')) continue;
      final inner = _args(src, m.end - 1);
      if (inner == null) continue;
      final a = _splitArgs(inner);
      if (a.isEmpty) continue;
      if (a[0].startsWith('this.')) continue; // the constructor of SuspicionEvent itself
      if (a[0].startsWith('String ')) continue; // the definition of `_siteKind`
      final where = '$name:${_line(src, m.start)}';
      final implied = _implied[name];
      final first = _literal(a[0]);
      // appupdate.dart: `_event('type', 'level', data)`
      if (implied != null && first != null && a.length > 1 && _levels.contains(_literal(a[1]))) {
        f.add(implied.$1, first, where);
        continue;
      }
      if (a.length < 2) continue;
      final second = _literal(a[1]);
      if (first != null && second != null) {
        f.add(first, second, where);
      } else if (first != null && _isIdent(a[1])) {
        final key = '$name|${m[1]}|$first|${a[1]}';
        f.dynamicSites.add(key);
        f.sites++;
        // the (type, level) tuples written in front of the call (`'lost' => ('lost', 'warn')`)
        final win = src.substring((m.start - 600).clamp(0, m.start), m.start);
        for (final t in RegExp(r"=>\s*\(\s*'([A-Za-z]+)'\s*,\s*'(?:info|warn|error)'\s*\)").allMatches(win)) {
          f.add(first, t[1]!, where);
        }
      } else if (_isIdent(a[0]) && _isIdent(a[1])) {
        f.dynamicSites.add('$name|${m[1]}|cat|type');
        f.sites++;
      } else if (first == null && implied == null) {
        f.dynamicSites.add('$name|${m[1]}|?|?');
        f.sites++;
      }
    }

    final implied = _implied[name];
    if (implied != null) {
      for (final m in implied.$2.allMatches(src)) {
        final before = src.substring(0, m.start).trimRight();
        if (before.endsWith(' int') || before.endsWith(' void') || before.endsWith('\nvoid')) continue;
        final inner = _args(src, m.end - 1);
        if (inner == null) continue;
        final a = _splitArgs(inner);
        final first = a.isEmpty ? null : _literal(a[0]);
        if (first == null) continue; // `_report(sid, s, patch)` of the updater: not an event
        // `_event('type', 'level', …)` was read above; `_report('type', 'level', …)` and `onEvent('type', {…})` here
        if (name == 'appupdate.dart') continue;
        f.add(implied.$1, first, '$name:${_line(src, m.start)}');
      }
    }
  }
  return f;
}

// ── the app ──

_Found _appEmits(Directory dir) {
  final f = _Found();
  final call = RegExp(r'(?<![A-Za-z0-9_])(_journal|postEvent)\(');
  for (final file in _dartFiles(dir)) {
    final src = _code(file.readAsStringSync());
    final name = _name(file);
    for (final m in call.allMatches(src)) {
      final before = src.substring(0, m.start).trimRight();
      // a definition: `void postEvent(`, `Future<void> postEvent(`
      if (before.endsWith('void') || before.endsWith('void>') || before.endsWith('int')) continue;
      final inner = _args(src, m.end - 1);
      if (inner == null) continue;
      final a = _splitArgs(inner);
      if (a.isEmpty) continue;
      final where = '$name:${_line(src, m.start)}';
      if (m[1] == '_journal') {
        final type = _literal(a[0]);
        var cat = 'user';
        String? dyn;
        for (final x in a.skip(1)) {
          final c = RegExp(r'^cat:\s*(.+)$', dotAll: true).firstMatch(x);
          if (c == null) continue;
          final lit = _literal(c[1]!.trim());
          if (lit == null) {
            dyn = c[1]!.trim();
          } else {
            cat = lit;
          }
        }
        if (type == null || dyn != null) {
          f.dynamicSites.add('$where _journal(${type == null ? a[0] : "'$type'"}${dyn != null ? ', cat: $dyn' : ''})');
          f.sites++;
        } else {
          f.add(cat, type, where);
        }
      } else {
        // `postEvent('cat', 'type', …)` of the host; another postEvent (the notifier's) takes no literal
        final cat = _literal(a[0]);
        final type = a.length > 1 ? _literal(a[1]) : null;
        if (cat != null && type != null) f.add(cat, type, where);
      }
    }
  }
  return f;
}
