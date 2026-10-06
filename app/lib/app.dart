import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/core_host.dart';
import 'core/settings_model.dart';
import 'core/tile_sync.dart';
import 'platform/tile_channel.dart';
import 'l10n/l10n.dart';
import 'shell/home_shell.dart';
import 'state/app_settings.dart';
import 'theme/app_colors.g.dart';

/// Root widget: owns the app-wide [AppSettings], shares the [CoreHost] it is given (built in
/// main.dart by `openCoreHost`, a fake in tests), applies the theme, locale and text-scale policy.
class JormungandApp extends StatefulWidget {
  const JormungandApp({super.key, required this.coreHost, this.tilePort});

  final CoreHost coreHost;

  /// The Quick Settings tile's line to the platform; null = the real one on Android, none elsewhere.
  final TilePort? tilePort;

  @override
  State<JormungandApp> createState() => _JormungandAppState();
}

class _JormungandAppState extends State<JormungandApp> {
  final AppSettings _settings = AppSettings();
  late final AppLifecycleListener _lifecycle;
  TileSync? _tile;

  CoreHost get _core => widget.coreHost;

  // The look (theme, text size, language) is part of the core's state (genCfg), so a backup
  // carries it: the host's copy is applied when it loads or is restored, a change here is
  // written back to it.
  bool _applying = false;
  String? _look; // the look of genCfg the settings match now
  bool _langChosen = false; // the language is written only once the user picked one
  Locale? _lastLocale;

  String _lookOf(GenCfg g) => '${g.theme}|${g.uiScale}|${g.lang}';

  void _loadLook() {
    if (!_core.ready) return;
    final g = _core.gen;
    final sig = _lookOf(g);
    if (sig == _look) return;
    _look = sig;
    _applying = true;
    final theme = g.theme, scale = g.uiScale, lang = g.lang;
    if (theme != null) _settings.setTheme(AppThemeId.parse(theme));
    if (scale != null) _settings.setTextScale(scale);
    if (lang != null &&
        AppSettings.supported.any((l) => l.languageCode == lang)) {
      _settings.setLocale(Locale(lang));
    }
    _lastLocale = _settings.locale;
    _applying = false;
  }

  void _saveLook() {
    if (_settings.locale != _lastLocale) {
      _lastLocale = _settings.locale;
      if (!_applying) _langChosen = true;
    }
    if (_applying || !_core.ready) return;
    final g = _core.gen;
    g.theme = _settings.theme.name;
    g.uiScale = _settings.textScale;
    if (_langChosen) g.lang = _settings.locale.languageCode;
    _look = _lookOf(g);
    _core.changed();
  }

  @override
  void initState() {
    super.initState();
    _lastLocale = _settings.locale;
    _core.addListener(_loadLook);
    _settings.addListener(_saveLook);
    unawaited(
      _core.init().then((_) {
        if (!mounted) return null;
        _loadLook();
        return _core.runLaunchActions();
      }),
    );
    // Android: the Quick Settings tile shows the connection and toggles it
    final tilePort = widget.tilePort ?? (_core.isAndroid ? const TileChannel() : null);
    if (tilePort != null) _tile = TileSync(_core, tilePort)..start();
    // Desktop: the window is closing - stop sing-box, put the system proxy back (or keep it by
    // the kill switch) and save. Android's process just ends; the state is saved as it changes.
    // Android's `detached` is NOT a close: the activity went (swiped from Recents, Back) while the
    // engine, this core and the tunnel stay (docs/platforms.md, "Работа в фоне"), so no shutdown.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _core.shutdown();
        return AppExitResponse.exit;
      },
      onDetach: _core.isAndroid ? null : _core.shutdown,
    );
  }

  @override
  void dispose() {
    _core.removeListener(_loadLook);
    _tile?.dispose();
    _lifecycle.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppSettingsScope(
      settings: _settings,
      child: CoreHostScope(
        host: _core,
        child: ListenableBuilder(
          listenable: _settings,
          builder: (context, _) => MaterialApp(
            onGenerateTitle: (_) => 'Jormungand',
            debugShowCheckedModeBanner: false,
            theme: appThemes[_settings.theme],
            locale: _settings.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            // Headers and the nav bar keep the system size; pages scale their content with the
            // user's 90-120 % (ContentScale in widgets/app_view.dart).
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
              child: child!,
            ),
            home: const HomeShell(),
          ),
        ),
      ),
    );
  }
}
