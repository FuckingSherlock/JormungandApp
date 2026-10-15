import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'settings_parts.dart';

/// Settings -> Auto mode (mockup 55-automode.js `renderAutoMode`); the Home card opens the same
/// sheet. Every change goes to `catalog.autoCfg` and through `host.changed()`, which saves it
/// and tells the running core.
Future<void> showAutoModeSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const AutoModeSheet());

class AutoModeSheet extends StatelessWidget {
  const AutoModeSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SheetFrame(
      title: l10n.autoMode,
      titleBadge: const HelpButton(HelpTopic.autoMode),
      child: const AutoModeBody(),
    );
  }
}

/// The one-liner of the Home card: `Check every 60 s`.
String autoCardSub(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  return l10n.checkEvery2(fmtEvery(l10n, host.catalog.autoCfg.checkEvery));
}

String standbyText(AppLocalizations l10n, num n) =>
    n > 0 ? l10n.next(n) : l10n.off2;

class AutoModeBody extends StatelessWidget {
  const AutoModeBody({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final a = host.catalog.autoCfg;
    void save() => host.changed();

    void toast(String text) => showToast(context, text);
    String unitOf(String key) => key == 'retryPause' ? l10n.s3 : l10n.min2;

    Future<void> interval(String key, num current) async {
      final spec = intervals[key]!;
      final unit = intervalUnitFor(spec, current);
      final (title, hint) = switch (key) {
        'checkEvery' => (l10n.checkTheConnectionEvery, l10n.from10STo60Min),
        'warmEvery' => (
          l10n.pingTheSparesEvery,
          l10n.from10STo60Min2,
        ),
        _ => (
          l10n.updateAllSubscriptionsEvery,
          l10n.n0OffOnlyWhenYouTap,
        ),
      };
      // the dialog stays open on a refused value, like the mockup's toast over it
      final r = await showNumberUnitDialog(
        context,
        title: title,
        hint: hint,
        initial: fmtNum(current / unit),
        units: spec.units,
        unit: unit,
        validate: (text, u) => parseInterval(spec, text, u) != null ? null : hint,
      );
      if (r == null) return;
      final secs = parseInterval(spec, r.text, r.unit);
      if (secs == null) return;
      switch (key) {
        case 'checkEvery':
          a.checkEvery = secs;
        case 'warmEvery':
          a.warmEvery = secs;
        default:
          a.subsEvery = secs;
      }
      save();
    }

    void setNum(String key, String raw) {
      final v = parseAutoNum(key, raw);
      final spec = autoNums[key]!;
      if (v == null) {
        toast(l10n.enter(spec.min, spec.max, unitOf(key)));
        return;
      }
      switch (key) {
        case 'retryPause':
          a.retryPause = v;
        case 'flapMax':
          a.flapMax = v;
        default:
          a.flapReset = v;
      }
      save();
    }

    Widget numField(String key, num value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CommitField(
          value: fmtNum(value),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onCommit: (t) => setNum(key, t),
        ),
        UnitText(unitOf(key)),
      ],
    );

    final fa = a.failAfter.toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetGroup(
          card: true,
          children: [
            SetRow(
              label: l10n.switchToAFasterServer,
              hint: l10n.onlyIfItIsFasterThan,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CommitField(
                    value: fmtNum(a.threshold),
                    onCommit: (t) {
                      final v = parseThreshold(t);
                      if (v == null) {
                        toast(l10n.enter0Ms2(autoThresholdMax));
                        return;
                      }
                      a.threshold = v;
                      save();
                    },
                  ),
                  UnitText(l10n.ms2),
                ],
              ),
            ),
            SetRow(
              label: l10n.checkTheConnectionEvery,
              hint: l10n.pingsTheCurrentServerAndThe,
              trailing: SetValueButton(
                text: fmtEvery(l10n, a.checkEvery),
                onTap: () => interval('checkEvery', a.checkEvery),
              ),
            ),
            _StandbyRow(
              value: a.standby.toInt(),
              onChanged: (v) {
                a.standby = v;
                save();
              },
            ),
            if (a.standby > 0)
              SetRow(
                label: l10n.pingTheSparesEvery,
                hint: l10n.notMoreOftenThanTheConnection,
                trailing: SetValueButton(
                  text: fmtEvery(l10n, a.warmEvery),
                  onTap: () => interval('warmEvery', a.warmEvery),
                ),
              ),
            SetRow(
              label: l10n.leaveAServerAfter,
              hint: l10n.timeoutsInARowBeforeAuto,
              trailing: StepperControl(
                value: fa,
                min: autoFailAfterMin,
                max: autoFailAfterMax,
                onChanged: (v) {
                  a.failAfter = v;
                  save();
                },
              ),
            ),
            SetRow(
              label: l10n.retryPause,
              hint: l10n.afterAMissedCheckBeforeThe,
              trailing: numField('retryPause', a.retryPause),
            ),
            SetRow(
              label: l10n.speedTestOnFailures,
              hint: l10n.whenRequestsFailAlsoMeasureThe,
              trailing: MiniToggle(
                on: a.speedOnFail,
                onChanged: (v) {
                  a.speedOnFail = v;
                  save();
                },
              ),
            ),
            SetRow(
              label: l10n.retryAFailedSiteThroughOther,
              hint: l10n.tellsABlockedSiteFromA,
              trailing: SetSelect<String>(
                value: const ['off', '3', 'all'].contains(a.siteRetry) ? a.siteRetry : '3',
                options: [
                  ('off', l10n.off),
                  ('3', l10n.upTo3),
                  ('all', l10n.all),
                ],
                onChanged: (v) {
                  a.siteRetry = v;
                  save();
                },
              ),
            ),
            SetRow(
              label: l10n.checkWithAnExternalChecker,
              hint: l10n.aSiteThatFailsOnEvery,
              trailing: MiniToggle(
                on: a.siteCheck,
                onChanged: (v) {
                  a.siteCheck = v;
                  save();
                },
              ),
            ),
            SetRow(
              label: l10n.pauseChecksWithTheScreenOff,
              hint: l10n.savesBatteryChecksAgainOnWake,
              trailing: MiniToggle(
                on: a.pauseScreenOff,
                onChanged: (v) {
                  a.pauseScreenOff = v;
                  save();
                },
              ),
            ),
          ],
        ),
        AmLabel(l10n.goingBackUp, help: HelpTopic.autoReturn),
        SetGroup(
          card: true,
          children: [
            SetRow(
              label: l10n.returnToAHigherEntry,
              hint: l10n.whenAnEntryAboveTheCurrent,
              trailing: SetSelect<String>(
                value: const ['always', 'faster', 'never'].contains(a.returnTo) ? a.returnTo : 'always',
                options: [
                  ('always', l10n.always),
                  ('faster', l10n.ifFaster),
                  ('never', l10n.never),
                ],
                onChanged: (v) {
                  a.returnTo = v;
                  save();
                },
              ),
            ),
            SetRow(
              label: l10n.flapProtection,
              hint: l10n.anEntryThatKeepsDroppingWaits,
              trailing: MiniToggle(
                on: a.flapGuard,
                onChanged: (v) {
                  a.flapGuard = v;
                  save();
                },
              ),
            ),
            if (a.flapGuard) ...[
              SetRow(
                label: l10n.longestWait,
                hint: l10n.n124MinutesUpTo,
                trailing: numField('flapMax', a.flapMax),
              ),
              SetRow(
                label: l10n.forgetDropsAfter,
                hint: l10n.thisLongOfStableWorkOn,
                trailing: numField('flapReset', a.flapReset),
              ),
            ],
          ],
        ),
        AmLabel(l10n.subscriptions, help: HelpTopic.subsUpdate),
        SetGroup(
          card: true,
          children: [
            SetRow(
              label: l10n.updateAllSubscriptionsEvery,
              trailing: SetValueButton(
                text: a.subsEvery > 0 ? fmtEvery(l10n, a.subsEvery) : l10n.off2,
                onTap: () => interval('subsEvery', a.subsEvery),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The spares slider: the number follows the thumb, the setting is written on release.
class _StandbyRow extends StatefulWidget {
  const _StandbyRow({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_StandbyRow> createState() => _StandbyRowState();
}

class _StandbyRowState extends State<_StandbyRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shown = (_drag ?? widget.value.toDouble()).round();
    return SetRow(
      labelWidget: LabelWithValue(l10n.spareServers, standbyText(l10n, shown)),
      hint: l10n.nextEntriesByPriorityPingedAhead,
      below: ScaleSlider(
        value: shown.toDouble(),
        min: 0,
        max: autoStandbyMax.toDouble(),
        divisions: autoStandbyMax,
        startLabel: '0',
        endLabel: '$autoStandbyMax',
        startSize: 13,
        endSize: 13,
        onChanged: (v) => setState(() => _drag = v),
        onChangeEnd: (v) {
          setState(() => _drag = null);
          widget.onChanged(v.round());
        },
      ),
    );
  }
}
