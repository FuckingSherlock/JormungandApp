import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_update.dart';
import '../core/core_host.dart';
import '../core/format.dart';
import '../core/settings_model.dart';
import '../l10n/l10n.dart';
import '../platform/files_channel.dart';
import '../platform/platform_caps.dart';
import '../state/app_settings.dart';
import '../theme/app_colors.g.dart';
import 'app_card.dart';
import 'app_sheet.dart';
import 'form_parts.dart';
import 'save_flow.dart';
import 'settings_parts.dart';

/// Settings -> Data (mockup 59-data.js): App updates, Backup (export / restore with a confirm
/// sheet) and About. The updater is the core's AppUpdater through the host; the files go through
/// [BackupIo].
Future<void> showDataSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const DataSheet());

class DataSheet extends StatefulWidget {
  const DataSheet({super.key});

  @override
  State<DataSheet> createState() => _DataSheetState();
}

class _DataSheetState extends State<DataSheet> {
  Map<String, dynamic>? _version;

  @override
  void initState() {
    super.initState();
    CoreHostScope.read(context).version().then((v) {
      if (mounted) setState(() => _version = v);
    }, onError: (_) {
      if (mounted) setState(() => _version = const {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final host = CoreHostScope.of(context);
    final v = _version;
    Widget val(String? x, String fallback) => Text(
      x == null || x.isEmpty ? fallback : x,
      style: monoText.copyWith(fontSize: 13, color: context.colors.t2),
    );
    final wait = Text('…', style: TextStyle(color: context.colors.t2));
    return SheetFrame(
      title: l10n.data,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _UpdatesBlock(),
          SetCaption(l10n.backup),
          SetGroup(
            card: true,
            children: [
              SetRow(
                label: l10n.exportBackup,
                hint: l10n.sourcesWithTheirServersProfilesChains,
                trailing: Icon(
                  Icons.file_download_outlined,
                  size: 20,
                  color: context.colors.t2,
                ),
                onTap: () => _export(context, host),
              ),
              SetRow(
                label: l10n.restoreFromFile,
                hint: l10n.replacesEverythingHereWithTheBackup,
                trailing: Icon(
                  Icons.file_upload_outlined,
                  size: 20,
                  color: context.colors.t2,
                ),
                onTap: () => _restore(context, host),
              ),
            ],
          ),
          SetCaption(l10n.about),
          SetGroup(
            card: true,
            children: [
              SetRow(
                label: 'Jormungand',
                trailing: val(host.appVersion, '—'),
              ),
              SetRow(
                label: l10n.build,
                trailing: val(
                  [
                    if (host.appBuild > 0) '${host.appBuild}',
                    if (host.appCommit.isNotEmpty) host.appCommit,
                  ].join(' · '),
                  '—',
                ),
              ),
              SetRow(
                label: 'sing-box',
                trailing: v == null
                    ? wait
                    : val('${v['singBox'] ?? ''}', l10n.notFound),
              ),
              if (v != null && '${v['dataDir'] ?? ''}'.isNotEmpty)
                SetRow(
                  label: l10n.dataFolder,
                  hintWidget: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${v['dataDir']}',
                      style: monoText.copyWith(
                        fontSize: 11,
                        color: context.colors.t2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── backup ─────────────────────────────

Future<void> _export(BuildContext context, CoreHost host) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String t) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(t)));
  final at = DateTime.now().toUtc();
  final file = {
    'app': 'jormungand',
    'backup': 1,
    'at': at.toIso8601String(),
    'snapshot': host.exportState(),
  };
  final name = 'jormungand-backup-${at.toIso8601String().substring(0, 10)}.json';
  try {
    final saved = await saveExport(
      context,
      android: host.caps.folderPicker,
      name: name,
      text: const JsonEncoder.withIndent('  ').convert(file),
    );
    if (saved != null) say(l10n.backupSaved2(saved.label));
  } catch (e) {
    say(l10n.backupFailed('$e'));
  }
}

Future<void> _restore(BuildContext context, CoreHost host) async {
  final l10n = context.l10n;
  PickedFile? picked;
  try {
    picked = await BackupIo.current.pick();
  } catch (e) {
    if (context.mounted) {
      showToast(context, l10n.cannotRestore('$e'));
    }
    return;
  }
  if (picked == null || !context.mounted) return;
  Object? j;
  try {
    j = jsonDecode(picked.text);
  } catch (_) {
    showToast(context, l10n.cannotRestore(l10n.notAJsonFile));
    return;
  }
  final snap = j is Map && j['snapshot'] is Map ? j['snapshot'] : j;
  if (snap is! Map ||
      snap['sourcesData'] is! Map ||
      snap['sourceOrder'] is! List) {
    showToast(context, l10n.cannotRestore(l10n.noJormungandBackupInIt));
    return;
  }
  final at = j is Map && j['at'] is String ? DateTime.tryParse(j['at'] as String) : null;
  _confirmRestore(
    context,
    host,
    Map<String, dynamic>.from(snap),
    at,
    picked.name,
  );
}

int _count(Object? o) => o is Map ? o.length : 0;

void _confirmRestore(
  BuildContext context,
  CoreHost host,
  Map<String, dynamic> snap,
  DateTime? at,
  String fileName,
) {
  final l10n = context.l10n;
  final c = context.colors;
  var servers = 0;
  for (final s in (snap['sourcesData'] as Map).values) {
    if (s is Map && s['nodes'] is List) servers += (s['nodes'] as List).length;
  }
  final what = [
    l10n.sourcesPlural(_count(snap['sourcesData'])),
    l10n.serversPlural(servers),
    l10n.profilesPlural(_count(snap['profilesData'])),
    l10n.chainsPlural(_count(snap['chainsData'])),
    l10n.rulesPlural(_count(snap['rulesData'])),
  ].join(' · ');
  final when = at == null
      ? ''
      : ' · ${MaterialLocalizations.of(context).formatShortDate(at.toLocal())} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal()))}';
  final messenger = ScaffoldMessenger.maybeOf(context);
  final dataContext = context;
  showMenuSheet<void>(context, l10n.restoreBackup, (sheet) => [
    Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.t1.tint(.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$fileName$when',
            style: monoText.copyWith(fontSize: 12, color: c.t2),
          ),
          const SizedBox(height: 4),
          Text(what, style: TextStyle(fontSize: 14, color: c.t1)),
          const SizedBox(height: 6),
          Text(
            host.isOn
                ? l10n.everythingHereIsReplacedSourcesProfiles2
                : l10n.everythingHereIsReplacedSourcesProfiles,
            style: TextStyle(fontSize: 13, height: 1.4, color: c.warn),
          ),
        ],
      ),
    ),
    MenuRow(
      icon: const Icon(Icons.file_upload_outlined),
      label: l10n.restore,
      danger: true,
      onTap: () async {
        Navigator.of(sheet).pop();
        void say(String t) => messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(t)));
        try {
          await host.importState(snap);
          say(l10n.backupRestored);
          if (dataContext.mounted) Navigator.of(dataContext).maybePop();
        } catch (e) {
          say(l10n.notRestored('$e'));
        }
      },
    ),
    MenuRow(
      icon: const SizedBox(width: 20),
      label: l10n.cancel,
      onTap: () => Navigator.of(sheet).pop(),
    ),
  ]);
}

// ───────────────────────────── app updates ─────────────────────────────

String _updError(AppLocalizations l10n, UpdError? e) {
  switch (e?.code) {
    case 'network':
      return l10n.noUpdateServerAnsweredConnectTo;
    case 'badSignature':
      return l10n.theUpdateInformationCouldNotBe;
    case 'hash':
    case 'size':
      return l10n.theDownloadedFileIsDamaged;
    case 'disk':
      return l10n.cannotSaveTheFileCheckThe;
    case 'noAsset':
      return l10n.thereIsNoFileForThis;
    case 'schema':
      return l10n.thisVersionHasToBeDownloaded;
  }
  final m = e?.message ?? '';
  return m.isEmpty ? l10n.somethingWentWrong : m;
}

class _UpdatesBlock extends StatefulWidget {
  const _UpdatesBlock();

  @override
  State<_UpdatesBlock> createState() => _UpdatesBlockState();
}

class _UpdatesBlockState extends State<_UpdatesBlock> {
  /// Install was tapped and has not come back yet: the replacement can take seconds
  /// before the app closes, so the card says so instead of looking frozen.
  bool _installing = false;

  /// The release notes under the offer are collapsed until the caption is tapped.
  bool _notesOpen = false;

  Future<void> _install(CoreHost host) async {
    setState(() => _installing = true);
    try {
      await host.installUpdate();
    } catch (_) {}
    // success ends this process; a refusal (declined dialog, installer failure) lands here
    if (mounted) setState(() => _installing = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final host = CoreHostScope.of(context);
    final u = host.appUpdate;
    final gen = host.gen;
    final lang = AppSettingsScope.of(context).locale.languageCode;
    final o = u.offer;
    final p = u.phase;
    final at = u.checkedAt == null
        ? l10n.notCheckedYet
        : l10n.checkedAt(MaterialLocalizations.of(context).formatTimeOfDay(
              TimeOfDay.fromDateTime(
                DateTime.fromMillisecondsSinceEpoch(u.checkedAt!),
              ),
              alwaysUse24HourFormat: true,
            ));
    final unavailable = p == UpdPhase.unavailable;
    final hint = switch (p) {
      UpdPhase.unavailable => l10n.updateChecksAreNotAvailableIn,
      UpdPhase.idle => at,
      UpdPhase.checking => l10n.checking,
      UpdPhase.upToDate => '${l10n.youAreUpToDate} · $at',
      UpdPhase.available => l10n.aNewVersionIsOut,
      UpdPhase.downloading => l10n.downloading,
      UpdPhase.ready => l10n.readyToInstall,
      UpdPhase.failed =>
        u.checkFailed ? _updError(l10n, u.error) : l10n.downloadFailed2,
    };
    final version = host.appVersion;
    // the tap on Install here, or the install dialog [UpdateFlow] opened right after the download
    final installing = (_installing || host.updateInstalling) && host.canInstallUpdate;

    Widget? card;
    if (o != null && p != UpdPhase.checking) {
      final total = p == UpdPhase.downloading && u.total > 0
          ? u.total
          : (o.downloadSize > 0 ? o.downloadSize : u.total);
      final pct = total > 0 ? (u.received * 100 / total).round().clamp(0, 100) : 0;
      final notes = o.notesFor(lang);
      card = Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.accent.tint(.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.accent.tint(.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        l10n.updateAvailable(o.version),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: c.t1,
                        ),
                      ),
                      if (o.channel == 'beta')
                        ConnTag('beta', tone: TagTone.warn),
                    ],
                  ),
                ),
                Text(
                  fmtBytes(o.downloadSize),
                  style: monoText.copyWith(fontSize: 12, color: c.t2),
                ),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _notesOpen = !_notesOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.whatSNew.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: .6,
                            color: c.t3,
                          ),
                        ),
                      ),
                      AnimatedRotation(
                        turns: _notesOpen ? .5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.expand_more, size: 16, color: c.t3),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: _notesOpen
                    ? Text(
                        notes,
                        style: TextStyle(fontSize: 13, height: 1.4, color: c.t2),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
            const SizedBox(height: 10),
            if (p == UpdPhase.available)
              PrimaryButton(
                label: l10n.downloadInstall,
                onPressed: host.downloadUpdate,
              ),
            if (p == UpdPhase.downloading) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: total > 0 ? pct / 100 : null,
                  minHeight: 6,
                  color: c.accent,
                  backgroundColor: c.t1.tint(.08),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.downloadingOf(pct,
                        fmtBytes(u.received),
                        fmtBytes(total)),
                      style: TextStyle(fontSize: 12, color: c.t2),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: host.cancelUpdate,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        l10n.cancel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.accent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (p == UpdPhase.ready) ...[
              Text(
                l10n.downloadedAndChecked,
                style: TextStyle(fontSize: 13, color: c.active),
              ),
              const SizedBox(height: 8),
              if (host.canInstallUpdate)
                PrimaryButton(
                  label: l10n.install,
                  onPressed: installing ? null : () => _install(host),
                )
              else if (u.file != null)
                HintText(u.file!),
              if (installing) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.installingTheAppWillCloseAnd,
                        style: TextStyle(fontSize: 13, color: c.t2),
                      ),
                    ),
                  ],
                ),
              ],
            ],
            if (p == UpdPhase.failed && !u.checkFailed) ...[
              WarnNote(_updError(l10n, u.error)),
              PrimaryButton(label: l10n.retry, onPressed: host.downloadUpdate),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SetCaption(l10n.appUpdates),
        SetGroup(
          card: true,
          children: [
            SetRow(
              labelWidget: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${l10n.version} '),
                    TextSpan(
                      text: version.isEmpty ? '—' : version,
                      style: monoText.copyWith(fontSize: 14),
                    ),
                  ],
                ),
                style: TextStyle(fontSize: 15, color: c.t1),
              ),
              hintWidget: HintText(hint, warn: p == UpdPhase.failed),
              trailing: SecondaryButton(
                label: p == UpdPhase.failed && u.checkFailed
                    ? l10n.retry
                    : l10n.checkNow,
                onPressed: unavailable || u.busy ? null : host.checkUpdate,
              ),
            ),
            ?card,
            SetRow(
              label: l10n.autoCheck,
              hint: l10n.onLaunchAndOnceADay,
              trailing: MiniToggle(
                on: gen.updates,
                onChanged: (v) {
                  gen.updates = v;
                  host.changed();
                },
              ),
            ),
            SetRow(
              label: l10n.autoDownload,
              hint: l10n.downloadsWhatAutoCheckFindsInstalling,
              trailing: Opacity(
                opacity: gen.updates ? 1 : .4,
                child: SetValueButton(
                  text: _autoDownloadLabel(l10n, host),
                  onTap: gen.updates ? () => _pickAutoDownload(context, host) : null,
                ),
              ),
            ),
            SetRow(
              label: l10n.channel,
              hint: l10n.betaGetsNewVersionsEarlier,
              trailing: SetValueButton(
                text: gen.updChannel == 'beta' ? l10n.beta : l10n.release,
                onTap: () => _pickChannel(context, host),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Off / Wi-Fi only / Always. The desktop has no metered networks, so there «Wi-Fi only» would
  /// be «Always» under another name: the list is Off / Always and a stored `wifi` reads as Always.
  String _autoDownloadLabel(AppLocalizations l10n, CoreHost host) {
    final v = host.gen.updAutoDownload;
    if (v == 'off') return l10n.off;
    if (v == 'always' || !host.isAndroid) return l10n.always;
    return l10n.wiFiOnly;
  }

  void _pickAutoDownload(BuildContext context, CoreHost host) {
    final l10n = context.l10n;
    final gen = host.gen;
    final shown = gen.updAutoDownload == 'wifi' && !host.isAndroid
        ? 'always'
        : gen.updAutoDownload;
    showMenuSheet<void>(context, l10n.autoDownload, (sheet) {
      PickRow pick(String label, String v) => PickRow(
        label: label,
        selected: shown == v,
        onTap: () => closeThen(sheet, () {
          gen.updAutoDownload = v;
          host.changed();
        }),
      );
      return [
        pick(l10n.off, 'off'),
        if (host.isAndroid) pick(l10n.wiFiOnly, 'wifi'),
        pick(l10n.always, 'always'),
      ];
    });
  }

  void _pickChannel(BuildContext context, CoreHost host) {
    final l10n = context.l10n;
    final gen = host.gen;
    showMenuSheet<void>(context, l10n.updateChannel, (sheet) => [
      PickRow(
        label: l10n.release,
        sub: l10n.testedReleases,
        selected: gen.updChannel == 'stable',
        onTap: () => closeThen(sheet, () {
          gen.updChannel = 'stable';
          host.changed();
        }),
      ),
      PickRow(
        label: l10n.beta,
        sub: l10n.earlyBuildsNewThingsFirstMore,
        selected: gen.updChannel == 'beta',
        onTap: () => closeThen(sheet, () {
          gen.updChannel = 'beta';
          host.changed();
        }),
      ),
    ]);
  }
}
