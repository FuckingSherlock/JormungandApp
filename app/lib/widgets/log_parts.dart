import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show LogLine;

import '../core/core_host.dart' show CoreHostScope;
import '../l10n/l10n.dart';
import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_mark.dart';
import 'event_rows.dart' show LogTag;
import 'follow_list.dart';
import 'form_parts.dart' show onAccentOf;

/// Lines of the same second, level and source follow each other under one meta line (time, level,
/// source): `logKey` / `logGroupHtml` of the mockup.
class RawGroup {
  RawGroup(LogLine first) : lines = [first];

  final List<LogLine> lines;

  LogLine get first => lines.first;

  /// What the group's text and look come from: its first and last line and how many there are
  /// (the numbers only grow, so a group that gained or lost a line is another one).
  (int, int, int) get sig => (lines.first.n, lines.last.n, lines.length);

  static String keyOf(LogLine l) => '${l.t ~/ 1000}|${l.lvl}|${l.src}';
}

List<RawGroup> groupRaw(List<LogLine> lines) {
  final out = <RawGroup>[];
  String? last;
  for (final l in lines) {
    final k = RawGroup.keyOf(l);
    if (out.isNotEmpty && last == k) {
      out.last.lines.add(l);
    } else {
      out.add(RawGroup(l));
      last = k;
    }
  }
  return out;
}

String _two(int n) => n.toString().padLeft(2, '0');

String logClock(int t) {
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}

final _cid = RegExp(r'^\[(\d+ [^\]]+)\] ');

/// sing-box's INFO line naming the Android package of a connection: `[id 5ms] router: found package name: org.x`.
final _foundPkg = RegExp(r'found package name: (\S+)\s*$');

/// `.log-group`: the meta line (time, level tag, `core` tag) over the messages of the group. Each
/// line is a [RowMark] (its number) so the page can tell which are in view; [hit] is the number of
/// the line to light up with [hitToken].
///
/// A group of the same lines with the same look is the same widget: the Logs page keeps the
/// [RawGroupView]s it made and hands out the one of an unchanged group again ([RawGroup.sig]), so a
/// list that is asked for its rows after every batch of lines does not rebuild the rows that did not
/// change (the framework skips a child that is the identical widget).
class RawGroupView extends StatelessWidget {
  const RawGroupView({
    super.key,
    required this.group,
    required this.query,
    required this.unread,
    this.hit,
    this.hitToken,
    this.hitKey,
    this.first = false,
  });

  final RawGroup group;
  final String query;

  /// Numbers of the lines not read yet (only those are marked, the others never need a look).
  final Set<int> unread;
  final int? hit;
  final int? hitToken;
  final GlobalKey? hitKey;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = group.first;
    final tone = f.lvl == 'warn'
        ? c.warn
        : f.lvl == 'error'
        ? c.muted
        : null;
    return Container(
      decoration: BoxDecoration(
        color: tone?.tint(f.lvl == 'error' ? .06 : .05),
        border: Border(
          left: BorderSide(color: tone ?? Colors.transparent, width: 2),
          top: first ? BorderSide.none : BorderSide(color: c.border),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                logClock(f.t),
                style: monoText.copyWith(fontSize: 12, height: 1.45, color: c.t3),
              ),
              const SizedBox(width: 6),
              LogTag(f.lvl == 'warn' ? 'WARN' : f.lvl.toUpperCase(), kind: f.lvl),
              if (f.src == 'core') ...[
                const SizedBox(width: 6),
                const LogTag('core', kind: 'core'),
              ],
            ],
          ),
          for (final (i, l) in group.lines.indexed)
            Padding(
              padding: EdgeInsets.only(top: i > 0 ? 3 : 1),
              child: _line(context, l),
            ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, LogLine l) {
    final c = context.colors;
    final base = monoText.copyWith(
      fontSize: 12,
      height: 1.45,
      color: l.lvl == 'warn' || l.lvl == 'error'
          ? c.t1
          : l.lvl == 'debug'
          ? c.t3
          : c.t2,
    );
    final spans = _spans(context, l.msg, base);
    // sing-box says whose connection it is (`found package name: org.x`): the app's icon and name after the line
    final pkg = _foundPkg.firstMatch(l.msg)?.group(1);
    if (pkg != null) {
      final host = CoreHostScope.read(context), links = AppLinksScope.of(context);
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: AppMark(
              pkg: pkg,
              name: appDisplayName(context.l10n, host.catalog, pkg),
              size: 14,
              style: base,
              onTap: links.openAppAct == null ? null : () => links.openAppAct!(pkg),
            ),
          ),
        ),
      );
    }
    Widget w = Text.rich(TextSpan(children: spans));
    if (hit == l.n) w = HitFlash(token: hitToken, alpha: .35, duration: const Duration(milliseconds: 2200), child: w);
    if (hit == l.n && hitKey != null) w = KeyedSubtree(key: hitKey, child: w);
    return unread.contains(l.n) ? RowMark<int>(value: l.n, child: w) : w;
  }

  List<InlineSpan> _spans(BuildContext context, String msg, TextStyle base) {
    final c = context.colors;
    var rest = msg;
    final out = <InlineSpan>[];
    final m = _cid.firstMatch(rest);
    if (m != null) {
      out.add(TextSpan(text: '${m.group(0)!.trimRight()} ', style: base.copyWith(color: c.t3)));
      rest = rest.substring(m.end);
    }
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      out.add(TextSpan(text: rest, style: base));
      return out;
    }
    final low = rest.toLowerCase();
    var at = 0;
    while (true) {
      final i = low.indexOf(q, at);
      if (i < 0) break;
      if (i > at) out.add(TextSpan(text: rest.substring(at, i), style: base));
      out.add(
        TextSpan(
          text: rest.substring(i, i + q.length),
          style: base.copyWith(color: c.t1, backgroundColor: c.accent.tint(.3)),
        ),
      );
      at = i + q.length;
    }
    if (at < rest.length) out.add(TextSpan(text: rest.substring(at), style: base));
    return out;
  }
}

/// `.log-levels .chip`: a level filter with the unread count on its corner (99+ at most); the
/// colour of the worst unread line: red error, yellow warning, green info.
class LevelChip extends StatelessWidget {
  const LevelChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    required this.unread,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final List<LogLine> unread;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = unread.length;
    final sev = unread.any((l) => l.lvl == 'error')
        ? 'err'
        : unread.any((l) => l.lvl == 'warn')
        ? 'warn'
        : 'ok';
    final (bg, fg) = switch (sev) {
      'err' => (c.danger, Colors.white),
      'warn' => (c.warn, Colors.black),
      _ => (c.active, Colors.black),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: active ? c.accent : c.t1.tint(.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active ? c.accent : c.border),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? onAccentOf(context) : c.t2,
              ),
            ),
          ),
          if (n > 0)
            Positioned(
              top: -6,
              right: -6,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  n > 99 ? '99+' : '$n',
                  style: TextStyle(fontSize: 10, height: 1.6, fontWeight: FontWeight.w700, color: fg),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
