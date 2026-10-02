import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';

/// Top of Home when something blocks the internet (mockup `renderVpnAlert`): the VPN is down
/// (sing-box did not come back; the system proxy is kept or not), or the kill switch holds the
/// system proxy after a disconnect. Nothing when [CoreHost.down] and [CoreHost.blocking] are
/// both null.
class VpnAlert extends StatelessWidget {
  const VpnAlert({super.key, required this.host});

  final CoreHost host;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final down = host.down;
    final block = host.blocking;
    if (down == null && block == null) return const SizedBox.shrink();
    final String title;
    String? message;
    final buttons = <Widget>[];
    if (down != null) {
      final held = down.proxy == 'kept';
      title = held
          ? l10n.vpnIsDownInternetIsBlocked
          : l10n.vpnIsDownTrafficGoesDirect;
      message = held
          ? l10n.theSystemProxyIsKeptSo2
          : l10n.tryingAgainInTheBackground;
      buttons.add(_AlertButton(l10n.retry, host.retry));
      if (held) {
        buttons.add(_AlertButton(l10n.disableSysProxy, host.releaseSysProxy));
      }
    } else {
      title = l10n.killSwitchInternetIsBlockedUntil;
      buttons.add(_AlertButton(l10n.remove, host.releaseSysProxy));
    }
    return _AlertBox(title: title, message: message, buttons: buttons);
  }
}

/// `.src-error.vpn-alert`: danger-tinted strip with an icon, a title, an optional line and
/// buttons stacked on the right.
class _AlertBox extends StatelessWidget {
  const _AlertBox({
    required this.title,
    required this.message,
    required this.buttons,
  });

  final String title;
  final String? message;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.danger.tint(.09),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.danger.tint(.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: c.danger),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.danger,
                      ),
                    ),
                    if (message != null)
                      Text(
                        message!,
                        style: TextStyle(fontSize: 12, color: c.t2),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    buttons[i],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.src-error-retry`: small framed button.
class _AlertButton extends StatelessWidget {
  const _AlertButton(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.cardHi,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.borderHi),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: c.t1,
            ),
          ),
        ),
      ),
    );
  }
}
