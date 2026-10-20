import 'package:flutter/material.dart';

/// One line of text that scrolls sideways when it does not fit the width (a server's name + protocol in an event
/// row): static when it fits, otherwise a slow loop with a pause at each end. Respects "remove animations"
/// (`MediaQuery.disableAnimations`): the line is then cut with an ellipsis. The ticker is muted by [TickerMode]
/// while the row is not visible and stopped on dispose.
class MarqueeText extends StatelessWidget {
  const MarqueeText(this.text, {super.key, this.style, this.speed = 28, this.pause = const Duration(seconds: 1, milliseconds: 200)});

  final String text;
  final TextStyle? style;

  /// Logical pixels per second.
  final double speed;

  /// How long the text stays at each end.
  final Duration pause;

  @override
  Widget build(BuildContext context) {
    final st = DefaultTextStyle.of(context).style.merge(style);
    final scale = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: st),
          textDirection: dir,
          textScaler: scale,
          maxLines: 1,
        )..layout();
        final width = tp.width, height = tp.height;
        tp.dispose();
        final room = box.maxWidth;
        if (!room.isFinite || width <= room + .5 || still) {
          return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);
        }
        return SizedBox(
          height: height,
          child: ClipRect(
            child: _Scroller(
              key: ValueKey('$text|$room'),
              text: text,
              style: style,
              distance: width - room,
              speed: speed,
              pause: pause,
            ),
          ),
        );
      },
    );
  }
}

class _Scroller extends StatefulWidget {
  const _Scroller({super.key, required this.text, required this.style, required this.distance, required this.speed, required this.pause});

  final String text;
  final TextStyle? style;
  final double distance;
  final double speed;
  final Duration pause;

  @override
  State<_Scroller> createState() => _ScrollerState();
}

class _ScrollerState extends State<_Scroller> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;
  late final Animation<double> _pos;

  @override
  void initState() {
    super.initState();
    final run = (widget.distance / widget.speed * 1000).round().clamp(600, 600000);
    final hold = widget.pause.inMilliseconds;
    // hold at the start, scroll to the end, hold, scroll back
    _ctl = AnimationController(vsync: this, duration: Duration(milliseconds: 2 * (hold + run)));
    final total = (2 * (hold + run)).toDouble();
    _pos = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: hold / total),
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)), weight: run / total),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: hold / total),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInOut)), weight: run / total),
    ]).animate(_ctl);
    _ctl.repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pos,
    builder: (context, _) => OverflowBox(
      alignment: Alignment.centerLeft,
      minWidth: 0,
      maxWidth: double.infinity,
      child: Transform.translate(
        offset: Offset(-widget.distance * _pos.value, 0),
        child: Text(widget.text, style: widget.style, maxLines: 1, softWrap: false, overflow: TextOverflow.visible),
      ),
    ),
  );
}
