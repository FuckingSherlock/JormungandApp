import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show PickState;

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';

/// The small building blocks of the Nodes screen and its sheets, named after the mockup's CSS
/// classes (`.icon-btn`, `.mini-toggle`, `.chip`, `.form-input`, `.set-group`, `.sub-checkbox`,
/// `.btn-primary`, `.warn-note`, the Fastest / Priority `.seg-switch`).

/// The text colour on an accent-filled surface (the mockup's `#fff`).
Color onAccentOf(BuildContext context) =>
    Theme.of(context).colorScheme.onPrimary;

/// The English word "Fastest": the glossary keeps Fastest / Auto / Direct untranslated.
const String fastestLabel = 'Fastest';

enum IconBtnKind { normal, primary, ghost }

/// `.icon-btn`: a 36 px rounded square (ghost: 30 px, no frame; primary: accent fill).
/// [active] frames it in [activeColor] (accent by default): the toggled-on state.
class IconBtn extends StatelessWidget {
  const IconBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.kind = IconBtnKind.normal,
    this.active = false,
    this.activeColor,
  });

  final Widget icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final IconBtnKind kind;
  final bool active;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ghost = kind == IconBtnKind.ghost;
    final primary = kind == IconBtnKind.primary;
    final tone = activeColor ?? c.accent;
    final fg = primary
        ? onAccentOf(context)
        : active
        ? tone
        : c.t2;
    final bg = primary
        ? c.accent
        : ghost
        ? Colors.transparent
        : c.card;
    final border = primary
        ? c.accent
        : ghost
        ? Colors.transparent
        : active
        ? tone
        : c.border;
    final side = ghost ? 30.0 : 36.0;
    Widget w = Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        highlightColor: ghost ? c.t1.tint(.06) : c.cardHi,
        child: SizedBox(
          width: side,
          height: side,
          child: Center(
            child: IconTheme(
              data: IconThemeData(color: fg, size: ghost ? 16 : 17),
              child: icon,
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

/// Turns [child] round and round while [spinning] (`.spin`: an update that is running).
class Spin extends StatefulWidget {
  const Spin({super.key, required this.spinning, required this.child});

  final bool spinning;
  final Widget child;

  @override
  State<Spin> createState() => _SpinState();
}

class _SpinState extends State<Spin> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _ctl.repeat();
  }

  @override
  void didUpdateWidget(Spin old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_ctl.isAnimating) {
      _ctl.repeat();
    } else if (!widget.spinning && _ctl.isAnimating) {
      _ctl.stop();
      _ctl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _ctl, child: widget.child);
}

/// `.mini-toggle`: 32 x 19 switch; the thumb overshoots a little when it slides.
class MiniToggle extends StatelessWidget {
  const MiniToggle({super.key, required this.on, this.onChanged});

  final bool on;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChanged == null ? null : () => onChanged!(!on),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 32,
          height: 19,
          decoration: BoxDecoration(
            color: on ? c.active : c.borderHi,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutBack,
                top: 2,
                left: on ? 15 : 2,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x4D000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: SizedBox(width: 15, height: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.chip`: a rounded choice; [active] fills it with [activeColor] (accent by default).
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.active,
    this.onTap,
    this.activeColor,
    this.small = false,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color? activeColor;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tone = activeColor ?? c.accent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(
          horizontal: small ? 10 : 12,
          vertical: small ? 4 : 7,
        ),
        decoration: BoxDecoration(
          color: active ? tone : c.t1.tint(.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? tone : c.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: small ? 12 : 14,
            fontWeight: FontWeight.w600,
            color: active ? onAccentOf(context) : c.t2,
          ),
        ),
      ),
    );
  }
}

/// `.chip-row`: chips that wrap.
class ChipRow extends StatelessWidget {
  const ChipRow({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Wrap(spacing: 6, runSpacing: 6, children: children),
  );
}

/// `.form-label`: small caps over a field.
class FormLabel extends StatelessWidget {
  const FormLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: .6,
        color: context.colors.t3,
      ),
    ),
  );
}

/// `.form-group`: a label (optional) over [child], padded like the sheets.
class FormGroup extends StatelessWidget {
  const FormGroup({
    super.key,
    this.label,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
  });

  final String? label;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [if (label != null) FormLabel(label!), child],
    ),
  );
}

/// `.set-hint`.
class HintText extends StatelessWidget {
  const HintText(this.text, {super.key, this.warn = false});

  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.35,
          color: warn ? c.warn : c.t2,
        ),
      ),
    );
  }
}

/// `.form-input`: a filled, framed text field.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.hint,
    this.lines = 1,
    this.mono = false,
    this.keyboardType,
    this.obscure = false,
    this.onChanged,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? hint;
  final int lines;
  final bool mono;
  final TextInputType? keyboardType;
  final bool obscure;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: color),
    );
    final base = mono ? monoText : const TextStyle();
    return TextField(
      controller: controller,
      minLines: obscure ? 1 : lines,
      maxLines: obscure ? 1 : lines,
      keyboardType:
          keyboardType ?? (lines > 1 ? TextInputType.multiline : null),
      obscureText: obscure,
      autocorrect: false,
      // suggestions on (autocorrect stays off): with them off keyboards like SwiftKey drop the
      // suggestion strip and with it the clipboard button
      enableSuggestions: !obscure,
      autofocus: autofocus,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      cursorColor: c.accent,
      style: base.copyWith(
        fontSize: mono ? 13 : 15,
        height: mono ? 1.45 : null,
        color: c.t1,
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: c.t1.tint(.05),
        hintText: hint,
        hintStyle: TextStyle(color: c.t3, fontSize: mono ? 13 : 15),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        border: border(c.border),
        enabledBorder: border(c.border),
        focusedBorder: border(c.accent),
      ),
    );
  }
}

/// `.set-input`: a borderless field at the right of a [SetRow].
class InlineField extends StatelessWidget {
  const InlineField({
    super.key,
    required this.controller,
    this.hint,
    this.width,
    this.obscure = false,
    this.keyboardType,
    this.alignLeft = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? hint;
  final double? width;
  final bool obscure;
  final TextInputType? keyboardType;
  final bool alignLeft;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final field = TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      autocorrect: false,
      // suggestions on (autocorrect stays off): with them off keyboards like SwiftKey drop the
      // suggestion strip and with it the clipboard button
      enableSuggestions: !obscure,
      onChanged: onChanged,
      textAlign: alignLeft ? TextAlign.left : TextAlign.right,
      cursorColor: c.accent,
      style: TextStyle(fontSize: 15, color: c.t1),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: hint,
        hintStyle: TextStyle(color: c.t3, fontSize: 15),
      ),
    );
    return width == null
        ? Expanded(child: field)
        : SizedBox(width: width, child: field);
  }
}

/// `.set-group`: rows in one framed block, a hairline between them.
class SetGroup extends StatelessWidget {
  const SetGroup({super.key, required this.children, this.card = false});

  final List<Widget> children;

  /// The Settings sheets' groups are on the card colour instead of the faint tint.
  final bool card;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 6, 18, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: card ? c.card : c.t1.tint(.035),
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: c.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// `.set-row`: a label (with a hint under it) and what goes at the right; [stack] puts [below]
/// under the label instead (chip rows).
class SetRow extends StatelessWidget {
  const SetRow({
    super.key,
    this.label,
    this.hint,
    this.trailing,
    this.below,
    this.onTap,
    this.labelWidget,
    this.hintWidget,
  });

  final String? label;
  final Widget? labelWidget;
  final String? hint;

  /// A hint that needs more than a string (a warning colour).
  final Widget? hintWidget;
  final Widget? trailing;
  final Widget? below;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        labelWidget ??
            Text(label ?? '', style: TextStyle(fontSize: 15, color: c.t1)),
        if (hintWidget != null)
          hintWidget!
        else if (hint != null)
          HintText(hint!),
      ],
    );
    final content = below == null
        ? Row(
            children: [
              Expanded(child: head),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [head, const SizedBox(height: 8), below!],
          );
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: c.t1.tint(.03),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Align(alignment: Alignment.centerLeft, child: content),
        ),
      ),
    );
  }
}

/// `.sub-checkbox`: none / some (a dash) / all (a tick).
class SubCheckbox extends StatelessWidget {
  const SubCheckbox({super.key, required this.state});

  final PickState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final all = state == PickState.all;
    final some = state == PickState.some;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: all
            ? c.accent
            : some
            ? c.accent.tint(.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: all || some ? c.accent : c.borderHi,
          width: 1.5,
        ),
      ),
      child: all
          ? Icon(Icons.check, size: 12, color: onAccentOf(context))
          : some
          ? Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(1),
                ),
                child: const SizedBox(width: 8, height: 2),
              ),
            )
          : null,
    );
  }
}

/// `.btn-primary`: the sheet's one big action. Disabled (`onPressed` null) is dimmed.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Opacity(
      opacity: onPressed == null ? .4 : 1,
      child: Material(
        color: c.accent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: onAccentOf(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.btn-danger-text`: a quiet destructive action under the primary one.
class DangerTextButton extends StatelessWidget {
  const DangerTextButton({super.key, required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onPressed,
    splashFactory: NoSplash.splashFactory,
    child: SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: context.colors.muted,
          ),
        ),
      ),
    ),
  );
}

/// `.btn-secondary`: a tinted small button (Check route, Stop).
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Opacity(
      opacity: onPressed == null ? .4 : 1,
      child: Material(
        color: c.accent.tint(.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: c.accent.tint(.35)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: c.accent),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.warn-note`: why the button above stays dimmed, or what went wrong.
class WarnNote extends StatelessWidget {
  const WarnNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: c.warn.tint(.12),
        borderRadius: BorderRadius.circular(c.radius),
        border: Border.all(color: c.warn.tint(.3)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, height: 1.35, color: c.warn),
      ),
    );
  }
}

/// The tiny tag of a line (`.conn-tag`): `chain`, `off`, `priority`.
enum TagTone { accent, muted, warn, off }

class ConnTag extends StatelessWidget {
  const ConnTag(this.text, {super.key, this.tone = TagTone.accent});

  final String text;
  final TagTone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (bg, fg) = switch (tone) {
      TagTone.accent => (c.accent.tint(.15), c.accent),
      TagTone.muted => (c.t1.tint(.06), c.t3),
      TagTone.warn => (c.warn.tint(.15), c.warn),
      TagTone.off => (c.muted.tint(.15), c.muted),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: .4,
            color: fg,
          ),
        ),
      ),
    );
  }
}

/// `.fmt-tag`: a monospace tag (`sing-box`, `manual`, `chain`, `profile`).
class FmtTag extends StatelessWidget {
  const FmtTag(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.t1.tint(.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          text,
          style: monoText.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: c.t2,
          ),
        ),
      ),
    );
  }
}

/// The Fastest / Priority switch of the source entry, profile and chain-exit editors
/// (mockup `pickModeSwitch`): tap a side or swipe, the pill slides across. [trailing] sits at the
/// far right (the ping-all button).
class PickModeSwitch extends StatelessWidget {
  const PickModeSwitch({
    super.key,
    required this.priority,
    required this.onChanged,
    this.trailing,
  });

  final bool priority;
  final ValueChanged<bool> onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    Widget side(String text, bool isPriority) => Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (priority != isPriority) onChanged(isPriority);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          child: Center(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: priority == isPriority ? onAccentOf(context) : c.t2,
              ),
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
      ),
    );
    final switcher = GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 80) return;
        final toPriority = v > 0;
        if (toPriority != priority) onChanged(toPriority);
      },
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.t1.tint(.04),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 280),
                curve: const Cubic(.65, 0, .35, 1),
                alignment: priority
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: .5,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [side(fastestLabel, false), side(l10n.priority, true)],
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: SizedBox(width: double.infinity, child: switcher),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

/// A server list or message inside a framed block (`.se-nodes`, `.cc-nodes`).
class NodesBox extends StatelessWidget {
  const NodesBox({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: 14),
  });

  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(c.radius),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }
}

/// `.route-empty`: a grey line where a list would be.
class EmptyLine extends StatelessWidget {
  const EmptyLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: Text(text, style: TextStyle(fontSize: 13, color: context.colors.t3)),
  );
}

/// The two-circle chain glyph of the mockup (`CHAIN_ICON`).
class ChainIcon extends StatelessWidget {
  const ChainIcon({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? context.colors.t2;
    return CustomPaint(size: Size.square(size), painter: _ChainPainter(color));
  }
}

class _ChainPainter extends CustomPainter {
  _ChainPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * k
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(5 * k, 12 * k), 3 * k, p);
    canvas.drawCircle(Offset(19 * k, 12 * k), 3 * k, p);
    canvas.drawLine(Offset(8 * k, 12 * k), Offset(16 * k, 12 * k), p);
  }

  @override
  bool shouldRepaint(_ChainPainter old) => old.color != color;
}

/// The small round "pinging" ring of a latency slot (`.lat-spin`).
class PingSpinner extends StatelessWidget {
  const PingSpinner({super.key, this.size = 12});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: c.t2,
        backgroundColor: c.t2.tint(.3),
      ),
    );
  }
}
