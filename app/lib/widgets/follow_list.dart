import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';
import 'form_parts.dart' show onAccentOf;

/// A list that follows what arrives while it is at its bottom and stays put when scrolled up
/// (mockup 46-logs.js `evFollow` / `evScrolled`): the logs open at the bottom, the newest line
/// last. [onChange] says when the list leaves or returns to its end (the "↓ N new" pill).
class FollowController {
  FollowController({this.onChange}) {
    scroll.addListener(_onScroll);
  }

  final scroll = ScrollController();
  final void Function(bool follow)? onChange;
  bool follow = true;
  DateTime _smoothUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  bool get _atEnd =>
      !scroll.hasClients ||
      scroll.position.pixels >= scroll.position.maxScrollExtent - 24;

  void _onScroll() {
    if (!scroll.hasClients) return;
    final atEnd = _atEnd;
    // the steps of our own smooth scroll are still a few pixels away from the end
    if (!atEnd && follow && DateTime.now().isBefore(_smoothUntil)) return;
    if (atEnd == follow) return;
    follow = atEnd;
    onChange?.call(follow);
  }

  /// To the bottom; the extent of a builder list is an estimate until the rows are laid out,
  /// so it looks again for a few frames - unless the list was left (scrolled up, a row jumped to)
  /// in the meantime: its next frame must not pull it back.
  void toBottom({bool smooth = false}) {
    follow = true;
    void go(int left) {
      if (_disposed || !follow || !scroll.hasClients) return;
      final max = scroll.position.maxScrollExtent;
      if (smooth && left == 4 && scroll.position.pixels < max - 1) {
        _smoothUntil = DateTime.now().add(const Duration(milliseconds: 700));
        scroll.animateTo(
          max,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
        return;
      }
      if (scroll.position.pixels < max - 1) scroll.jumpTo(max);
      if (left > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => go(left - 1));
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => go(4));
  }

  /// Keeps the follow state after the content changed.
  void afterContent({bool smooth = false}) {
    if (follow) toBottom(smooth: smooth);
  }

  void dispose() {
    _disposed = true;
    scroll.dispose();
  }
}

/// Marks a row of a list with a value; [visibleMarks] finds the rows that are in the viewport.
class RowMark<T> extends StatelessWidget {
  const RowMark({super.key, required this.value, required this.child});

  final T value;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// The place of a row in its data, a number that only grows with the data (a raw line number, an
/// event id): what [AnchoredList] keeps a list to while rows come and go at its head.
class RowAnchor {
  const RowAnchor(this.order);

  final int order;
}

/// The built `RowMark<T>` rows under [list] with where they sit relative to the top of the
/// viewport of [list] (the way the mockup reads `getBoundingClientRect`), and the viewport's
/// height. Built rows only: a builder list keeps just the ones near the viewport.
({List<({T value, double top, double bottom})> rows, double height}) _builtMarks<T>(BuildContext list) {
  final out = <({T value, double top, double bottom})>[];
  final viewport = list.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return (rows: out, height: 0);
  final top = viewport.localToGlobal(Offset.zero).dy;
  void visit(Element e) {
    final w = e.widget;
    if (w is RowMark<T>) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) {
        final t = box.localToGlobal(Offset.zero).dy - top;
        out.add((value: w.value, top: t, bottom: t + box.size.height));
      }
      return;
    }
    e.visitChildren(visit);
  }

  (list as Element).visitChildren(visit);
  return (rows: out, height: viewport.size.height);
}

/// The values of the [RowMark]s under [list] whose row shows in the viewport of [list] (at least
/// 8 px of it).
List<T> visibleMarks<T>(BuildContext list) {
  final m = _builtMarks<T>(list);
  return [
    for (final r in m.rows)
      if (r.bottom > 8 && r.top < m.height - 8) r.value,
  ];
}

/// The topmost row marked with a [RowAnchor] that shows in the viewport of [list] and passes
/// [where], with where its top is (negative: it starts above the viewport).
({int order, double top})? firstVisibleRow(BuildContext list, {bool Function(int order)? where}) {
  final m = _builtMarks<RowAnchor>(list);
  ({int order, double top})? best;
  for (final r in m.rows) {
    if (r.bottom <= 1 || r.top >= m.height) continue;
    if (where != null && !where(r.value.order)) continue;
    if (best == null || r.top < best.top) best = (order: r.value.order, top: r.top);
  }
  return best;
}

/// A list of rows in data order, laid out around a pivot instead of from its first row (a
/// [CustomScrollView] with a `center`): the rows from [pivot] on go below the scroll origin, the
/// older ones above it. What the user looks at keeps its place when rows fall off the head of the
/// data or arrive at its tail, however the indices move - the viewport is measured from the pivot,
/// not from the first row. With no [pivot] it is the plain list from the first row (a list that
/// follows its end).
///
/// [orderAt] gives the data order of row `i` (never decreases); [indexOfKey] finds the row a key
/// of the built widgets belongs to, so the rows keep their elements while indices move.
class AnchoredList extends StatelessWidget {
  const AnchoredList({
    super.key,
    required this.controller,
    required this.count,
    required this.orderAt,
    required this.itemBuilder,
    this.indexOfKey,
    this.pivot,
    this.bottomPadding = 64,
  });

  final ScrollController controller;
  final int count;
  final int Function(int i) orderAt;
  final Widget Function(BuildContext context, int i) itemBuilder;
  final int? Function(Key key)? indexOfKey;
  final int? pivot;
  final double bottomPadding;

  static const _centerKey = ValueKey('anchoredListCenter');

  /// The index of the first row that belongs below the origin.
  int get split {
    final p = pivot;
    if (p == null) return 0;
    var lo = 0, hi = count;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (orderAt(mid) < p) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  @override
  Widget build(BuildContext context) {
    final cut = split;
    final find = indexOfKey;
    return CustomScrollView(
      controller: controller,
      center: _centerKey,
      slivers: [
        // older rows: the child at 0 is the one next to the origin, the list grows upwards
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, j) => itemBuilder(context, cut - 1 - j),
            childCount: cut,
            findChildIndexCallback: find == null
                ? null
                : (key) {
                    final i = find(key);
                    return i == null || i >= cut ? null : cut - 1 - i;
                  },
            addAutomaticKeepAlives: false,
          ),
        ),
        SliverPadding(
          key: _centerKey,
          padding: EdgeInsets.only(bottom: bottomPadding),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, j) => itemBuilder(context, cut + j),
              childCount: count - cut,
              findChildIndexCallback: find == null
                  ? null
                  : (key) {
                      final i = find(key);
                      return i == null || i < cut ? null : i - cut;
                    },
              addAutomaticKeepAlives: false,
            ),
          ),
        ),
      ],
    );
  }
}

/// The pill over the bottom of a list: "↓ Latest", or "↓ 3 new".
class JumpPill extends StatelessWidget {
  const JumpPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: Color(0x59000000), blurRadius: 14, offset: Offset(0, 4)),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: onAccentOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lights [child] for a moment when [token] changes to a non-null value (a row that was jumped
/// to): the accent tint holds, then fades (`ev-hit` / `log-hit`).
class HitFlash extends StatefulWidget {
  const HitFlash({
    super.key,
    required this.token,
    required this.child,
    this.alpha = .22,
    this.duration = const Duration(milliseconds: 2600),
  });

  final int? token;
  final Widget child;
  final double alpha;
  final Duration duration;

  @override
  State<HitFlash> createState() => _HitFlashState();
}

class _HitFlashState extends State<HitFlash> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.token != null) _ctl.forward(from: 0);
  }

  @override
  void didUpdateWidget(HitFlash old) {
    super.didUpdateWidget(old);
    if (widget.token != null && widget.token != old.token) _ctl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, child) {
        // 0..55 % full, then to nothing
        final v = _ctl.value;
        final k = v >= 1 || v == 0 ? 0.0 : v < .55 ? 1.0 : 1 - (v - .55) / .45;
        return DecoratedBox(
          decoration: BoxDecoration(color: k == 0 ? null : c.accent.tint(widget.alpha * k)),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Brings the row of [key] into the middle of the list. The list is expected to have been
/// pivoted on that row ([AnchoredList.pivot], the origin at 0): it is built where it is looked
/// for, and appears within a frame or two.
Future<void> showRow(GlobalKey key) async {
  for (var i = 0; i < 6; i++) {
    final ctx = key.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: .5,
        duration: const Duration(milliseconds: 1),
      );
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
  }
}

/// Moves the scroll origin of [scroll] to [pixels] (in the pivoted list's own coordinates) for a
/// change of the pivot that is applied in the frame being built. A list that is being scrolled
/// by a fling is jumped (its simulation holds absolute positions), any other has its position
/// corrected without a notification: nothing hears of a move that is not one.
void shiftScroll(ScrollController scroll, double pixels) {
  if (!scroll.hasClients) return;
  final p = scroll.position;
  if (p.isScrollingNotifier.value) {
    scroll.jumpTo(pixels);
  } else {
    p.correctPixels(pixels);
  }
}
