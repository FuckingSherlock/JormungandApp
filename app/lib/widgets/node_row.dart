import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogNode, protoLabel;

import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'latency_text.dart';

/// What the protocol badge says: `REALITY` for VLESS over Reality, else the protocol (mockup
/// `protoLabel`, uppercased by its CSS).
String nodeProtoLabel(CatalogNode n) =>
    protoLabel(n.protocol, n.outbound).toUpperCase();

/// One server of a list (mockup `.node-row`): flag + name (a long name wraps under the flag),
/// the protocol badge and the latency.
///
/// The plain row is for a list inside a card (a hairline over it). [framed] is the pick style
/// (`.node-row.pick`): a rounded frame, accent when [on] (the server is used); [dim] is a
/// switched-off server (struck name, faded), [gone] one the provider dropped. [onPing] makes the
/// latency its own tap target (the whole height at the right edge), so a tap near the ms never
/// lands on the row. [lead] widgets (a grip, a rank) go before the flag; [proto] replaces the
/// badge text; [trailing] replaces the latency slot.
class NodeRow extends StatelessWidget {
  const NodeRow({
    super.key,
    required this.node,
    this.sourceName,
    this.lead = const [],
    this.proto,
    this.trailing,
    this.onTap,
    this.onPing,
    this.framed = false,
    this.on = true,
    this.dim = false,
    this.gone = false,
    this.now = false,
    this.topBorder = true,
  });

  final CatalogNode node;

  /// The source under the name (`.node-src`), only when the list mixes sources.
  final String? sourceName;
  final List<Widget> lead;
  final String? proto;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onPing;
  final bool framed;
  final bool on;
  final bool dim;
  final bool gone;

  /// The server the entry connects through now (name in the active colour).
  final bool now;
  final bool topBorder;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hp = framed ? 10.0 : 14.0;
    final vp = framed ? 8.0 : 10.0;
    final struck = dim || gone;
    final nameStyle = TextStyle(
      fontSize: 14,
      height: 1.3,
      color: now
          ? c.active
          : framed && !on
          ? c.t2
          : c.t1,
      decoration: struck ? TextDecoration.lineThrough : null,
      decorationColor: c.t3,
    );
    final name = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: node.flag,
            style: const TextStyle(fontSize: 16, height: 1),
          ),
          const WidgetSpan(child: SizedBox(width: 7)),
          TextSpan(text: node.name),
          if (sourceName != null)
            TextSpan(
              text: '  $sourceName',
              style: TextStyle(
                fontSize: 11,
                color: c.t3,
                decoration: TextDecoration.none,
              ),
            ),
        ],
      ),
      style: nameStyle,
    );
    final slot = trailing ?? LatencyText(node);
    final content = Row(
      children: [
        SizedBox(width: hp),
        ...lead,
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: vp),
            child: name,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          proto ?? nodeProtoLabel(node),
          style: monoText.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: c.t2,
          ),
        ),
        const SizedBox(width: 5),
        GestureDetector(
          behavior: onPing == null
              ? HitTestBehavior.deferToChild
              : HitTestBehavior.opaque,
          onTap: onPing,
          child: Padding(
            padding: EdgeInsets.fromLTRB(4, vp, hp, vp),
            child: slot,
          ),
        ),
      ],
    );
    final faded = Opacity(
      opacity: dim
          ? .45
          : gone
          ? .55
          : 1,
      child: content,
    );
    final BoxDecoration? decoration = framed
        ? BoxDecoration(
            color: on ? c.accent.tint(.07) : null,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: on ? c.accent.tint(.5) : Colors.transparent,
            ),
          )
        : topBorder
        ? BoxDecoration(
            border: Border(top: BorderSide(color: c.t1.tint(.035))),
          )
        : null;
    return Container(
      margin: framed
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
          : null,
      decoration: decoration,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: framed ? BorderRadius.circular(9) : null,
        clipBehavior: framed ? Clip.antiAlias : Clip.none,
        child: InkWell(
          onTap: onTap,
          splashFactory: NoSplash.splashFactory,
          highlightColor: c.t1.tint(.04),
          child: faded,
        ),
      ),
    );
  }
}
