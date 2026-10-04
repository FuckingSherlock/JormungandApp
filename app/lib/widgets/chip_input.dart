import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show splitRuleValues, validRuleValue;

import '../core/rules_text.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'form_parts.dart';

/// `.chip-input`: the values of a rule field as chips plus a free input. Enter, a comma or a pasted
/// column adds values; a chip's text taps into an inline input (Enter / leaving it commits, an
/// invalid text stays in edit, red, with its hint); x removes a chip; Backspace on an empty input
/// takes the last chip back. A value the field's validator refuses is a red chip (`.vchip.bad`).
class ChipInput extends StatefulWidget {
  const ChipInput({
    super.key,
    required this.values,
    required this.placeholder,
    required this.kind,
    required this.ruleSetNames,
    required this.onAdd,
    required this.onRemove,
    required this.onEdit,
    this.autofocus = false,
  });

  final List<String> values;
  final String placeholder;

  /// The validator kind of the field (`RuleField.kind`).
  final String kind;
  final List<String> ruleSetNames;
  final bool autofocus;

  /// Typed / pasted text: the parent splits it and adds the values.
  final void Function(String text) onAdd;
  final void Function(int index) onRemove;

  /// A chip edited: the new text may be a list (it replaces the chip with those values).
  final void Function(int index, String text) onEdit;

  @override
  State<ChipInput> createState() => _ChipInputState();
}

class _ChipInputState extends State<ChipInput> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  final _editCtl = TextEditingController();
  final _editFocus = FocusNode();
  int? _edit;
  bool _editBad = false;

  bool _valid(String v) =>
      validRuleValue(widget.kind, v, ruleSetNames: widget.ruleSetNames);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit(refocus: false);
      if (mounted) setState(() {});
    });
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus) _commitEdit();
    });
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    _editCtl.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _commit({bool refocus = true}) {
    final t = _ctl.text;
    if (t.trim().isEmpty) {
      _ctl.clear();
      return;
    }
    _ctl.clear();
    widget.onAdd(t);
    if (refocus) _focus.requestFocus();
  }

  void _startEdit(int i) {
    _editCtl.text = widget.values[i];
    _editCtl.selection = TextSelection.collapsed(offset: _editCtl.text.length);
    setState(() {
      _edit = i;
      _editBad = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _commitEdit() {
    final i = _edit;
    if (i == null) return;
    final parts = splitRuleValues(_editCtl.text);
    if (parts.any((v) => !_valid(v))) {
      setState(() => _editBad = true);
      return;
    }
    setState(() {
      _edit = null;
      _editBad = false;
    });
    widget.onEdit(i, _editCtl.text);
  }

  void _cancelEdit() => setState(() {
    _edit = null;
    _editBad = false;
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final badValues =
        _editBad ||
        widget.values.indexed.any((e) => e.$1 != _edit && !_valid(e.$2));
    final chips = <Widget>[];
    for (final (i, v) in widget.values.indexed) {
      chips.add(i == _edit ? _editChip(c) : _chip(c, i, v));
    }
    final input = SizedBox(
      width: 130,
      child: Focus(
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent &&
              e.logicalKey == LogicalKeyboardKey.backspace &&
              _ctl.text.isEmpty &&
              widget.values.isNotEmpty) {
            widget.onRemove(widget.values.length - 1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: _ctl,
          focusNode: _focus,
          autocorrect: false,
          enableSuggestions: false,
          cursorColor: c.accent,
          style: monoText.copyWith(fontSize: 13, color: c.t1),
          onChanged: (t) {
            if (RegExp(r'[,;\n]').hasMatch(t)) _commit();
          },
          onSubmitted: (_) => _commit(),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.all(4),
            hintText: widget.values.isEmpty ? widget.placeholder : null,
            hintStyle: TextStyle(color: c.t3, fontSize: 13),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _focus.requestFocus(),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
            decoration: BoxDecoration(
              color: c.t1.tint(.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _focus.hasFocus || _edit != null ? c.accent : c.border,
              ),
            ),
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [...chips, input],
            ),
          ),
        ),
        if (badValues)
          HintText(l10n.red(valueHint(l10n, widget.kind)), warn: true),
      ],
    );
  }

  Widget _chip(AppColors c, int i, String v) {
    final ok = _valid(v);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
      decoration: BoxDecoration(
        color: ok ? c.accent.tint(.14) : c.muted.tint(.15),
        borderRadius: BorderRadius.circular(6),
        border: ok ? null : Border.all(color: c.muted.tint(.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _startEdit(i),
              child: Text(
                v,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoText.copyWith(
                  fontSize: 12,
                  color: ok ? c.t1 : c.muted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onRemove(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Text(
                '×',
                style: TextStyle(fontSize: 14, height: 1, color: c.t3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editChip(AppColors c) {
    final tone = _editBad ? c.warn : c.accent;
    final w = (_editCtl.text.length.clamp(3, 40) + 1) * 7.6;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      decoration: BoxDecoration(
        color: c.accent.tint(.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tone),
      ),
      child: SizedBox(
        width: w,
        child: Focus(
          onKeyEvent: (node, e) {
            if (e is KeyDownEvent &&
                e.logicalKey == LogicalKeyboardKey.escape) {
              _cancelEdit();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _editCtl,
            focusNode: _editFocus,
            autocorrect: false,
            enableSuggestions: false,
            cursorColor: c.accent,
            style: monoText.copyWith(
              fontSize: 12,
              color: _editBad ? c.warn : c.t1,
            ),
            onChanged: (_) => setState(() => _editBad = false),
            onSubmitted: (_) => _commitEdit(),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }
}
