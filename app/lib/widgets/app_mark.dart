import 'package:flutter/material.dart';
import 'package:jormungand_core/jormungand_core.dart' show AppRulesOps, Catalog;

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'rules_parts.dart' show AppIcon;

/// The name of the app behind a package id in events and connections: the installed-apps name
/// (`Catalog.appLabel`, the saved name of a removed app), «Android System» for the system's own
/// package (`android`, the uid 1000 of sing-box's process info), the package id itself when unknown.
String appDisplayName(AppLocalizations l10n, Catalog catalog, String pkg) =>
    pkg == 'android' ? l10n.androidSystem : catalog.appLabel(pkg);

/// An app named where a request came from (display only): its icon (the one cached by the host,
/// a letter tile when it has none) and its name. With [onTap] the name leads to the app's route
/// (Rules → Apps).
class AppMark extends StatelessWidget {
  const AppMark({super.key, required this.pkg, required this.name, this.onTap, this.size = 18, this.style});

  final String pkg;
  final String name;
  final VoidCallback? onTap;
  final double size;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(pkg: pkg, name: name, size: size),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (style ?? const TextStyle(fontSize: 12.5)).copyWith(color: onTap != null ? c.accent : null),
          ),
        ),
      ],
    );
    if (onTap == null) return row;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row);
  }
}
