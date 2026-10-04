import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show CatalogImpact, CatalogNode, CatalogOps, ImpactLine, Source;
import 'package:url_launcher/url_launcher.dart';

import '../core/core_host.dart';
import '../l10n/l10n.dart';
import '../platform/import_io.dart';
import '../platform/platform_caps.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'entry_editors.dart';
import 'form_parts.dart';
import 'nodes_forms.dart';
import 'nodes_text.dart';
import 'qr_box.dart';
import 'source_entry_sheet.dart';
import 'speed_test_sheet.dart';

/// The small menus and the delete confirmation of the Nodes screen (mockup 30-nodes.js:
/// `openNodesMore`, `openSourceActions`, `openNodeActions`, `openGoneActions`,
/// `confirmDelete*`; 31-catalog.js `openNodesAdd`; 20-profiles.js `openCreateMenu`;
/// 37-share.js). Each is a function taking the page's [BuildContext]: it opens a compact sheet,
/// and a row closes it first, then does its job (or opens the next sheet) from the same context.

/// Runs [then] once the sheet [sheet] is closed, if the page is still there.
void _after(BuildContext sheet, BuildContext page, VoidCallback then) {
  Navigator.of(sheet).pop();
  if (page.mounted) then();
}

Future<void> _menu(
  BuildContext context,
  String title,
  List<Widget> Function(BuildContext sheet) rows,
) => showAppSheet<void>(
  context,
  builder: (sheet) => SheetFrame(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows(sheet),
    ),
  ),
);

/// Copies [text] and says "[what] copied".
Future<void> copyText(BuildContext context, String text, String what) async {
  final l10n = context.l10n;
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showToast(context, l10n.copied2(what));
}

// ── Add / Create ──

/// The "+" of Nodes: on Simple the Add menu, on Profiles the Create menu. [onOpenCard] opens the
/// card of what was added.
void showNodesAdd(
  BuildContext context, {
  required String tab,
  required ValueChanged<String> onOpenCard,
}) {
  final host = CoreHostScope.read(context);
  final l10n = context.l10n;
  if (tab == 'profiles') {
    final enough = host.catalog.getProfileIds().length >= 2;
    _menu(
      context,
      l10n.create,
      (sheet) => [
        MenuRow(
          icon: const Icon(Icons.add),
          label: l10n.profile,
          sub: l10n.chosenSubscriptionsOrSingleServersUses,
          onTap: () => _after(sheet, context, () => showProfileEditor(context)),
        ),
        MenuRow(
          icon: const ChainIcon(size: 20),
          label: l10n.chain,
          sub: enough
              ? l10n.enterThroughOneProfileExitThrough
              : l10n.needsAtLeastTwoProfiles,
          disabled: !enough,
          onTap: () => _after(
            sheet,
            context,
            () => _openChainEditor(context, 'profiles'),
          ),
        ),
      ],
    );
    return;
  }
  final enough = host.catalog.unitIdsOf('simple').length >= 2;
  _menu(
    context,
    l10n.add2,
    (sheet) => [
      MenuRow(
        icon: const Icon(Icons.link),
        label: l10n.subscription,
        sub: l10n.pasteASubscriptionUrl,
        onTap: () => _after(
          sheet,
          context,
          () => showSubscriptionForm(context, onOpenCard: onOpenCard),
        ),
      ),
      MenuRow(
        icon: const Icon(Icons.content_paste),
        label: l10n.fromClipboard,
        sub: l10n.subscriptionUrlOrVlessHy2Link,
        onTap: () => _after(
          sheet,
          context,
          () => _addFromClipboard(context, onOpenCard),
        ),
      ),
      MenuRow(
        icon: const Icon(Icons.dns_outlined),
        label: l10n.manualServer,
        sub: l10n.fillInAddressPortAndKey,
        onTap: () => _after(
          sheet,
          context,
          () => showNodeForm(context, onOpenCard: onOpenCard),
        ),
      ),
      MenuRow(
        icon: const ChainIcon(size: 20),
        label: l10n.chain,
        sub: l10n.enterThroughOneSubscriptionOrGroup,
        disabled: !enough,
        onTap: () =>
            _after(sheet, context, () => _openChainEditor(context, 'simple')),
      ),
      if (host.caps.cameraScan)
        MenuRow(
          icon: const Icon(Icons.qr_code_2),
          label: l10n.scanQrCode,
          onTap: () =>
              _after(sheet, context, () => _scanQr(context, onOpenCard)),
        ),
      MenuRow(
        icon: const Icon(Icons.insert_drive_file_outlined),
        label: l10n.importConfigFile,
        sub: l10n.singBoxJsonClashYamlA,
        onTap: () =>
            _after(sheet, context, () => _importFile(context, onOpenCard)),
      ),
    ],
  );
}

/// "Scan QR code": the camera reads a code, its text goes where pasted text goes.
Future<void> _scanQr(
  BuildContext context,
  ValueChanged<String> onOpenCard,
) async {
  final text = await ImportIo.current.scan(context);
  if (text == null || !context.mounted) return;
  _importText(context, text, onOpenCard);
}

/// "Import config file": a picked image is read as a QR code and its text goes where pasted
/// text goes; any other file (sing-box JSON, Clash YAML, a list of links) becomes a local source
/// (kind `file`) and its card opens.
Future<void> _importFile(
  BuildContext context,
  ValueChanged<String> onOpenCard,
) async {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  PickedFile? picked;
  try {
    picked = await ImportIo.current.pickFile();
  } on ImportException catch (e) {
    if (context.mounted) {
      showToast(
        context,
        e.failure == ImportFailure.noQr
            ? l10n.noQrCodeFoundInThe
            : l10n.theFileCouldNotBeOpened,
      );
    }
    return;
  }
  if (picked == null || !context.mounted) return;
  // an image (its QR) or a file that is just a subscription URL: the usual paste path
  if (picked.qr ||
      RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(picked.text.trim())) {
    _importText(context, picked.text, onOpenCard);
    return;
  }
  final r = await host.importConfigFile(picked.name, picked.text);
  if (!context.mounted) return;
  final sid = r.sourceId;
  if (sid == null) {
    final err = r.error ?? '';
    showToast(
      context,
      l10n.couldNotImport(picked.name, switch (err) {
        'No servers found in the file' => l10n.noServersFoundInTheFile,
        'The file is over 16 MB' => l10n.theFileIsOver16Mb,
        _ => err,
      }),
    );
    return;
  }
  onOpenCard(sid);
  showToast(context, l10n.importedServersFromPlural(r.count, r.name));
}

/// Chain editor from the menus: a chain needs two units of the tab (`openCreateChain`).
void _openChainEditor(BuildContext context, String tab) {
  final host = CoreHostScope.read(context);
  final l10n = context.l10n;
  if (host.catalog.unitIdsOf(tab).length < 2) {
    showToast(
      context,
      tab == 'simple'
          ? l10n.aChainNeedsTwoSubscriptionsOr
          : l10n.aChainNeedsTwoProfilesCreate,
    );
    return;
  }
  showChainEditor(context, tab: tab);
}

/// "From clipboard": a subscription URL opens the subscription form with it, share links the
/// server form (`pasteFromClipboard`, with the real clipboard).
Future<void> _addFromClipboard(
  BuildContext context,
  ValueChanged<String> onOpenCard,
) async {
  final l10n = context.l10n;
  String text;
  try {
    text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
  } catch (_) {
    if (context.mounted) showToast(context, l10n.clipboardIsNotReadableHere);
    return;
  }
  if (!context.mounted) return;
  _importText(
    context,
    text,
    onOpenCard,
    foundToast: l10n.subscriptionUrlFoundInClipboard,
    notFound: l10n.noSubscriptionUrlOrServerLink,
  );
}

/// Where text from the clipboard, a QR code or a file goes: a subscription URL opens the
/// subscription form with it, share links the server form. [foundToast] follows a URL;
/// [notFound] is said when the text holds neither.
void _importText(
  BuildContext context,
  String raw,
  ValueChanged<String> onOpenCard, {
  String? foundToast,
  String? notFound,
}) {
  final host = CoreHostScope.read(context);
  final text = raw.trim();
  if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(text)) {
    showSubscriptionForm(context, prefillUrl: text, onOpenCard: onOpenCard);
    if (foundToast != null) showToast(context, foundToast);
  } else if (text.isNotEmpty && host.parseLinks(text).isNotEmpty) {
    showNodeForm(context, link: text, onOpenCard: onOpenCard);
  } else {
    showToast(context, notFound ?? context.l10n.noSubscriptionUrlOrServerLink2);
  }
}

// ── More ──

/// The ⋮ of the header: update all, collapse / expand all, the sort of server lists.
void showNodesMore(
  BuildContext context, {
  required bool anyOpen,
  required ValueChanged<bool> onSetAllOpen,
}) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  showAppSheet<void>(
    context,
    builder: (sheet) {
      // inside the builder: rebuilds when the sort changes
      final sort = CoreHostScope.of(sheet).nodeSort;
      return SheetFrame(
        title: l10n.nodes,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuRow(
              icon: const Icon(Icons.refresh),
              label: l10n.updateAllSubscriptions,
              onTap: () {
                Navigator.of(sheet).pop();
                host.updateAll();
              },
            ),
            MenuRow(
              icon: Icon(anyOpen ? Icons.unfold_less : Icons.unfold_more),
              label: anyOpen ? l10n.collapseAll : l10n.expandAll,
              onTap: () {
                Navigator.of(sheet).pop();
                onSetAllOpen(!anyOpen);
              },
            ),
            MenuCaption(l10n.sortNodes),
            MenuSegments<String>(
              value: sort,
              onChanged: host.setNodeSort,
              options: [
                ('order', l10n.asInSource),
                ('latency', l10n.byLatency),
                ('name', l10n.byName),
              ],
            ),
          ],
        ),
      );
    },
  );
}

// ── Source / server / unavailable-server actions ──

void showSourceActions(
  BuildContext context,
  Source s, {
  required ValueChanged<String> onOpenCard,
}) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  final isSub = s.kind == 'sub';
  final ua = '${s.unknown['userAgent'] ?? 'Auto'}';
  final site = '${s.unknown['website'] ?? ''}'.isNotEmpty
      ? '${s.unknown['website']}'
      : '${s.unknown['webPage'] ?? ''}';
  final support = '${s.unknown['supportUrl'] ?? ''}';
  _menu(
    context,
    s.name,
    (sheet) => [
      MenuRow(
        icon: const Icon(Icons.edit_outlined),
        label: isSub
            ? l10n.editSubscription
            : s.kind == 'file'
            ? l10n.rename
            : l10n.renameGroup,
        onTap: () => _after(
          sheet,
          context,
          () =>
              showSubscriptionForm(context, sid: s.id, onOpenCard: onOpenCard),
        ),
      ),
      MenuRow(
        icon: const Icon(Icons.bolt),
        label: l10n.routeSettings,
        sub: l10n.serversItUsesAsARoute,
        onTap: () =>
            _after(sheet, context, () => showSourceEntry(context, s.id)),
      ),
      if (isSub && ua == 'Auto')
        MenuRow(
          icon: const Icon(Icons.refresh),
          label: l10n.updateWithAllUserAgents,
          sub: l10n.asksAsSingBoxMihomoAnd,
          onTap: () => _after(
            sheet,
            context,
            () => host.updateSource(s.id, rediscover: true),
          ),
        ),
      if (isSub && (s.url ?? '').isNotEmpty) ...[
        MenuRow(
          icon: const Icon(Icons.copy),
          label: l10n.copyUrl,
          onTap: () => _after(
            sheet,
            context,
            () => copyText(context, s.url!, l10n.subscriptionUrl),
          ),
        ),
        MenuRow(
          icon: const Icon(Icons.qr_code_2),
          label: l10n.showQrCode,
          onTap: () => _after(
            sheet,
            context,
            () => showShareSheet(
              context,
              title: s.name,
              text: s.url!,
              what: l10n.subscriptionUrl,
              copyLabel: l10n.copyUrl,
            ),
          ),
        ),
      ],
      if (isSub && site.isNotEmpty)
        MenuRow(
          icon: const Icon(Icons.language),
          label: l10n.openWebsite,
          onTap: () => _after(sheet, context, () => _openUrl(context, site)),
        ),
      if (isSub && support.isNotEmpty)
        MenuRow(
          icon: const Icon(Icons.language),
          label: l10n.support,
          onTap: () => _after(sheet, context, () => _openUrl(context, support)),
        ),
      MenuRow(
        icon: const Icon(Icons.delete_outline),
        label: l10n.delete,
        danger: true,
        onTap: () =>
            _after(sheet, context, () => confirmDeleteSource(context, s)),
      ),
    ],
  );
}

void showNodeActions(BuildContext context, Source s, CatalogNode n) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  final on = !host.catalog.isNodeDisabled(s, n.id);
  _menu(
    context,
    '${n.flag}  ${n.name}',
    (sheet) => [
      MenuRow(
        icon: const Icon(Icons.power_settings_new),
        label: on ? l10n.switchOff : l10n.switchOn,
        sub: on ? l10n.hiddenEverywhereItsSettingsKept : null,
        onTap: () =>
            _after(sheet, context, () => host.toggleNodeEnabled(s.id, n.id)),
      ),
      MenuRow(
        icon: const Icon(Icons.copy),
        label: l10n.copyShareLink,
        onTap: () => _after(sheet, context, () => _copyShareLink(context, n)),
      ),
      MenuRow(
        icon: const Icon(Icons.qr_code_2),
        label: l10n.showQrCode,
        onTap: () => _after(sheet, context, () => _showNodeShare(context, n)),
      ),
      MenuRow(
        icon: const Icon(Icons.speed),
        label: l10n.speedTest,
        sub: l10n.downloadUploadAndLatencyThroughThis,
        onTap: () => _after(sheet, context, () => showSpeedTest(context, n)),
      ),
      if (s.kind == 'node') ...[
        MenuRow(
          icon: const Icon(Icons.edit_outlined),
          label: l10n.editServer,
          onTap: () => _after(
            sheet,
            context,
            () => showNodeForm(context, sid: s.id, node: n),
          ),
        ),
        MenuRow(
          icon: const Icon(Icons.delete_outline),
          label: l10n.delete,
          danger: true,
          onTap: () =>
              _after(sheet, context, () => confirmDeleteNode(context, s, n)),
        ),
      ],
    ],
  );
}

/// "Open website" / "Support": the page of the provider in the browser (or the app that handles
/// its link, e.g. Telegram). The address comes from the subscription's headers, so only web,
/// Telegram and mail schemes are launched; no scheme means https.
Future<void> _openUrl(BuildContext context, String raw) async {
  final l10n = context.l10n;
  var text = raw.trim();
  if (!RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(text)) {
    text = 'https://$text';
  }
  final uri = Uri.tryParse(text);
  var ok = false;
  if (uri != null &&
      const {'http', 'https', 'tg', 'mailto'}.contains(uri.scheme)) {
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
  if (!ok && context.mounted) showToast(context, l10n.couldNotOpen(raw));
}

String _noLinkWhy(AppLocalizations l10n, CatalogNode n) =>
    l10n.thisServerHasNoShareLink(
      (n.unsupported ?? '').isNotEmpty ? n.unsupported! : n.protocol,
    );

void _copyShareLink(BuildContext context, CatalogNode n) {
  final l10n = context.l10n;
  final link = CoreHostScope.read(context).shareLink(n);
  if (link == null) {
    showToast(context, _noLinkWhy(l10n, n));
  } else {
    copyText(context, link, l10n.shareLink);
  }
}

void _showNodeShare(BuildContext context, CatalogNode n) {
  final l10n = context.l10n;
  final link = CoreHostScope.read(context).shareLink(n);
  if (link == null) {
    showToast(context, _noLinkWhy(l10n, n));
    return;
  }
  showShareSheet(
    context,
    title: '${n.flag}  ${n.name}',
    text: link,
    what: l10n.shareLink,
    copyLabel: l10n.copyShareLink,
  );
}

/// The share sheet (`showQr`): the code, the text under it and Copy. A text that does not fit
/// into a QR code only gets a toast.
void showShareSheet(
  BuildContext context, {
  required String title,
  required String text,
  required String what,
  required String copyLabel,
}) {
  final c = context.colors;
  final qr = QrBox.of(text);
  if (qr == null) {
    showToast(context, context.l10n.tooLongForAQrCode);
    return;
  }
  _menu(
    context,
    title,
    (sheet) => [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Column(
          children: [
            qr,
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 74),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.border),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: monoText.copyWith(
                    fontSize: 11,
                    height: 1.4,
                    color: c.t2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      MenuRow(
        icon: const Icon(Icons.copy),
        label: copyLabel,
        onTap: () => copyText(context, text, what),
      ),
    ],
  );
}

void showGoneActions(BuildContext context, Source s, CatalogNode n) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  final days = host.catalog.goneLeftDays(n) ?? 0;
  final ago = n.goneAt == null ? '' : timeAgo(l10n, n.goneAt!);
  _menu(
    context,
    '${n.flag}  ${n.name}',
    (sheet) => [
      MenuNote(l10n.removedByTheProviderIfA(ago, l10n.daysPlural(days))),
      MenuRow(
        icon: const Icon(Icons.delete_outline),
        label: l10n.forgetNow,
        sub: l10n.dropsItAndItsSettingsEverywhere,
        danger: true,
        onTap: () => _after(sheet, context, () {
          final k = host.forgetGone(s.id, [n.id]);
          showToast(context, l10n.forgotUnavailableServersPlural(k));
        }),
      ),
    ],
  );
}

// ── Delete ──

/// The English texts of the core's impact lines, in the language of the app. The core
/// (impact.dart) keeps the mockup's English; these are the mockup's dictionary entries.
({String name, String kind, String what}) localizeImpact(
  AppLocalizations l10n,
  ImpactLine line,
) {
  final name = line.name == 'Current connection'
      ? l10n.currentConnection
      : line.name;
  String kind = line.kind;
  if (kind == 'chain') {
    kind = l10n.chain2;
  } else if (kind == 'profile') {
    kind = l10n.profile2;
  } else if (kind == 'entry') {
    kind = l10n.entry2;
  } else if (kind.startsWith('rule #')) {
    kind = l10n.rule5(int.tryParse(kind.substring(6)) ?? 0);
  } else if (kind.startsWith('app')) {
    kind = l10n.app2 + kind.substring(3);
  }
  return (name: name, kind: kind, what: _impactWhat(l10n, line.what));
}

String _impactWhat(AppLocalizations l10n, String what) {
  switch (what) {
    case 'goes through it — will reconnect through the next working server':
      return l10n.goesThroughItWillReconnectThrough2;
    case 'goes through it — will reconnect through the next entry':
      return l10n.goesThroughItWillReconnectThrough;
    case 'is deleted with it':
      return l10n.isDeletedWithIt;
    case "is left with no servers — won't connect until you select another":
      return l10n.isLeftWithNoServersWon;
  }
  if (what.startsWith('its entry is left with no servers')) {
    return l10n.itsEntryIsLeftWithNo;
  }
  if (what.startsWith('its exit is left with no servers')) {
    return l10n.itsExitIsLeftWithNo;
  }
  var m = RegExp(r'^its (entry|exit) moves to (.*)$').firstMatch(what);
  if (m != null) {
    return m[1] == 'entry'
        ? l10n.itsEntryMovesTo(m[2]!)
        : l10n.itsExitMovesTo(m[2]!);
  }
  m = RegExp(r'^loses (\d+) servers? of (\d+)$').firstMatch(what);
  if (m != null) {
    return l10n.losesServersOfPlural(int.parse(m[1]!), int.parse(m[2]!));
  }
  m = RegExp(r'^loses its target — traffic goes (.*)$').firstMatch(what);
  if (m != null) {
    switch (m[1]) {
      case 'through the main flow':
        return l10n.losesItsTargetTrafficGoesThrough;
      case 'nowhere (blocked)':
        return l10n.losesItsTargetTrafficGoesNowhere;
      case 'direct':
        return l10n.losesItsTargetTrafficGoesDirect;
    }
    return what;
  }
  // "entry loses 2 servers, exit loses 1 server (out of its priority order)"
  final parts = what.split(', ');
  final out = <String>[];
  for (final p in parts) {
    final e = RegExp(r'^entry loses (\d+) servers?$').firstMatch(p);
    final x = RegExp(
      r'^exit loses (\d+) servers?( \(out of its priority order\))?$',
    ).firstMatch(p);
    if (e != null) {
      out.add(l10n.entryLosesServersPlural(int.parse(e[1]!)));
    } else if (x != null) {
      final k = int.parse(x[1]!);
      out.add(
        x[2] != null
            ? l10n.exitLosesServersOutOfItsPlural(k)
            : l10n.exitLosesServersPlural(k),
      );
    } else {
      return what;
    }
  }
  return out.join(', ');
}

/// The delete confirmation: [note], what it affects, Delete and Cancel (`confirmDeleteHtml`).
void _confirmDelete(
  BuildContext context, {
  required String title,
  required String note,
  required List<ImpactLine> lines,
  required String label,
  required VoidCallback onDelete,
}) {
  final l10n = context.l10n;
  final c = context.colors;
  _menu(context, title, (sheet) {
    final impact = [for (final l in lines) localizeImpact(l10n, l)];
    return [
      MenuNote(note),
      if (lines.isEmpty)
        MenuNote(l10n.notUsedInAnyProfileChain)
      else ...[
        MenuCaption(l10n.thisWillAffect),
        Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, l) in impact.indexed)
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        width: 3,
                        color: lines[i].level == 'bad' ? c.muted : c.warn,
                      ),
                      top: i > 0
                          ? BorderSide(color: c.border)
                          : BorderSide.none,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              l.name,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: c.t1,
                              ),
                            ),
                          ),
                          if (l.kind.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            ConnTag(l.kind, tone: TagTone.muted),
                          ],
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          l.what,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: lines[i].level == 'bad' ? c.muted : c.t2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
      MenuRow(
        icon: const Icon(Icons.delete_outline),
        label: label,
        danger: true,
        onTap: () => _after(sheet, context, onDelete),
      ),
      MenuRow(
        icon: const Icon(Icons.close),
        label: l10n.cancel,
        onTap: () => Navigator.of(sheet).pop(),
      ),
    ];
  });
}

void confirmDeleteSource(BuildContext context, Source s) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  final n = s.nodes.length, g = s.gone.length;
  final sub = s.kind == 'sub';
  final file = s.kind == 'file';
  final String note;
  if (g > 0) {
    note =
        (sub
            ? l10n.theSubscriptionAndItsServersArePlural2(n)
            : file
            ? l10n.theImportedFileAndItsServersPlural2(n)
            : l10n.theGroupAndItsServersArePlural2(n)) +
        (g == 1
            ? l10n.withUnavailableOneKeptForTheir(g)
            : l10n.withUnavailableOnesKeptForTheir(g)) +
        l10n.thisCanTBeUndone;
  } else {
    note = sub
        ? l10n.theSubscriptionAndItsServersArePlural(n)
        : file
        ? l10n.theImportedFileAndItsServersPlural(n)
        : l10n.theGroupAndItsServersArePlural(n);
  }
  _confirmDelete(
    context,
    title: l10n.delete2(s.name),
    note: note,
    lines: host.catalog.deleteSourceImpact(s.id),
    label: sub
        ? l10n.deleteSubscription
        : file
        ? l10n.deleteImportedFile
        : l10n.deleteGroup,
    onDelete: () => host.deleteSource(s.id),
  );
}

void confirmDeleteNode(BuildContext context, Source s, CatalogNode n) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  _confirmDelete(
    context,
    title: l10n.delete2(n.name),
    note: l10n.isRemovedFromWithItsPlace(n.flag, n.name, s.name),
    lines: host.catalog.deleteNodeImpact(s.id, n.id),
    label: l10n.deleteServer,
    onDelete: () => host.deleteNode(s.id, n.id),
  );
}

/// A profile or a chain (the editors' Delete).
void confirmDeleteEntry(BuildContext context, String id) {
  final l10n = context.l10n;
  final host = CoreHostScope.read(context);
  final e = host.catalog.connectEntry(id);
  if (e == null) return;
  final chain = host.catalog.isChain(id);
  _confirmDelete(
    context,
    title: l10n.delete2(e.name),
    note: chain
        ? l10n.theChainIsRemovedFromNodes
        : l10n.theProfileIsRemovedFromNodes,
    lines: host.catalog.deleteEntryImpact(id),
    label: chain ? l10n.deleteChain : l10n.deleteProfile,
    onDelete: () => host.deleteEntry(id),
  );
}
