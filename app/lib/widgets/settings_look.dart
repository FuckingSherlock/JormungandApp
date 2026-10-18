import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../core/settings_model.dart';
import '../core/system_notifier.dart';
import '../l10n/l10n.dart';
import '../platform/notify_channel.dart';
import '../platform/platform_caps.dart';
import '../state/app_settings.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'settings_parts.dart';
import 'settings_row.dart';

/// Settings -> Appearance, General and Notifications (mockup 90-themes.js, 57-general.js,
/// 58-notif.js). Theme, text size and language live in [AppSettings]; the app copies them into
/// the state (`genCfg`) so a backup carries them (app.dart).

/// The language names are shown in their own language and never translated.
const Map<String, String> languageNames = {'en': 'English', 'ru': 'Русский'};

// ───────────────────────────── Appearance ─────────────────────────────

Future<void> showAppearanceSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const AppearanceSheet());

String themeSub(AppLocalizations l10n, AppThemeId id) => switch (id) {
  AppThemeId.original => l10n.navyBlueAccent,
  AppThemeId.karing => l10n.neutralGreyBlueAccent,
  AppThemeId.github => l10n.githubDarkPalette,
};

class AppearanceSheet extends StatelessWidget {
  const AppearanceSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = AppSettingsScope.of(context);
    return SheetFrame(
      title: l10n.appearance,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SetGroup(
            card: true,
            children: [
              _TextSizeRow(
                value: settings.textScale,
                onApply: settings.setTextScale,
              ),
            ],
          ),
          SetGroup(
            card: true,
            children: [
              for (final id in AppThemeId.values)
                SetRow(
                  labelWidget: Row(
                    children: [
                      _Swatch(colors: id.colors),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              id.label,
                              style: TextStyle(
                                fontSize: 15,
                                color: context.colors.t1,
                              ),
                            ),
                            HintText(themeSub(l10n, id)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  trailing: RadioMark(selected: id == settings.theme),
                  onTap: () => settings.setTheme(id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The text size slider: the number follows the thumb, the size applies on release so the slider
/// stays under the finger (mockup `previewScale` / `applyScale`).
class _TextSizeRow extends StatefulWidget {
  const _TextSizeRow({required this.value, required this.onApply});

  final double value;
  final ValueChanged<double> onApply;

  @override
  State<_TextSizeRow> createState() => _TextSizeRowState();
}

class _TextSizeRowState extends State<_TextSizeRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final v = AppSettings.clampTextScale(_drag ?? widget.value);
    return SetRow(
      labelWidget: LabelWithValue(l10n.textSize, '${(v * 100).round()}%'),
      hint: l10n.listsAndMenusTitlesKeepTheir,
      below: ScaleSlider(
        value: v,
        min: AppSettings.textScaleMin,
        max: AppSettings.textScaleMax,
        divisions: AppSettings.textScaleSteps,
        startLabel: 'A',
        endLabel: 'A',
        onChanged: (x) => setState(() => _drag = x),
        onChangeEnd: (x) {
          setState(() => _drag = null);
          widget.onApply(x);
        },
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final color in [
            colors.bg,
            colors.card,
            colors.accent,
            colors.active,
          ])
            DecoratedBox(
              decoration: BoxDecoration(color: color),
              child: const SizedBox(width: 10, height: 26),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────────── General ─────────────────────────────

Future<void> showGeneralSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const GeneralSheet());

/// The sub line of the Settings row: `English · connects on launch`.
String generalSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final lang = AppSettingsScope.of(context).locale.languageCode;
  return (languageNames[lang] ?? lang) +
      (host.gen.connectOnLaunch ? ' ${l10n.connectsOnLaunch}' : '');
}

class GeneralSheet extends StatelessWidget {
  const GeneralSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final settings = AppSettingsScope.of(context);
    final g = host.gen;
    final standby = host.catalog.autoCfg.standby.toInt();
    Widget toggleRow(
      String label,
      String hint,
      bool value,
      void Function(bool) set,
    ) => SetRow(
      label: label,
      hint: hint,
      trailing: MiniToggle(
        on: value,
        onChanged: (v) {
          set(v);
          host.changed();
        },
      ),
    );
    return SheetFrame(
      title: l10n.general,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SetGroup(
            card: true,
            children: [
              SetRow(
                label: l10n.language,
                trailing: SetValueButton(
                  text: languageNames[settings.locale.languageCode] ??
                      settings.locale.languageCode,
                  onTap: () => _pickLanguage(context),
                ),
              ),
            ],
          ),
          SetCaption(l10n.startup),
          SetGroup(
            card: true,
            children: [
              toggleRow(
                l10n.launchAtStartup,
                l10n.startWithTheSystemAndroidAfter,
                g.launchAtStartup,
                (v) => g.launchAtStartup = v,
              ),
              toggleRow(
                l10n.startMinimized,
                l10n.desktopOpenInTheTrayNot,
                g.startMinimized,
                (v) => g.startMinimized = v,
              ),
              toggleRow(
                l10n.connectOnLaunch,
                l10n.turnTheVpnOnAsSoon,
                g.connectOnLaunch,
                (v) => g.connectOnLaunch = v,
              ),
              toggleRow(
                l10n.checkServersOnLaunch,
                l10n.pingsTheTopAutoEntryAnd(standby.toString()),
                g.pingOnLaunch,
                (v) => g.pingOnLaunch = v,
              ),
            ],
          ),
          SetCaption(l10n.other),
          SetGroup(
            card: true,
            children: [
              toggleRow(
                l10n.linksInTheClipboard,
                l10n.onOpenOfferToAddA,
                g.clipboard,
                (v) => g.clipboard = v,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickLanguage(BuildContext context) {
    final l10n = context.l10n;
    final settings = AppSettingsScope.of(context);
    return showMenuSheet<void>(context, l10n.language, (sheet) => [
      for (final loc in AppSettings.supported)
        PickRow(
          label: languageNames[loc.languageCode] ?? loc.languageCode,
          selected: loc == settings.locale,
          onTap: () => closeThen(sheet, () => settings.setLocale(loc)),
        ),
    ]);
  }
}

// ───────────────────────────── Notifications ─────────────────────────────

Future<void> showNotifSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const NotifSheet());

/// The sub line of the Settings row: `All on`, `Off`, `5 of 9 on`.
String notifSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final n = host.notif;
  if (!n.enabled) return l10n.off;
  final on = n.onCount, all = NotifCfg.allKeys.length;
  if (on == all) return l10n.allOn;
  if (on == 0) return l10n.allOff;
  return l10n.ofOn(on, all);
}

class NotifSheet extends StatelessWidget {
  const NotifSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final n = host.notif;
    // Android: a hidden VPN notification is not a stopped VPN
    final hideNote = NotifyIo.current.available;
    Widget row(String key, String label, String hint) => SetRow(
      label: label,
      hint: hideNote && key == 'status' ? null : hint,
      hintWidget: hideNote && key == 'status'
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HintText(hint),
                HintText(l10n.switchedOffTheNotificationIsHidden),
              ],
            )
          : null,
      trailing: MiniToggle(
        on: n.flag(key),
        onChanged: (v) {
          n.setFlag(key, v);
          host.changed();
          SystemNotifier.askForSwitch(NotifyIo.current, v);
        },
      ),
    );
    final groups = <(String, List<(String, String, String)>)>[
      (l10n.status, [
        (
          'status',
          l10n.statusNotification,
          l10n.androidShowsTheEntryServerAnd,
        ),
      ]),
      (l10n.connection, [
        (
          'autoSwitch',
          l10n.whenAutoSwitches,
          l10n.autoMovedToAnotherEntryOr,
        ),
        (
          'unstable',
          l10n.unstableEntry,
          l10n.anEntryKeepsDroppingAndWaits,
        ),
        (
          'connLost',
          l10n.connectionLost,
          l10n.noNetworkOrNoServerAnswers,
        ),
        (
          'blocked',
          l10n.siteDoesNotOpen,
          l10n.itDoesNotOpenThroughThe,
        ),
        (
          'dnsFailed',
          l10n.dnsServerDoesNotAnswer,
          l10n.aDnsServerStopsAnsweringOn,
        ),
        ('vpnRevoked', l10n.vpnTurnedOffByTheSystem, l10n.anotherVpnAppTookOverOr),
      ]),
      (l10n.subscriptionsAndRules, [
        (
          'subUpdated',
          l10n.subscriptionUpdated,
          l10n.aBackgroundUpdateFinishedNameAnd,
        ),
        (
          'subFailed',
          l10n.subscriptionProblems,
          l10n.aBackgroundUpdateFailedTheProvider,
        ),
        (
          'ruleSets',
          l10n.ruleSets,
          l10n.aRuleSetCouldNotBe,
        ),
      ]),
      (l10n.appUpdates, [
        (
          'updateAvailable',
          l10n.newVersion,
          l10n.aNewVersionOfTheApp,
        ),
      ]),
      (l10n.app, [
        (
          'appData',
          l10n.appData,
          l10n.savedDataWasDamagedAndRestored,
        ),
      ]),
    ];
    return SheetFrame(
      title: l10n.notifications,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotifPermissionHint(),
          SetGroup(
            card: true,
            children: [
              SetRow(
                label: l10n.notifications,
                hint: l10n.offTheAppStaysSilentIn,
                trailing: MiniToggle(
                  on: n.enabled,
                  onChanged: (v) {
                    n.setFlag('enabled', v);
                    host.changed();
                    SystemNotifier.askForSwitch(NotifyIo.current, v);
                  },
                ),
              ),
            ],
          ),
          DimWhen(
            dim: !n.enabled,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (caption, rows) in groups) ...[
                  SetCaption(caption),
                  SetGroup(
                    card: true,
                    children: [
                      for (final (k, l, h) in rows)
                        if (k != 'vpnRevoked' || host.caps.vpnRevoked) row(k, l, h),
                      // a screen that can be off is a phone's: not on the desktop
                      if (caption == l10n.connection && NotifyIo.current.available)
                        row('bgErrors', l10n.errorsWhileScreenIsOff, l10n.aSiteThatFailsWhileThe),
                    ],
                  ),
                ],
              ],
            ),
          ),
          SetCaption(l10n.popUpsOnPc),
          SetGroup(
            card: true,
            children: [
              SetRow(
                label: l10n.whereTheyShow,
                hint: l10n.ownPopUpsShowEvenWhen,
                below: ChipRow(
                  padding: EdgeInsets.zero,
                  children: [
                    AppChip(
                      label: l10n.ownPopUps,
                      active: n.desktopStyle == 'own',
                      onTap: () {
                        n.desktopStyle = 'own';
                        host.changed();
                      },
                    ),
                    AppChip(
                      label: l10n.systemNotifications,
                      active: n.desktopStyle == 'system',
                      onTap: () {
                        n.desktopStyle = 'system';
                        host.changed();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          SetCaption(
            l10n.onThePhoneTheseComeAs,
            plain: true,
          ),
        ],
      ),
    );
  }
}

/// Android blocks notifications for the app (the permission was refused, or the switch in the
/// system settings is off): a warning row with a button to the app's system notification page.
/// Nothing where there are no system notifications or they are allowed. Re-reads the state when
/// the user comes back from the system settings.
class NotifPermissionHint extends StatefulWidget {
  const NotifPermissionHint({super.key});

  @override
  State<NotifPermissionHint> createState() => _NotifPermissionHintState();
}

class _NotifPermissionHintState extends State<NotifPermissionHint>
    with WidgetsBindingObserver {
  final NotifyIo _io = NotifyIo.current;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_io.available) _io.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _io.available) _io.refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!_io.available) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ValueListenableBuilder<NotifyPermission>(
      valueListenable: _io.permission,
      builder: (context, state, _) {
        if (state != NotifyPermission.denied) return const SizedBox.shrink();
        return SetGroup(
          card: true,
          children: [
            SetRow(
              label: l10n.notificationsAreBlocked,
              hintWidget: HintText(l10n.androidDoesNotLetTheApp, warn: true),
              below: Align(
                alignment: Alignment.centerLeft,
                child: SecondaryButton(
                  label: l10n.openSettings,
                  onPressed: _io.openSettings,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
