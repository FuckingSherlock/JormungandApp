import 'package:flutter/material.dart';

import '../core/core_host.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import '../platform/platform_caps.dart';
import '../theme/app_colors.g.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'nodes_menus.dart' show copyText;
import 'settings_parts.dart';

/// Settings -> Connection (mockup 56-dns.js `renderConnSettings` and its pickers in 59-data.js).
/// What exists only for the Windows system proxy is left out where [PlatformCaps] says so.
Future<void> showConnSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const ConnSheet());

class ConnSheet extends StatelessWidget {
  const ConnSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SheetFrame(title: l10n.connection, child: const _ConnBody());
  }
}

/// A hint under a label that has two texts (the active one shown): both sit in one stack, so the
/// row keeps its height when it flips.
class _HintStack extends StatelessWidget {
  const _HintStack({required this.first, required this.a, required this.b});

  final bool first;
  final String a;
  final String b;

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: first ? 0 : 1,
    alignment: Alignment.topLeft,
    children: [HintText(a), HintText(b)],
  );
}

class _ConnBody extends StatelessWidget {
  const _ConnBody();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final host = CoreHostScope.of(context);
    final cfg = host.catalog.connCfg;
    final caps = host.caps;
    final gen = host.gen;
    final closedOk = gen.launchAtStartup && gen.connectOnLaunch;
    void save() => host.changed();
    void toast(String t) => showToast(context, t);

    Widget toggle(bool on, void Function(bool) set) => MiniToggle(
      on: on,
      onChanged: (v) {
        set(v);
        save();
      },
    );

    void setPort(String raw) {
      final v = parsePort(raw);
      if (v != null && !reservedPorts.contains(v)) {
        cfg.port = v;
        save();
        return;
      }
      final n = int.tryParse(raw.trim());
      toast(
        n != null && reservedPorts.contains(n)
            ? l10n.portIsTakenByTheApp(n)
            : l10n.enterAPort102465535,
      );
    }

    String credText(CredProblem p, bool user) {
      final who = user ? l10n.login : l10n.password;
      return switch (p) {
        CredProblem.empty => '$who ${l10n.mustNotBeEmpty}',
        CredProblem.spaces => '$who ${l10n.cannotContainSpaces}',
        CredProblem.colon => l10n.loginCannotContain,
        CredProblem.tooLong =>
          user
              ? l10n.loginIsTooLongMax(proxyLoginMax)
              : l10n.passwordIsTooLongMax(proxyPassMax),
        CredProblem.tooShort => l10n.passwordIsTooShortMin(proxyPassMin),
      };
    }

    void setCred(bool user, String v) {
      final p = proxyCredProblem(user: user, v: v);
      if (p != null) {
        toast(credText(p, user));
        return;
      }
      if (user) {
        cfg.proxyUser = v;
      } else {
        cfg.proxyPass = v;
      }
      save();
    }

    void toggleAuth(bool on) {
      cfg.proxyAuth = on;
      // off keeps the login and password; on reuses them and makes them only when empty
      if (on) {
        if (cfg.proxyUser.isEmpty) cfg.proxyUser = newProxyLogin();
        if (cfg.proxyPass.isEmpty) cfg.proxyPass = newProxySecret();
      }
      save();
    }

    String? credUser() => cfg.proxyAuth ? cfg.proxyUser : null;
    String? credPass() => cfg.proxyAuth ? cfg.proxyPass : null;

    final tun = tunStacks.firstWhere(
      (s) => s.$1 == cfg.tunStack,
      orElse: () => tunStacks.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetGroup(
          card: true,
          children: [
            if (caps.systemProxy)
              SetRow(
                label: l10n.systemProxy,
                hint: l10n.appsThatFollowTheOsProxy,
                trailing: MiniToggle(
                  on: host.sysProxy,
                  onChanged: (v) => host.setSysProxy(v),
                ),
              ),
            SetRow(
              label: l10n.proxyPort,
              hint: l10n.httpSocks5On12700,
              trailing: CommitField(
                value: '${cfg.port}',
                width: 78,
                onCommit: setPort,
              ),
              below: ChipRow(
                padding: EdgeInsets.zero,
                children: [
                  AppChip(
                    label: l10n.copySocks5,
                    active: false,
                    onTap: () => copyText(
                      context,
                      proxyUrl(
                        'socks5',
                        port: cfg.port,
                        user: credUser(),
                        pass: credPass(),
                      ),
                      l10n.socks5Address,
                    ),
                  ),
                  AppChip(
                    label: l10n.copyHttp,
                    active: false,
                    onTap: () => copyText(
                      context,
                      proxyUrl(
                        'http',
                        port: cfg.port,
                        user: credUser(),
                        pass: credPass(),
                      ),
                      l10n.httpAddress,
                    ),
                  ),
                ],
              ),
            ),
            SetRow(
              labelWidget: Row(
                children: [
                  Flexible(
                    child: Text(
                      l10n.proxyPassword,
                      style: TextStyle(fontSize: 15, color: c.t1),
                    ),
                  ),
                  const HelpButton(HelpTopic.proxyAuth),
                ],
              ),
              trailing: toggle(cfg.proxyAuth, toggleAuth),
            ),
            if (cfg.proxyAuth) ...[
              _AuthRow(
                label: l10n.login,
                value: cfg.proxyUser,
                onCommit: (v) => setCred(true, v),
              ),
              _AuthRow(
                label: l10n.password,
                value: cfg.proxyPass,
                onCommit: (v) => setCred(false, v),
                regenerate: () {
                  cfg.proxyPass = newProxySecret();
                  save();
                  toast(
                    l10n.newPasswordSetProgramsUsingThe,
                  );
                },
                regenTip: l10n.newPassword,
              ),
            ],
            if (caps.killSwitch) ...[
              SetRow(
                label: l10n.killSwitch,
                hint: l10n.blocksTrafficWhenTheVpnIs,
                trailing: MiniToggle(
                  on: cfg.killSwitch,
                  onChanged: (_) => _toggleKill(context, host),
                ),
              ),
              if (cfg.killSwitch) ...[
                _SubRow(
                  child: SetRow(
                    label: l10n.alsoAfterIDisconnect,
                    hint: l10n.internetStaysBlockedUntilYouConnect,
                    trailing: toggle(
                      cfg.killOnDisconnect,
                      (v) => cfg.killOnDisconnect = v,
                    ),
                  ),
                ),
                _SubRow(
                  child: DimWhen(
                    dim: false,
                    child: Opacity(
                      opacity: closedOk ? 1 : .55,
                      child: SetRow(
                        label: l10n.alsoWhileTheAppIsClosed,
                        hint: closedOk
                            ? l10n.theProxyStaysSetWhenThe
                            : l10n.needsLaunchAtStartupAndConnect,
                        onTap: closedOk ? null : () => _confirmClosed(context, host),
                        trailing: MiniToggle(
                          on: closedOk && cfg.killWhileClosed,
                          onChanged: closedOk
                              ? (v) {
                                  if (cfg.killWhileClosed) {
                                    cfg.killWhileClosed = false;
                                    save();
                                  } else {
                                    _confirmClosed(context, host);
                                  }
                                }
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                SetRow(
                  labelWidget: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.removeTheProxyIfTheVpn,
                        style: TextStyle(fontSize: 15, color: c.t1),
                      ),
                      _HintStack(
                        first: cfg.downProxy != 'keep',
                        a: l10n.onTheSystemProxyIsRemoved,
                        b: l10n.offTheProxyStaysSetSo,
                      ),
                    ],
                  ),
                  trailing: toggle(
                    cfg.downProxy != 'keep',
                    (v) => cfg.downProxy = v ? 'remove' : 'keep',
                  ),
                ),
            ],
          ],
        ),
        SetGroup(
          card: true,
          children: [
            SetRow(
              label: l10n.tunStack,
              hint: _stackHint(l10n, tun.$1),
              trailing: SetValueButton(
                text: tun.$2,
                onTap: () => _pickTunStack(context, host),
              ),
            ),
            SetRow(
              label: l10n.latencyTestUrl,
              hint: l10n.theAddressPingAndFastestTime,
              trailing: SetValueButton(
                text: _testUrlLabel(l10n, cfg.testUrl),
                onTap: () => showAppSheet<void>(
                  context,
                  builder: (_) => const _TestUrlSheet(),
                ),
              ),
            ),
            SetRow(
              label: l10n.backupChecks,
              hint: l10n.whenTheTestUrlDoesNot,
              trailing: SetValueButton(
                text: cfg.checkers.isEmpty ? l10n.off : '${cfg.checkers.length}',
                onTap: () => showAppSheet<void>(
                  context,
                  builder: (_) => const _CheckersSheet(),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

String _stackHint(AppLocalizations l10n, String id) => switch (id) {
  'system' => l10n.fastestMayClashWithSomeFirewalls,
  'gvisor' => l10n.mostCompatibleUsesMoreCpu,
  _ => l10n.tcpThroughTheSystemStackUdp,
};

String _testUrlLabel(AppLocalizations l10n, String url) {
  for (final (u, name, _) in testUrlPresets) {
    if (u == url) return name;
  }
  final h = Uri.tryParse(url)?.host ?? '';
  return h.isEmpty ? l10n.custom : h;
}

/// A sub-row of a group (`.set-row.set-sub`): indented under the row it belongs to.
class _SubRow extends StatelessWidget {
  const _SubRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 14),
    child: child,
  );
}

/// Login / Password: the label and a wide left-aligned field (the password one with a button that
/// makes a new one inside the frame).
class _AuthRow extends StatelessWidget {
  const _AuthRow({
    required this.label,
    required this.value,
    required this.onCommit,
    this.regenerate,
    this.regenTip,
  });

  final String label;
  final String value;
  final ValueChanged<String> onCommit;
  final VoidCallback? regenerate;
  final String? regenTip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _SubRow(
      child: SetRow(
        label: label,
        trailing: CommitField(
          value: value,
          width: 150,
          left: true,
          keyboardType: TextInputType.visiblePassword,
          onCommit: onCommit,
          trailing: regenerate == null
              ? null
              : Tooltip(
                  message: regenTip ?? '',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: regenerate,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.refresh, size: 16, color: c.t2),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

// ───────────────────────────── confirmations ─────────────────────────────

/// "Also while the app is closed" is only ever turned on through this sheet; with autostart or
/// auto-connect missing it turns those two on as well.
void _confirmClosed(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final gen = host.gen;
  final need = !(gen.launchAtStartup && gen.connectOnLaunch);
  showMenuSheet<void>(context, l10n.keepBlockingWhileClosed, (sheet) => [
    if (need)
      MenuNote(
        l10n.itOnlyMakesSenseIfThe,
      ),
    MenuNote(
      l10n.ifTheAppDoesnTStart,
    ),
    MenuRow(
      icon: const Icon(Icons.check),
      label: l10n.turnOn,
      onTap: () => closeThen(sheet, () {
        if (need) {
          gen.launchAtStartup = true;
          gen.connectOnLaunch = true;
        }
        host.catalog.connCfg.killWhileClosed = true;
        host.changed();
      }),
    ),
    MenuRow(
      icon: const Icon(Icons.close),
      label: l10n.cancel,
      onTap: () => Navigator.of(sheet).pop(),
    ),
  ]);
}

/// Turning the kill switch off while it protects something (connected, down, or a block after
/// disconnect) asks first; turning it on, or off while idle, does not.
void _toggleKill(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final cfg = host.catalog.connCfg;
  void flip() {
    cfg.killSwitch = !cfg.killSwitch;
    host.changed();
  }

  final protecting = host.isOn || host.blocking != null;
  if (!cfg.killSwitch || !protecting) {
    flip();
    return;
  }
  final keep = cfg.downProxy == 'keep';
  final what = host.blocking != null
      ? l10n.theInternetIsUnblockedNowThe
      : host.down != null
      ? '${l10n.theVpnIsDownRightNow} ${keep ? l10n.theProxyStaysButNothingGuarantees : l10n.theSystemProxyIsRemovedAnd}'
      : '${l10n.theConnectionStaysButIfThe} ${keep ? l10n.nothingGuaranteesTheBlockAnyMore : l10n.theSystemProxyIsRemovedAnd2}';
  showMenuSheet<void>(context, l10n.turnTheKillSwitchOff, (sheet) => [
    MenuNote(what),
    MenuRow(
      icon: const Icon(Icons.check),
      label: l10n.turnItOff,
      onTap: () => closeThen(sheet, flip),
    ),
    MenuRow(
      icon: const Icon(Icons.close),
      label: l10n.keepItOn,
      onTap: () => Navigator.of(sheet).pop(),
    ),
  ]);
}

void _pickTunStack(BuildContext context, CoreHost host) {
  final l10n = context.l10n;
  final cfg = host.catalog.connCfg;
  showMenuSheet<void>(context, l10n.tunStack, (sheet) => [
    for (final (id, name) in tunStacks)
      PickRow(
        label: name,
        sub: _stackHint(l10n, id),
        selected: cfg.tunStack == id,
        onTap: () => closeThen(sheet, () {
          if (cfg.tunStack == id) return;
          cfg.tunStack = id;
          host.changed();
        }),
      ),
  ]);
}

// ───────────────────────────── latency test URL ─────────────────────────────

/// The pick list of presets and a field for an address of one's own.
class _TestUrlSheet extends StatefulWidget {
  const _TestUrlSheet();

  @override
  State<_TestUrlSheet> createState() => _TestUrlSheetState();
}

class _TestUrlSheetState extends State<_TestUrlSheet> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    final cur = CoreHostScope.read(context).catalog.connCfg.testUrl;
    final custom = !testUrlPresets.any((p) => p.$1 == cur);
    _ctl = TextEditingController(text: custom ? cur : '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(String url) {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final cfg = host.catalog.connCfg;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    if (cfg.testUrl == url) return;
    cfg.testUrl = url;
    host.changed();
    final label = _testUrlLabel(l10n, url);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.latencyTest(label)}${host.isOn ? ' — ${l10n.fastestUsesItFromTheNext}' : ''}',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cur = CoreHostScope.of(context).catalog.connCfg.testUrl;
    return SheetFrame(
      title: l10n.latencyTestUrl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (u, name, hint) in testUrlPresets)
            PickRow(
              label: name,
              sub: hint,
              selected: u == cur,
              onTap: () => _set(u),
            ),
          MenuCaption(l10n.custom),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _ctl,
                    hint: 'https://example.com/generate_204',
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _useCustom(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  child: PrimaryButton(label: l10n.use, onPressed: _useCustom),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: HintText(
              l10n.anyAddressThatAnswersFastOver,
            ),
          ),
        ],
      ),
    );
  }

  void _useCustom() {
    final l10n = context.l10n;
    final v = _ctl.text.trim();
    if (!validTestUrl(v)) {
      showToast(context, l10n.enterAnHttpOrHttpsAddress);
      return;
    }
    _set(v);
  }
}

// ───────────────────────────── backup checks ─────────────────────────────

class _CheckersSheet extends StatefulWidget {
  const _CheckersSheet();

  @override
  State<_CheckersSheet> createState() => _CheckersSheetState();
}

class _CheckersSheetState extends State<_CheckersSheet> {
  final TextEditingController _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _toggle(String u) {
    final host = CoreHostScope.read(context);
    final list = host.catalog.connCfg.checkers;
    if (!list.remove(u)) list.add(u);
    host.changed();
  }

  void _add() {
    final l10n = context.l10n;
    final host = CoreHostScope.read(context);
    final v = _ctl.text.trim();
    if (!validTestUrl(v)) {
      showToast(context, l10n.enterAnHttpOrHttpsAddress);
      return;
    }
    final list = host.catalog.connCfg.checkers;
    if (!list.contains(v)) list.add(v);
    _ctl.clear();
    host.changed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final on = host.catalog.connCfg.checkers.toSet();
    final presets = checkerPresets();
    final own = [
      for (final u in host.catalog.connCfg.checkers)
        if (!presets.any((p) => p.$1 == u)) u,
    ];
    Widget row(String u, String name, String sub) => PickRow(
      label: name,
      sub: sub,
      selected: on.contains(u),
      onTap: () => _toggle(u),
    );
    return SheetFrame(
      title: l10n.backupChecks,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (u, name, hint) in presets) row(u, name, hint),
          for (final u in own) row(u, hostOf(u), '$u ${l10n.tapToRemove}'),
          MenuCaption(l10n.yourOwn),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _ctl,
                    hint: 'https://example.com/generate_204',
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 84,
                  child: PrimaryButton(label: l10n.add2, onPressed: _add),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: HintText(
              l10n.servicesOfDifferentOwnersOneBlocked,
            ),
          ),
        ],
      ),
    );
  }
}
