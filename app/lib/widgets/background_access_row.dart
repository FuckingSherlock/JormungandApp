import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../platform/power_channel.dart';
import 'form_parts.dart';

/// Settings -> Connection: whether Android lets the app work in the background without battery
/// limits (docs/platforms.md, "Работа в фоне"), with the button to ask when it does not. Nothing
/// where there is nothing to ask ([PowerIo.available] false). Re-reads the state when the user
/// comes back from the system.
class BackgroundAccessRow extends StatefulWidget {
  const BackgroundAccessRow({super.key, this.io});

  final PowerIo? io;

  @override
  State<BackgroundAccessRow> createState() => _BackgroundAccessRowState();
}

class _BackgroundAccessRowState extends State<BackgroundAccessRow>
    with WidgetsBindingObserver {
  late final PowerIo _io = widget.io ?? PowerIo.current;

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
    return ValueListenableBuilder<BackgroundAccess>(
      valueListenable: _io.access,
      builder: (context, state, _) {
        if (state == BackgroundAccess.unsupported) {
          return const SizedBox.shrink();
        }
        final ok = state == BackgroundAccess.allowed;
        return SetGroup(
          card: true,
          children: [
            SetRow(
              label: l10n.workInTheBackground,
              hintWidget: HintText(
                ok
                    ? l10n.allowedTheVpnAutoAndThe
                    : l10n.limitedByTheSystemAndroidMay,
                warn: !ok,
              ),
              below: ok
                  ? null
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: SecondaryButton(
                        label: l10n.allow,
                        onPressed: _io.request,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
