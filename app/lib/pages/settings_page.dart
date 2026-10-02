import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../state/app_settings.dart';
import '../theme/app_colors.g.dart';
import '../widgets/app_view.dart';
import '../widgets/settings_row.dart';

/// Settings tab. Only Appearance (theme, text size) and Language are real so far;
/// the rest of the mockup's list is TODO (Auto mode, General, Connection, DNS, Rules, Data ...).
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// Language names are shown in their own language and are not translated.
  static const Map<String, String> _languages = {
    'en': 'English',
    'ru': 'Русский',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final settings = AppSettingsScope.of(context);
    return AppView(
      title: l10n.settings,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          SettingsSection(l10n.appearance),
          for (final id in AppThemeId.values)
            SettingsRow(
              label: id.label,
              leading: _Swatch(colors: id.colors),
              trailing: RadioMark(selected: id == settings.theme),
              onTap: () => settings.setTheme(id),
            ),
          SettingsRow(
            label: l10n.textSize,
            trailing: Text(
              '${(settings.textScale * 100).round()}%',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.t2,
              ),
            ),
          ),
          Slider(
            value: settings.textScale,
            min: AppSettings.textScaleMin,
            max: AppSettings.textScaleMax,
            divisions: AppSettings.textScaleSteps,
            onChanged: settings.setTextScale,
          ),
          SettingsSection(l10n.language),
          for (final loc in AppSettings.supported)
            SettingsRow(
              label: _languages[loc.languageCode] ?? loc.languageCode,
              trailing: RadioMark(selected: loc == settings.locale),
              onTap: () => settings.setLocale(Locale(loc.languageCode)),
            ),
        ],
      ),
    );
  }
}

/// Four chips of a theme's palette (bg, card, accent, active) - `.theme-swatch`.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final color in [
          colors.bg,
          colors.card,
          colors.accent,
          colors.active,
        ])
          DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              border: Border.all(color: colors.borderHi),
            ),
            child: const SizedBox(width: 10, height: 26),
          ),
      ],
    );
  }
}
