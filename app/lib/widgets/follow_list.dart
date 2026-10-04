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
  /// so it looks again for a few frames.
  void toBottom({bool smooth = false}) {
    follow = true;
    void go(int left) {
      if (_disposed || !scroll.hasClients) return;
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

/// The values of the [RowMark]s under [list] whose row shows in the viewport of [list] (at least
/// 8 px of it), the way the mockup reads `getBoundingClientRect`. Built rows only: a builder list
/// keeps just the ones near the viewport.
List<T> visibleMarks<T>(BuildContext list) {
  final out = <T>[];
  final viewport = list.findRenderObject();
  if (viewport is! RenderBox || !viewport.hasSize) return out;
  final top = viewport.localToGlobal(Offset.zero).dy;
  final bottom = top + viewport.size.height;
  void visit(Element e) {
    final w = e.widget;
    if (w is RowMark<T>) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) {
        final t = box.localToGlobal(Offset.zero).dy;
        final b = t + box.size.height;
        if (b > top + 8 && t < bottom - 8) out.add(w.value);
      }
      return;
    }
    e.visitChildren(visit);
  }

  (list as Element).visitChildren(visit);
  return out;
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

/// Brings the row of [key] into the middle of the list: a builder list has not built it when it
/// is far away, so the list is first moved to where the row should be and then the row is asked
/// again, a few frames.
Future<void> scrollToRow({
  required ScrollController scroll,
  required GlobalKey key,
  required int index,
  required int count,
}) async {
  for (var i = 0; i < 6; i++) {
    final ctx = key.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: .5,
        duration: const Duration(milliseconds: 1),
      );
      return;
    }
    if (!scroll.hasClients || count == 0) return;
    final max = scroll.position.maxScrollExtent;
    scroll.jumpTo((max * index / count).clamp(0, max).toDouble());
    await WidgetsBinding.instance.endOfFrame;
  }
}
