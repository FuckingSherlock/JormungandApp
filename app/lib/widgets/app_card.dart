import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';

/// The mockup's `--mono`: the flag font first, then a monospace face.
const TextStyle monoText = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: [kFlagsFontFamily, 'Roboto Mono', 'Consolas'],
);

/// Width of [chars] characters of [monoText] at [fontSize], at the current text scale: the fixed
/// slots of the stat cards (`min-width:5ch`), so live numbers never move their neighbours.
double monoSlot(BuildContext context, int chars, double fontSize) =>
    MediaQuery.textScalerOf(context).scale(chars * fontSize * .6);

/// `.card`: card background, 1 px border, rounded; tappable when [onTap] is given.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(c.radius),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        highlightColor: c.cardHi,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
