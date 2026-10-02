import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';

/// Nodes -> Simple: one card per source (subscription / server group) with its servers and chains.
/// Stub: name only.
// TODO(ui): header (name, update state, error strip + Retry), NodeRow list, edit-mode handles,
// swipe actions - see design/src/js/31-catalog.js and docs/connect-model.md.
class SourceCard extends StatelessWidget {
  const SourceCard({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(c.radius),
        border: Border.all(color: c.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          name,
          style: TextStyle(fontWeight: FontWeight.w600, color: c.t1),
        ),
      ),
    );
  }
}
