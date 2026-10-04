import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme/app_colors.g.dart';

/// One tab page: fixed header (title, optional summary line and actions) over a content area.
///
/// Text size (Settings -> Appearance) zooms the content only: the header and the bottom nav keep
/// their size (the root MediaQuery has no text scaling, [ContentScale] sets the user's scale
/// below the header) - the mockup's `.view > .scroll { zoom: var(--ui-zoom) }`.
class AppView extends StatelessWidget {
  const AppView({
    super.key,
    required this.title,
    required this.child,
    this.summary,
    this.actions = const [],
    this.titleBadge,
  });

  /// The round ? next to the title (`.help-btn`).
  final Widget? titleBadge;
  final String title;
  final String? summary;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -.3,
                                color: c.t1,
                              ),
                            ),
                          ),
                          ?titleBadge,
                        ],
                      ),
                      if (summary != null)
                        Text(
                          summary!,
                          style: TextStyle(fontSize: 12, color: c.t2),
                        ),
                    ],
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
        Expanded(child: ContentScale(child: child)),
      ],
    );
  }
}

/// Applies the user's text scale (90-120 %) to everything below.
class ContentScale extends StatelessWidget {
  const ContentScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = AppSettingsScope.of(context).textScale;
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child,
    );
  }
}

/// Body of a page that is not built yet.
class PlaceholderBody extends StatelessWidget {
  const PlaceholderBody({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: c.t3),
          const SizedBox(height: 10),
          Text(label, style: TextStyle(fontSize: 14, color: c.t3)),
        ],
      ),
    );
  }
}
