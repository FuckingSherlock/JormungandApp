import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/core_host.dart';
import 'l10n/l10n.dart';
import 'shell/home_shell.dart';
import 'state/app_settings.dart';
import 'theme/app_colors.g.dart';

/// Root widget: owns the app-wide [AppSettings], shares the [CoreHost] it is given (built in
/// main.dart by `openCoreHost`, a fake in tests), applies the theme, locale and text-scale policy.
class JormungandApp extends StatefulWidget {
  const JormungandApp({super.key, required this.coreHost});

  final CoreHost coreHost;

  @override
  State<JormungandApp> createState() => _JormungandAppState();
}

class _JormungandAppState extends State<JormungandApp> {
  final AppSettings _settings = AppSettings();
  late final AppLifecycleListener _lifecycle;

  CoreHost get _core => widget.coreHost;

  @override
  void initState() {
    super.initState();
    _core.init();
    // Desktop: the window is closing - stop sing-box, put the system proxy back (or keep it by
    // the kill switch) and save. Android's process just ends; the state is saved as it changes.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _core.shutdown();
        return AppExitResponse.exit;
      },
      onDetach: _core.shutdown,
    );
  }

  @override
  void dispose() {
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
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.noScaling),
              child: child!,
            ),
            home: const HomeShell(),
          ),
        ),
      ),
    );
  }
}
