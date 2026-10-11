import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_view.dart';
import 'app_sheet.dart';
import 'form_parts.dart';

/// The small controls the Settings sheets are made of (mockup css/55-automode.css and
/// css/95-settings.css): `.set-value`, `.set-input.am-num`, `.set-select`, `.stepper`,
/// `.am-label`, `.set-caption`, `.help-btn`, and the menu / dialog helpers they open.

/// `.set-value`: the current value in accent colour with a chevron; opens a picker.
class SetValueButton extends StatelessWidget {
  const SetValueButton({
    super.key,
    required this.text,
    required this.onTap,
    this.mono = false,
  });

  final String text;
  final VoidCallback? onTap;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (mono ? monoText : const TextStyle()).copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: c.accent,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 14, color: c.t3),
          ],
        ),
      ),
    );
  }
}

/// `.set-input.am-num`: a small framed field that commits on Enter or when it loses focus; a
/// value the owner refuses puts the old one back (it shows [value] again after every commit).
class CommitField extends StatefulWidget {
  const CommitField({
    super.key,
    required this.value,
    required this.onCommit,
    this.width = 56,
    this.keyboardType = TextInputType.number,
    this.left = false,
    this.mono = true,
    this.hint,
    this.trailing,
  });

  final String value;
  final ValueChanged<String> onCommit;
  final double? width;
  final TextInputType keyboardType;
  final bool left;
  final bool mono;
  final String? hint;

  /// Inside the frame, at the right end (the new-password button).
  final Widget? trailing;

  @override
  State<CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<CommitField> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.value,
  );
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);
  String _focusedWith = '';

  void _onFocus() {
    if (_focus.hasFocus) {
      _focusedWith = _ctl.text;
    } else {
      _commit(_ctl.text);
    }
  }

  void _commit(String text) {
    if (text != _focusedWith || text != widget.value) widget.onCommit(text);
    _focusedWith = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _ctl.text = widget.value;
    });
  }

  @override
  void didUpdateWidget(CommitField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final field = TextField(
      controller: _ctl,
      focusNode: _focus,
      keyboardType: widget.keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      textAlign: widget.left ? TextAlign.left : TextAlign.center,
      cursorColor: c.accent,
      onSubmitted: (v) {
        _commit(v);
        _focus.unfocus();
      },
      style: (widget.mono ? monoText : const TextStyle()).copyWith(
        fontSize: widget.mono ? 14 : 13,
        color: c.t1,
      ),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        hintText: widget.hint,
        hintStyle: TextStyle(color: c.t3, fontSize: 13),
      ),
    );
    return AnimatedBuilder(
      animation: _focus,
      builder: (context, _) => Container(
        width: widget.width,
        padding: EdgeInsets.only(left: 8, right: widget.trailing == null ? 8 : 2),
        decoration: BoxDecoration(
          color: c.t1.tint(.035),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _focus.hasFocus ? c.accent : c.border),
        ),
        child: widget.trailing == null
            ? field
            : Row(
                children: [
                  Expanded(child: field),
                  widget.trailing!,
                ],
              ),
      ),
    );
  }
}

/// `.am-unit`: the unit after a number field.
class UnitText extends StatelessWidget {
  const UnitText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Text(text, style: TextStyle(fontSize: 15, color: context.colors.t2)),
  );
}

/// `.set-select`: a framed drop-down.
class SetSelect<T> extends StatelessWidget {
  const SetSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.maxWidth,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.cardHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: maxWidth != null,
          dropdownColor: c.cardHi,
          borderRadius: BorderRadius.circular(8),
          icon: Icon(Icons.expand_more, size: 18, color: c.t3),
          style: TextStyle(fontSize: 15, color: c.t1),
          items: [
            for (final (v, label) in options)
              DropdownMenuItem<T>(
                value: v,
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null && v != value) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// `.stepper`: a whole number with a button each side.
class StepperControl extends StatelessWidget {
  const StepperControl({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget button(String glyph, bool enabled, int to) => InkWell(
      onTap: enabled ? () => onChanged(to) : null,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Opacity(
            opacity: enabled ? 1 : .5,
            child: Text(
              glyph,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: enabled ? c.accent : c.t3,
              ),
            ),
          ),
        ),
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button('‹', value > min, value - 1),
          SizedBox(
            width: 26,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: monoText.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: c.t1,
              ),
            ),
          ),
          button('›', value < max, value + 1),
        ],
      ),
    );
  }
}

/// `.am-label`: a small label over a group, with a help button and / or a link at the end.
class AmLabel extends StatelessWidget {
  const AmLabel(this.text, {super.key, this.help, this.action});

  final String text;
  final HelpTopic? help;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
    child: Row(
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                text,
                style: TextStyle(fontSize: 12, color: context.colors.t3),
              ),
              if (help != null) HelpButton(help!),
            ],
          ),
        ),
        ?action,
      ],
    ),
  );
}

/// `.am-link`: a small accent link at the end of an [AmLabel].
class AmLink extends StatelessWidget {
  const AmLink(this.text, {super.key, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    splashFactory: NoSplash.splashFactory,
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: context.colors.accent,
      ),
    ),
  );
}

/// `.set-caption`: small caps over a group.
class SetCaption extends StatelessWidget {
  const SetCaption(this.text, {super.key, this.plain = false});

  final String text;

  /// The closing note: sentence case, no spacing of letters.
  final bool plain;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
    child: Text(
      plain ? text : text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: plain ? 0 : .6,
        height: plain ? 1.4 : null,
        color: context.colors.t3,
      ),
    ),
  );
}

/// The label of a row with a value after it (`Text size  100%`, `Spare servers  next 2`).
class LabelWithValue extends StatelessWidget {
  const LabelWithValue(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label),
          const TextSpan(text: '  '),
          TextSpan(
            text: value,
            style: monoText.copyWith(fontSize: 13, color: c.accent),
          ),
        ],
      ),
      style: TextStyle(fontSize: 15, color: c.t1),
    );
  }
}

/// `.scale-row`: a slider with a small and a big end label.
class ScaleSlider extends StatelessWidget {
  const ScaleSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    required this.startLabel,
    required this.endLabel,
    this.startSize = 12,
    this.endSize = 19,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String startLabel;
  final String endLabel;
  final double startSize;
  final double endSize;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget end(String t, double size) => SizedBox(
      width: 18,
      child: Text(
        t,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w600,
          height: 1,
          color: c.t2,
        ),
      ),
    );
    return Row(
      children: [
        end(startLabel, startSize),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: c.accent,
              thumbColor: c.accent,
              inactiveTrackColor: c.t2.tint(.2),
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        end(endLabel, endSize),
      ],
    );
  }
}

/// A group that is dimmed and ignores taps (`opacity:.4;pointer-events:none`).
class DimWhen extends StatelessWidget {
  const DimWhen({super.key, required this.dim, required this.child});

  final bool dim;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: dim,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: dim ? .4 : 1,
      child: child,
    ),
  );
}

// ───────────────────────────── help ─────────────────────────────

/// The tips of the Settings screens that carry a round ? (mockup 58-help.js).
enum HelpTopic { autoMode, autoReturn, subsUpdate, dns, dnsAuto, proxyAuth }

/// `.help-btn`: the round ? next to a title.
class HelpButton extends StatelessWidget {
  const HelpButton(this.topic, {super.key});

  final HelpTopic topic;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showHelp(context, topic),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 4, 4, 4),
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c.borderHi),
          ),
          child: Text(
            '?',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1,
              color: c.t3,
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact sheet with a few "term - what it does" lines.
Future<void> showHelp(BuildContext context, HelpTopic topic) {
  final l10n = context.l10n;
  final (title, items) = switch (topic) {
    HelpTopic.autoMode => (l10n.autoMode, [
      (l10n.autoMode, l10n.keepsYouConnectedWhenTheServer),
      (l10n.switchToAFasterServer, l10n.movesOnlyWhenTheGainIs),
      (l10n.spareServers, l10n.theNextEntriesArePingedAhead),
      (l10n.checkTheConnectionEvery, l10n.pingsTheCurrentServerOnA),
      (l10n.speedTestOnFailures, l10n.afterFailedRequestsAlsoChecksHow),
      (l10n.leaveAServerAfter, l10n.howManyMissedChecksInA),
      (l10n.onOff, l10n.theAutoBadgeInTheSimple),
      (l10n.priority, l10n.theOrderAutoTriesEntriesIn),
    ]),
    HelpTopic.autoReturn => (l10n.goingBackUp, [
      (l10n.retryPause, l10n.afterAMissedCheckTheServer),
      (l10n.noDrop, l10n.switchingNeverCutsWhatIsAlready),
      (l10n.always, l10n.goBackToAHigherEntry),
      (l10n.ifFaster, l10n.goBackOnlyIfTheHigher),
      (l10n.never, l10n.stayOnTheEntryAutoMoved),
      (l10n.flapProtection, l10n.eachDropOfAnEntryDoubles),
      (l10n.noNetwork, l10n.ifNoEntryAnswersAtAll),
    ]),
    HelpTopic.subsUpdate => (l10n.subscriptionUpdates, [
      (l10n.updateEvery, l10n.howOftenTheServerListsAre),
      (l10n.ownPeriod, l10n.aSubscriptionCanHaveItsOwn),
      (l10n.providerSPeriod, l10n.aSubscriptionLeftOnAutoFollows),
      (l10n.n0Off, l10n.listsAreUpdatedOnlyWhenYou),
    ]),
    HelpTopic.dns => ('DNS', [
      (l10n.servers, l10n.theFirstTickedServerFromThe),
      (l10n.via, l10n.theQueryGoesThroughTheVpn),
      ('ms', l10n.howFastTheServerAnswersTap),
      (l10n.hijackDns, l10n.catchesAppsThatAskTheirOwn),
    ]),
    HelpTopic.dnsAuto => (l10n.switchAutomatically, [
      (l10n.onText, l10n.aServerThatStopsAnsweringIs),
      (l10n.off, l10n.theFirstServerStaysInUse),
    ]),
    HelpTopic.proxyAuth => (l10n.passwordOnThePort, [
      (l10n.onText, l10n.thePortAsksForThisLogin),
      (l10n.off, l10n.anyProgramOnThisPcCan),
    ]),
  };
  final c = context.colors;
  return showAppSheet<void>(
    context,
    builder: (sheet) => SheetFrame(
      title: title,
      bodyPadding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (term, text) in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: term,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: c.t1,
                      ),
                    ),
                    TextSpan(text: ' — $text'),
                  ],
                ),
                style: TextStyle(fontSize: 14, height: 1.45, color: c.t2),
              ),
            ),
        ],
      ),
    ),
  );
}

// ───────────────────────────── menus and dialogs ─────────────────────────────

/// A compact menu sheet (the mockup's `openActions`): [rows] get the sheet's context so a row can
/// close it first.
Future<T?> showMenuSheet<T>(
  BuildContext context,
  String title,
  List<Widget> Function(BuildContext sheet) rows,
) => showAppSheet<T>(
  context,
  builder: (sheet) => SheetFrame(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows(sheet),
    ),
  ),
);

/// A menu row of a pick list: a check on the chosen one, [sub] under the label.
class PickRow extends StatelessWidget {
  const PickRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.sub,
  });

  final String label;
  final String? sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MenuRow(
    icon: selected ? const Icon(Icons.check) : const SizedBox(width: 20),
    label: label,
    sub: sub,
    onTap: onTap,
  );
}

/// Pop the menu sheet, then run [then] (the page the sheet came from is still there).
void closeThen(BuildContext sheet, VoidCallback then) {
  Navigator.of(sheet).pop();
  then();
}

/// The small centred dialog of a number + a unit (`.dialog`): resolves to the text and the
/// chosen multiplier, or null on Cancel. A value [validate] refuses (it returns the reason) keeps
/// the dialog open and shows the reason in place of the hint.
Future<({String text, int unit})?> showNumberUnitDialog(
  BuildContext context, {
  required String title,
  required String hint,
  required String initial,
  required List<(String, int)> units,
  required int unit,
  String? Function(String text, int unit)? validate,
}) {
  final l10n = context.l10n;
  final c = context.colors;
  final ctl = TextEditingController(text: initial);
  var chosen = unit;
  String? error;
  return showDialog<({String text, int unit})>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void done() {
          final why = validate?.call(ctl.text, chosen);
          if (why != null) {
            setState(() => error = why);
            return;
          }
          Navigator.of(ctx).pop((text: ctl.text, unit: chosen));
        }

        return Dialog(
          backgroundColor: c.sheet,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: c.borderHi),
          ),
          child: ContentScale(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.t1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 88,
                        child: AppTextField(
                          controller: ctl,
                          mono: true,
                          autofocus: true,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onSubmitted: (_) => done(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SetSelect<int>(
                          value: chosen,
                          maxWidth: 400,
                          options: [
                            for (final (n, m) in units)
                              (m, _unitName(l10n, n)),
                          ],
                          onChanged: (v) => setState(() => chosen = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  HintText(error ?? hint, warn: error != null),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: done, child: Text(l10n.save)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

String _unitName(AppLocalizations l10n, String id) => switch (id) {
  'seconds' => l10n.seconds,
  'minutes' => l10n.minutes,
  'hours' => l10n.hours,
  'days' => l10n.days,
  _ => id,
};
