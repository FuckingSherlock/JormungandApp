import 'package:flutter/material.dart';

import '../theme/app_colors.g.dart';
import 'form_parts.dart';

/// `.search`: a framed field with the magnifier; [onClose] adds the x at the right (the field
/// under a header that can be closed). Used by Logs, Live connections and the filter sheets.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onClose,
    this.closeTooltip,
    this.autofocus = false,
    this.margin = const EdgeInsets.fromLTRB(14, 0, 14, 10),
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClose;
  final String? closeTooltip;
  final bool autofocus;
  final EdgeInsetsGeometry margin;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: widget.margin,
      padding: EdgeInsets.only(left: 12, right: widget.onClose == null ? 12 : 6),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _focused ? c.accent : c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: c.t3),
          const SizedBox(width: 8),
          Expanded(
            child: Focus(
              onFocusChange: (f) => setState(() => _focused = f),
              child: TextField(
                controller: widget.controller,
                autofocus: widget.autofocus,
                onChanged: widget.onChanged,
                style: TextStyle(fontSize: 15, color: c.t1),
                cursorColor: c.accent,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: c.t3),
                ),
              ),
            ),
          ),
          if (widget.onClose != null)
            IconBtn(
              kind: IconBtnKind.ghost,
              tooltip: widget.closeTooltip,
              onTap: widget.onClose,
              icon: const Icon(Icons.close, size: 15),
            ),
        ],
      ),
    );
  }
}
