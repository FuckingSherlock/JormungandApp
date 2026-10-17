import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';

/// The popup of a manual subscription update that waits (`host.subWaits`): «Waiting for network…» (no
/// network, up to 5 s) or «Waiting for connection…» (the core's own reconnect), with the subscription's name.
/// Shown while the list is not empty and gone by itself when it is. The shell puts it over the tabs.
class SubWaitPopup extends StatelessWidget {
  const SubWaitPopup({super.key});

  @override
  Widget build(BuildContext context) {
    final host = CoreHostScope.read(context);
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final waits = host.subWaits;
        if (waits.isEmpty) return const SizedBox.shrink();
        final c = context.colors;
        final l10n = context.l10n;
        // the network wait is the one that holds the update first; a connection wait follows it
        final forNetwork = waits.any((w) => w.forWhat == 'network');
        final names = <String>{for (final w in waits) w.name.isEmpty ? w.source : w.name}.join(', ');
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Material(
                color: c.surface,
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(forNetwork ? l10n.waitingForNetwork : l10n.waitingForConnection),
                            Text(names, style: TextStyle(fontSize: 12, color: c.t3)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
