import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/widgets.dart';

import '../theme/app_colors.g.dart';

/// UI settings of Settings -> Appearance / General -> Language.
///
/// State management is plain `ChangeNotifier` + `InheritedNotifier` (no package): the shell has
/// two small stores (this and [CoreHost]), and the real state lives in the core, so a state
/// library would only add a dependency before there is anything to manage.
class AppSettings extends ChangeNotifier {
  AppSettings({
    AppThemeId theme = AppThemeId.original,
    double textScale = 1.0,
    Locale? locale,
  }) : _theme = theme,
       _textScale = clampTextScale(textScale),
       _locale = locale ?? defaultLocale();

  /// Settings -> Appearance -> Text size: 90-120 %, step 5 (UI_SCALE_MIN / UI_SCALE_MAX in the mockup).
  static const double textScaleMin = 0.9;
  static const double textScaleMax = 1.2;
  static const int textScaleSteps = 6;

  /// The app is localized to these (ARB files); the system language when it is one of them, else English.
  static const List<Locale> supported = [Locale('en'), Locale('ru')];

  static Locale defaultLocale() {
    final code = PlatformDispatcher.instance.locale.languageCode;
    return supported.firstWhere(
      (l) => l.languageCode == code,
      orElse: () => const Locale('en'),
    );
  }

  static double clampTextScale(double v) =>
      ((v.clamp(textScaleMin, textScaleMax)) * 20).round() / 20;

  AppThemeId _theme;
  double _textScale;
  Locale _locale;

  AppThemeId get theme => _theme;
  double get textScale => _textScale;
  Locale get locale => _locale;

  void setTheme(AppThemeId v) {
    if (v == _theme) return;
    _theme = v;
    notifyListeners();
  }

  void setTextScale(double v) {
    final s = clampTextScale(v);
    if (s == _textScale) return;
    _textScale = s;
    notifyListeners();
  }

  void setLocale(Locale v) {
    if (v == _locale) return;
    _locale = v;
    notifyListeners();
  }

  // TODO(persistence): load / save with the rest of the app state (the core keeps the snapshot
  // in jormd today; the mockup stores theme / scale / lang with it).
}

class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  /// Listens: the caller rebuilds when a setting changes.
  static AppSettings of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    assert(scope != null, 'No AppSettingsScope above this context');
    return scope!.notifier!;
  }
}
