import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';

/// Small caps section heading of a settings list.
class SettingsSection extends StatelessWidget {
  const SettingsSection(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: .8,
          color: context.colors.t3,
        ),
      ),
    );
  }
}

/// A card row of Settings (`.settings-row`): optional leading, label (+ sub), trailing; tappable.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.sub,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String label;
  final String? sub;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(c.radius),
          side: BorderSide(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: c.t1,
                        ),
                      ),
                      if (sub != null)
                        Text(sub!, style: TextStyle(fontSize: 12, color: c.t2)),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The selected / not selected mark of a choice row (`.profile-radio`).
class RadioMark extends StatelessWidget {
  const RadioMark({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? c.accent : c.borderHi, width: 2),
      ),
      child: SizedBox(
        width: 20,
        height: 20,
        child: selected
            ? Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.accent,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox(width: 10, height: 10),
                ),
              )
            : null,
      ),
    );
  }
}
