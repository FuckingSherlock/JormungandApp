import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'marquee_text.dart';

/// The generic event card (`connect-model.md`, "Новый вид карточки"): a header, a title, an optional neutral
/// transition line, blocks (switch frame / data box), the Cause line and the buttons. It knows nothing about event
/// types — the caller turns an event into an [EventCardModel]; every text comes ready in the model.

enum CardLevel { warn, error, info, ok }

/// The text of a chip: [title] and the small second line [sub].
class ChipText {
  const ChipText({required this.title, this.sub});
  final String title;
  final String? sub;
}

/// One row of a [SwitchFrame]: a label (one or two lines, `\n`) and the red [from] > green [to] chips.
class SwitchRow {
  const SwitchRow({required this.label, required this.from, required this.to});
  final String label;
  final ChipText from, to;
}

sealed class CardBlock {
  const CardBlock();
}

/// The frame of "from > to" rows; [heading] is the sub-title above it (a block nested in another event).
class SwitchFrame extends CardBlock {
  const SwitchFrame({this.heading, required this.rows});
  final String? heading;
  final List<SwitchRow> rows;
}

sealed class BoxRow {
  const BoxRow();
}

/// "name | value (+ small second line) | ›"; the chevron shows when [onTap] or [onGo] is given ([onGo] is its own tap).
class KeyRow extends BoxRow {
  const KeyRow({this.name, this.icon, this.leading, required this.value, this.sub, this.mark, this.marquee = false, this.onTap, this.onGo});
  final String? name;

  /// The value is a node: a name that does not fit runs as a marquee.
  final bool marquee;
  final IconData? icon;
  final Widget? leading;
  final String value;
  final String? sub;

  /// A small note at the right of the value ("applied", "overridden by rule").
  final String? mark;
  final VoidCallback? onTap;
  final VoidCallback? onGo;
}

/// A sub-title inside a data box ("Checked", "Through VPN").
class CardSection extends BoxRow {
  const CardSection({required this.title});
  final String title;
}

/// A check row: the background by the result, a retry on the left, a jump after a separator on the right.
class CheckRow extends BoxRow {
  const CheckRow({required this.ok, required this.value, this.sub, this.marquee = false, this.onRetry, this.onGo});
  final bool ok;

  /// The value is a node: a name that does not fit runs as a marquee.
  final bool marquee;
  final String value;
  final String? sub;
  final VoidCallback? onRetry;
  final VoidCallback? onGo;
}

class DataBox extends CardBlock {
  const DataBox({required this.rows});
  final List<BoxRow> rows;
}

class CardAction {
  const CardAction({required this.label, required this.onTap, this.details = false});
  final String label;
  final VoidCallback onTap;

  /// The "Details ▾" button: always first.
  final bool details;
}

class EventCardModel {
  EventCardModel({
    required this.level,
    this.icon,
    this.time,
    this.repeats = 1,
    this.background = false,
    required this.title,
    this.transition,
    this.blocks = const [],
    this.cause,
    List<CardAction> actions = const [],
  }) : actions = [
         ...actions.where((a) => a.details),
         ...actions.where((a) => !a.details),
       ];

  final CardLevel level;
  final IconData? icon;
  final String? time;
  final int repeats;
  final bool background;
  final String title;

  /// The grey "A > B" line under the title (neutral chips).
  final (String, String)? transition;
  final List<CardBlock> blocks;

  /// "Cause: (bold) — rest".
  final (String, String)? cause;
  final List<CardAction> actions;
}

/// The result colours of the check rows and the chips: one table, the same in every theme.
class CardTones {
  const CardTones._();
  static const Color bad = Color.fromRGBO(110, 38, 40, 1);
  static const Color good = Color.fromRGBO(28, 92, 48, 1);

  /// `linear-gradient(270deg, c, c .35 at 55%, c .12)`: strong on the right, fading to the left.
  static LinearGradient gradient(Color c) => LinearGradient(
    begin: Alignment.centerRight,
    end: Alignment.centerLeft,
    colors: [c, c.withValues(alpha: .35), c.withValues(alpha: .12)],
    stops: const [0, .55, 1],
  );
}

const double _pad = 11; // the left padding of the label = the label-chips gap
const double _wedge = 14;
const double _labelW = 56;

/// The ambient palette; a theme without the extension (a bare MaterialApp) gets the default one.
AppColors _pal(BuildContext context) => Theme.of(context).extension<AppColors>() ?? AppColors.original;

Color _rowColor(AppColors c) => c.cardHi;

Color _levelColor(AppColors c, CardLevel l) => switch (l) {
  CardLevel.warn => c.warn,
  CardLevel.error => c.danger,
  CardLevel.ok => c.active,
  CardLevel.info => c.border,
};

String _levelLabel(CardLevel l) => switch (l) {
  CardLevel.warn => 'WARN',
  CardLevel.error => 'ERROR',
  CardLevel.info => 'INFO',
  CardLevel.ok => 'OK',
};

class EventCard extends StatelessWidget {
  const EventCard({super.key, required this.model});
  final EventCardModel model;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context), m = model;
    final lc = _levelColor(c, m.level);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: lc, width: 3), bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(model: m, color: lc),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(m.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.t1)),
          ),
          if (m.transition != null) _Transition(from: m.transition!.$1, to: m.transition!.$2),
          for (final b in m.blocks) CardBlockView(block: b),
          if (m.cause != null) _CauseLine(bold: m.cause!.$1, rest: m.cause!.$2),
          if (m.actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (i, a) in m.actions.indexed)
                    OutlinedButton(
                      key: ValueKey('eventCard.action.$i'),
                      onPressed: a.onTap,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: a.details ? c.t2 : c.accent,
                        side: BorderSide(color: c.borderHi),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 34),
                      ),
                      child: Text(a.label),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One block of a card on its own — for a block nested into a card of the old view (DNS in `net/switched`).
class CardBlockView extends StatelessWidget {
  const CardBlockView({super.key, required this.block});
  final CardBlock block;

  @override
  Widget build(BuildContext context) => switch (block) {
        final SwitchFrame b => _FrameView(block: b),
        final DataBox b => _BoxView(block: b),
      };
}

class _Header extends StatelessWidget {
  const _Header({required this.model, required this.color});
  final EventCardModel model;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context), m = model;
    final small = TextStyle(fontSize: 12, color: c.t3);
    return Row(
      children: [
        if (m.icon != null) ...[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: color.withValues(alpha: .18), shape: BoxShape.circle),
            child: Icon(m.icon, size: 15, color: color == c.border ? c.t2 : color),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (m.time != null) Text(m.time!, style: small),
              Text(
                _levelLabel(m.level),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: .5, color: color == c.border ? c.t2 : color),
              ),
              if (m.repeats > 1) Text('×${m.repeats}', style: small),
              if (m.background)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.nightlight_round, key: const ValueKey('evBg'), size: 12, color: c.t3),
                    const SizedBox(width: 2),
                    Text(context.l10n.background.toLowerCase(), style: small),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Transition extends StatelessWidget {
  const _Transition({required this.from, required this.to});
  final String from, to;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    Widget chip(String s) => Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: _rowColor(c), borderRadius: BorderRadius.circular(6)),
        child: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.t2)),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          chip(from),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.chevron_right, size: 16, color: c.t3),
          ),
          chip(to),
        ],
      ),
    );
  }
}

class _FrameView extends StatelessWidget {
  const _FrameView({required this.block});
  final SwitchFrame block;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (block.heading != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(block.heading!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.t2)),
            ),
          Container(
            decoration: BoxDecoration(color: _rowColor(c), borderRadius: BorderRadius.circular(10)),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [for (final r in block.rows) _SwitchRowView(row: r)]),
          ),
        ],
      ),
    );
  }
}

class _SwitchRowView extends StatelessWidget {
  const _SwitchRowView({required this.row});
  final SwitchRow row;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_pad, 4, 0, 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _labelW,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(row.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.t3)),
              ),
            ),
            const SizedBox(width: _pad),
            Expanded(child: _Chip(side: row.from, from: true)),
            Expanded(child: _Chip(side: row.to, from: false)),
          ],
        ),
      ),
    );
  }
}

/// A red / green chip; the red one ends in a wedge, the green one has the matching notch.
class _Chip extends StatelessWidget {
  const _Chip({required this.side, required this.from});
  final ChipText side;
  final bool from;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    return ClipPath(
      clipper: _WedgeClipper(from),
      child: Container(
        decoration: BoxDecoration(gradient: CardTones.gradient(from ? CardTones.bad : CardTones.good)),
        padding: EdgeInsets.fromLTRB(from ? 11 : _wedge + 6, 8, from ? _wedge + 6 : 11, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(side.title, style: TextStyle(fontSize: 14, color: c.t1)),
            if (side.sub != null) Text(side.sub!, style: TextStyle(fontSize: 12.5, color: c.t2)),
          ],
        ),
      ),
    );
  }
}

class _WedgeClipper extends CustomClipper<Path> {
  const _WedgeClipper(this.from);
  final bool from;

  @override
  Path getClip(Size s) {
    final p = Path();
    if (from) {
      p
        ..moveTo(0, 0)
        ..lineTo(s.width - _wedge, 0)
        ..lineTo(s.width, s.height / 2)
        ..lineTo(s.width - _wedge, s.height)
        ..lineTo(0, s.height);
    } else {
      p
        ..moveTo(0, 0)
        ..lineTo(s.width, 0)
        ..lineTo(s.width, s.height)
        ..lineTo(0, s.height)
        ..lineTo(_wedge, s.height / 2);
    }
    return p..close();
  }

  @override
  bool shouldReclip(_WedgeClipper old) => old.from != from;
}

class _BoxView extends StatelessWidget {
  const _BoxView({required this.block});
  final DataBox block;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 8),
      decoration: BoxDecoration(color: _rowColor(c), borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final r in block.rows)
            switch (r) {
              KeyRow() => _KeyRowView(row: r),
              CardSection() => Container(
                width: double.infinity,
                color: c.card,
                padding: const EdgeInsets.fromLTRB(_pad, 8, _pad, 4),
                child: Text(r.title, style: TextStyle(fontSize: 11.5, letterSpacing: .6, color: c.t3)),
              ),
              CheckRow() => _CheckRowView(row: r),
            },
        ],
      ),
    );
  }
}

class _ValueText extends StatelessWidget {
  const _ValueText({required this.value, this.sub, this.marquee = false});
  final String value;
  final String? sub;
  final bool marquee;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    final vs = TextStyle(fontSize: 14, color: c.t1), ss = TextStyle(fontSize: 12.5, color: c.t2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // a node name that does not fit runs as a marquee (`connect-model.md`, "Строка ноды в событии"); any other text wraps
        if (marquee) MarqueeText(value, style: vs) else Text(value, style: vs),
        if (sub != null) if (marquee) MarqueeText(sub!, style: ss) else Text(sub!, style: ss),
      ],
    );
  }
}

class _KeyRowView extends StatelessWidget {
  const _KeyRowView({required this.row});
  final KeyRow row;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    final chev = Icon(Icons.chevron_right, size: 18, color: c.accent);
    return InkWell(
      key: const ValueKey('eventCard.row'),
      onTap: row.onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_pad, 8, _pad, 8),
        child: Row(
          children: [
            if (row.name != null) ...[
              SizedBox(width: _labelW, child: Text(row.name!, style: TextStyle(fontSize: 13, color: c.t3))),
              const SizedBox(width: _pad),
            ],
            if (row.leading != null) ...[row.leading!, const SizedBox(width: 8)],
            if (row.icon != null) ...[Icon(row.icon, size: 18, color: c.t2), const SizedBox(width: 8)],
            Expanded(child: _ValueText(value: row.value, sub: row.sub, marquee: row.marquee)),
            if (row.mark != null) ...[
              const SizedBox(width: 6),
              Flexible(child: Text(row.mark!, textAlign: TextAlign.end, style: TextStyle(fontSize: 11.5, color: c.t3))),
            ],
            if (row.onGo != null)
              InkWell(
                key: const ValueKey('eventCard.go'),
                onTap: row.onGo,
                child: Padding(padding: const EdgeInsets.all(4), child: chev),
              )
            else if (row.onTap != null)
              chev,
          ],
        ),
      ),
    );
  }
}

class _CheckRowView extends StatelessWidget {
  const _CheckRowView({required this.row});
  final CheckRow row;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    // a tap anywhere on the row retries (the refresh icon is only the hint); the jump after the separator is its own tap
    final retry = row.onRetry;
    // no IntrinsicHeight: the marquee lays out by its constraints; the jump is stretched to the row's height by the Stack
    return DecoratedBox(
      decoration: BoxDecoration(gradient: CardTones.gradient(row.ok ? CardTones.good : CardTones.bad)),
      child: Stack(
        children: [
          InkWell(
            key: const ValueKey('eventCard.retry'),
            onTap: retry,
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: retry == null ? null : Center(child: Icon(Icons.refresh, size: 18, color: c.accent)),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _ValueText(value: row.value, sub: row.sub, marquee: row.marquee),
                  ),
                ),
                SizedBox(width: row.onGo != null ? 45 : _pad),
              ],
            ),
          ),
          if (row.onGo != null)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: Row(
                children: [
                  VerticalDivider(width: 1, thickness: 1, color: c.border),
                  InkWell(
                    key: const ValueKey('eventCard.go'),
                    onTap: row.onGo,
                    child: SizedBox(width: 44, child: Center(child: Icon(Icons.chevron_right, size: 18, color: c.accent))),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CauseLine extends StatelessWidget {
  const _CauseLine({required this.bold, required this.rest});
  final String bold, rest;

  @override
  Widget build(BuildContext context) {
    final c = _pal(context);
    // The l10n key `cause` is "Cause: {s0}": the bold part goes where {s0} is, split around a sentinel.
    const mark = '\u0000';
    final parts = context.l10n.cause(mark).split(mark);
    final base = TextStyle(fontSize: 13.5, color: c.t2);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: parts.first),
            TextSpan(text: bold, style: TextStyle(fontWeight: FontWeight.w700, color: c.t1)),
            if (parts.length > 1) TextSpan(text: parts.sublist(1).join()),
            if (rest.isNotEmpty) TextSpan(text: ' — $rest'),
          ],
        ),
      ),
    );
  }
}
