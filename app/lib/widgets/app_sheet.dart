import 'package:flutter/material.dart';

import '../shell/app_links.dart';
import '../theme/app_colors.g.dart';
import 'app_view.dart';

/// Opens a sheet (the mockup's `.sheet`): rounded top, the app's sheet colour, a handle and a
/// header ([SheetFrame] draws them). One helper for every sheet of the app, so the way they are
/// presented can change in one place.
///
/// Deviation from the mockup, which opens its sheets from the very top and ends them above the
/// bottom nav: a Flutter modal bottom sheet covers the nav bar. Back / a swipe down / a tap on
/// the dim area close it, like the mockup's Back.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  // the sheet's route is not under the shell, so the links it hands out are carried over
  final links = AppLinksScope.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (ctx) => AppLinksScope(links: links, child: builder(ctx)),
  );
}

/// A short message at the bottom of the screen (the mockup's `toast`).
void showToast(BuildContext context, String text) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// The body of a sheet: handle, header (title, close x), the scrolling [child] (text size
/// applied, like `.sheet-body`) and an optional [footer] column pinned under it.
///
/// [full] fills the screen height (forms and editors); otherwise the sheet is as tall as its
/// content (`.sheet.compact`, the menus).
class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.title,
    required this.child,
    this.footer,
    this.full = false,
    this.headerActions = const [],
    this.bodyPadding,
    this.titleBadge,
    this.subHeader,
  });

  final String title;

  /// Pinned under the header, over the scrolling body (the tabs, a search field).
  final Widget? subHeader;

  /// Right after the title text (the round ? of a help sheet).
  final Widget? titleBadge;
  final Widget child;
  final List<Widget>? footer;
  final bool full;
  final List<Widget> headerActions;
  final EdgeInsetsGeometry? bodyPadding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final body = ContentScale(
      child: SingleChildScrollView(
        padding:
            bodyPadding ??
            (full
                ? const EdgeInsets.symmetric(vertical: 12)
                : const EdgeInsets.only(top: 6, bottom: 18)),
        child: child,
      ),
    );
    final column = Column(
      mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: c.borderHi,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 4, 14, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: c.t1,
                        ),
                      ),
                    ),
                    ?titleBadge,
                  ],
                ),
              ),
              ...headerActions,
              const SizedBox(width: 8),
              const SheetCloseButton(),
            ],
          ),
        ),
        ?subHeader,
        if (full) Expanded(child: body) else Flexible(child: body),
        if (footer != null)
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: footer!,
            ),
          ),
      ],
    );
    final framed = DecoratedBox(
      decoration: BoxDecoration(
        color: c.sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: c.borderHi)),
      ),
      child: SafeArea(top: false, child: column),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: full ? SizedBox(height: double.infinity, child: framed) : framed,
    );
  }
}

/// `.sheet-close`: the round x of a sheet header.
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: c.t1.tint(.06),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.close, size: 17, color: c.t2),
      ),
    );
  }
}

/// `.menu-row`: an icon, a label and a smaller line under it. [danger] greys it as the mockup
/// does for Delete; [disabled] only dims it (the tap still explains why).
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.sub,
    this.onTap,
    this.danger = false,
    this.disabled = false,
  });

  final Widget icon;
  final String label;
  final String? sub;
  final VoidCallback? onTap;
  final bool danger;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Opacity(
      opacity: disabled ? .45 : 1,
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        highlightColor: c.t1.tint(.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          child: Row(
            children: [
              IconTheme(
                data: IconThemeData(color: danger ? c.muted : c.t2, size: 20),
                child: icon,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: danger ? c.muted : c.t1,
                      ),
                    ),
                    if (sub != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          sub!,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: c.t2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.menu-caption`: small caps over a group of a menu.
class MenuCaption extends StatelessWidget {
  const MenuCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: .6,
        color: context.colors.t3,
      ),
    ),
  );
}

/// `.menu-note`: a paragraph in a menu; [spans] may carry bold parts.
class MenuNote extends StatelessWidget {
  const MenuNote(this.text, {super.key, this.spans});

  final String text;
  final List<InlineSpan>? spans;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Text.rich(
        TextSpan(text: spans == null ? text : null, children: spans),
        style: TextStyle(fontSize: 13, height: 1.45, color: c.t2),
      ),
    );
  }
}

/// `.seg3` in a menu: a few labelled options, the chosen one filled.
class MenuSegments<T> extends StatelessWidget {
  const MenuSegments({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.t1.tint(.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          for (final (v, label) in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(v),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    vertical: 7,
                    horizontal: 4,
                  ),
                  decoration: BoxDecoration(
                    color: v == value ? c.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: v == value
                          ? Theme.of(context).colorScheme.onPrimary
                          : c.t2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
