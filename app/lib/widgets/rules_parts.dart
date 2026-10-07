import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'app_view.dart';
import 'form_parts.dart';

/// The small pieces the Rules screens are made of (mockup css/65-rules.css): `.rules-label`,
/// `.seg3`, `.rule-action-badge`, `.app-ico`, `.sheet-tabs`, `.dialog`, the dashed buttons and
/// the round ? help.

/// `.rules-label`: small caps over a group, an optional note after it and an [action] at the end.
class RulesLabel extends StatelessWidget {
  const RulesLabel(this.text, {super.key, this.note, this.action, this.help});

  final String text;
  final String? note;
  final Widget? action;

  /// The round ? after the text.
  final VoidCallback? help;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: .6,
                color: c.t3,
              ),
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Opacity(
                opacity: .8,
                child: Text(
                  note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: c.t3,
                  ),
                ),
              ),
            ),
          ],
          const Spacer(),
          if (help != null) RoundHelp(onTap: help!),
          ?action,
        ],
      ),
    );
  }
}

/// `.help-btn`: the round ? next to a title.
class RoundHelp extends StatelessWidget {
  const RoundHelp({super.key, required this.onTap, this.tight = false});

  final VoidCallback onTap;

  /// No space before it (inside a row that already has a gap).
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: context.l10n.whatIsThis,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(tight ? 0 : 7, 4, 4, 4),
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.borderHi),
            ),
            child: Text(
              '?',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                height: 1,
                color: c.t3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A sheet of "term - what it does" lines (the help of a screen).
Future<void> showTermsSheet(
  BuildContext context,
  String title,
  List<(String, String)> items,
) {
  final c = context.colors;
  return showAppSheet<void>(
    context,
    builder: (_) => SheetFrame(
      title: title,
      bodyPadding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (term, text) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: term,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: c.t1,
                      ),
                    ),
                    TextSpan(text: ' — $text'),
                  ],
                ),
                style: TextStyle(fontSize: 14, height: 1.45, color: c.t2),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The colour of an action word: `proxy` / `vpn` / `main` accent, `direct` the active green,
/// `block` the muted one; anything else (Default) the neutral one.
Color actColor(AppColors c, String act) => switch (act) {
  'proxy' || 'vpn' || 'main' => c.accent,
  'direct' => c.active,
  'block' => c.muted,
  _ => c.t3,
};

/// `.seg3`: a few buttons in one frame, the chosen one filled in its action's colour. [wide] fills
/// the row (the big ones of the rule form); disabled ones are dimmed and ignore taps.
class Seg3 extends StatelessWidget {
  const Seg3({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.wide = false,
    this.enabled = true,
  });

  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;
  final bool wide;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final onFill = onAccentOf(context);
    Widget button(int i) {
      final (v, label) = options[i];
      final on = v == value;
      final text = Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: wide ? 14 : 12,
          fontWeight: FontWeight.w600,
          color: on ? onFill : c.t2,
        ),
      );
      final cell = InkWell(
        onTap: enabled ? () => onChanged(v) : null,
        splashFactory: NoSplash.splashFactory,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 6 : 9,
            vertical: wide ? 8 : 6,
          ),
          decoration: BoxDecoration(
            color: on ? actColor(c, v) : null,
            border: i > 0 ? Border(left: BorderSide(color: c.border)) : null,
          ),
          child: wide ? Center(child: text) : text,
        ),
      );
      return wide ? Expanded(child: cell) : cell;
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (var i = 0; i < options.length; i++) button(i)],
        ),
      ),
    );
  }
}

/// `.rule-action-badge`: what a rule does, in the colour of the action.
class ActionBadge extends StatelessWidget {
  const ActionBadge({super.key, required this.act, required this.text});

  final String act;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tone = actColor(c, act);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 110),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tone.tint(
            act == 'proxy'
                ? .15
                : act == 'direct'
                ? .12
                : .14,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: tone,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.sheet-tabs`: Form | JSON, Export | Import.
class SheetTabs extends StatelessWidget {
  const SheetTabs({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
  });

  final List<(String, String)> tabs;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Row(
        children: [
          for (final (i, (id, label)) in tabs.indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(id),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: id == value ? c.accent : c.t1.tint(.04),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: id == value ? onAccentOf(context) : c.t2,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A framed text field with a magnifier (`.search`) or without ([rules-tools]'s `.form-input`).
class SearchBox extends StatelessWidget {
  const SearchBox({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.icon = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final bool icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color),
    );
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autocorrect: false,
      enableSuggestions: false,
      cursorColor: c.accent,
      style: TextStyle(fontSize: 15, color: c.t1),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: c.t1.tint(.05),
        hintText: hint,
        hintStyle: TextStyle(color: c.t3, fontSize: 15),
        prefixIcon: icon ? Icon(Icons.search, size: 18, color: c.t3) : null,
        prefixIconConstraints: const BoxConstraints(minWidth: 38),
        contentPadding: EdgeInsets.symmetric(
          horizontal: icon ? 0 : 12,
          vertical: 10,
        ),
        border: border(c.border),
        enabledBorder: border(c.border),
        focusedBorder: border(c.accent),
      ),
    );
  }
}

/// A rectangle with a dashed edge (`border: 1px dashed`).
class DashedBox extends StatelessWidget {
  const DashedBox({
    super.key,
    required this.child,
    this.radius = 12,
    this.color,
    this.margin,
    this.padding,
  });

  final Widget child;
  final double radius;
  final Color? color;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final line = color ?? context.colors.borderHi;
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: CustomPaint(
        painter: _DashPainter(line, radius),
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color, this.radius);

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ).deflate(.5),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) =>
      old.color != color || old.radius != radius;
}

/// `.node-add.rf-add-btn`: a dashed "+ ..." button.
class DashedAddButton extends StatelessWidget {
  const DashedAddButton(this.label, {super.key, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DashedBox(
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashFactory: NoSplash.splashFactory,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: c.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.dialog`: the small centred card of a short question ([title], the [child], buttons at the right).
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext) builder,
  required List<Widget> Function(BuildContext) actions,
}) {
  final c = context.colors;
  return showDialog<T>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: c.sheet,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.borderHi),
      ),
      child: ContentScale(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.t1,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: builder(ctx))),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final (i, a) in actions(ctx).indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    a,
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A row of a `.set-group` that goes on to another sheet: label, a line under it, a chevron.
class ChevronRow extends StatelessWidget {
  const ChevronRow({
    super.key,
    required this.label,
    this.hint,
    required this.onTap,
    this.labelWidget,
    this.trailing,
  });

  final String label;
  final Widget? labelWidget;
  final String? hint;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SetRow(
      label: label,
      labelWidget: labelWidget,
      hint: hint,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?trailing,
          Icon(Icons.chevron_right, size: 16, color: c.t3),
        ],
      ),
    );
  }
}

/// A fixed hue per name for the letter tile of an app.
int _hueOf(String s) {
  var h = 0;
  for (final u in s.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return h % 360;
}

/// `.app-ico`: the app's own icon when the platform gives one, else its first letter on a tint
/// that follows the package.
class AppIcon extends StatefulWidget {
  const AppIcon({super.key, required this.pkg, required this.name, this.size = 32});

  final String pkg;
  final String name;

  /// The side of the tile (32 in the lists, smaller where an app is only named: events, connections).
  final double size;

  @override
  State<AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<AppIcon> {
  Future<Uint8List?>? _icon;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _icon ??= CoreHostScope.read(context).appIcon(widget.pkg);
  }

  @override
  Widget build(BuildContext context) {
    final h = _hueOf(widget.pkg).toDouble();
    final letter = widget.name.isEmpty
        ? '?'
        : String.fromCharCode(widget.name.runes.first).toUpperCase();
    final s = widget.size, radius = BorderRadius.circular(9 * s / 32);
    final tile = Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(.18, h, .6, .55).toColor(),
        borderRadius: radius,
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 15 * s / 32,
          fontWeight: FontWeight.w700,
          color: HSLColor.fromAHSL(1, h, .7, .72).toColor(),
        ),
      ),
    );
    return FutureBuilder<Uint8List?>(
      future: _icon,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return tile;
        return ClipRRect(
          borderRadius: radius,
          child: Image.memory(
            bytes,
            width: s,
            height: s,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => tile,
          ),
        );
      },
    );
  }
}
