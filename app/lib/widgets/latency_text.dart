import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show CatalogNode, Chain;

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'form_parts.dart';

/// A measured latency as the mockup's `latMsHtml` shows it: `123 ms` coloured by speed
/// (< 150 good, < 400 mid, else muted), a warning sign for no answer, a ring while pinging,
/// a dash when never measured. The slot is at least 44 px wide, text right-aligned, so a column
/// of them lines up.
class LatencyView extends StatelessWidget {
  const LatencyView({
    super.key,
    this.ms,
    this.testing = false,
    this.minWidth = 44,
  });

  /// `-1` / any negative = no answer (timeout); null = never measured.
  final num? ms;
  final bool testing;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final Widget content;
    if (testing) {
      content = Tooltip(message: l10n.pinging, child: const PingSpinner());
    } else if (ms == null) {
      content = Text('—', style: _style(c.t3));
    } else if (ms! < 0) {
      content = Tooltip(
        message: l10n.noAnswerTimeout,
        child: Icon(Icons.warning_amber_rounded, size: 14, color: c.muted),
      );
    } else {
      final v = ms!;
      final color = v < 150
          ? c.active
          : v < 400
          ? c.warn
          : c.muted;
      content = Text('${v.round()} ms', style: _style(color));
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, minHeight: 14),
      child: Align(
        alignment: Alignment.centerRight,
        widthFactor: 1,
        child: content,
      ),
    );
  }

  static TextStyle _style(Color color) => monoText.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: color,
  );
}

/// The latency of one server, read from the catalog's ping book (rebuilds when the host
/// notifies, so every answer shows as it arrives).
class LatencyText extends StatelessWidget {
  const LatencyText(this.node, {super.key});

  final CatalogNode node;

  @override
  Widget build(BuildContext context) {
    final e = CoreHostScope.of(context).catalog.pings.entry(node);
    return LatencyView(ms: e?.ms, testing: e?.testing ?? false);
  }
}

/// The latency of a chain's exit as the chain gets it: through the entry in use (the pair
/// book, `Catalog.chainExitEntry`), not the server's own direct ping. Same look as [LatencyText].
class ChainExitLatency extends StatelessWidget {
  const ChainExitLatency(this.chain, this.node, {super.key});

  final Chain chain;
  final CatalogNode node;

  @override
  Widget build(BuildContext context) {
    final e = CoreHostScope.of(context).catalog.chainExitEntry(chain, node);
    return LatencyView(ms: e?.ms, testing: e?.testing ?? false);
  }
}
