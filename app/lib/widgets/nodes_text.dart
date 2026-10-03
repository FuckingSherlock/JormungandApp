import 'package:jormungand_core/jormungand_core.dart'
    show Catalog, Chain, NodeRef, OffReason, Profile;

import '../l10n/l10n.dart';

/// "Remnawave is off in Nodes" / "Frankfurt 01, Paris 02 are off in Nodes" (up to three named,
/// then "+N"): what to switch on for an entry with nothing left to connect through
/// (`reasonsText` of the core, translated).
String offReasonsText(
  AppLocalizations l10n,
  Catalog catalog,
  List<OffReason> reasons,
) {
  final names =
      reasons.take(3).map(catalog.reasonLabel).join(', ') +
      (reasons.length > 3 ? ' +${reasons.length - 3}' : '');
  return reasons.length > 1
      ? l10n.areOffInNodes(names)
      : l10n.isOffInNodes(names);
}

/// Why a profile draft cannot be saved (`profileProblem`, translated), or null.
String? profileWarn(AppLocalizations l10n, Catalog catalog, Profile d) {
  if (catalog.profileRefsOf(d.sources, d.nodes).isNotEmpty) return null;
  final offs = catalog.offReasons(
    catalog.profileRefsOf(d.sources, d.nodes, withOff: true),
  );
  return offs.isNotEmpty
      ? l10n.switchOnThereOrSelectAnother(
          offReasonsText(l10n, catalog, offs),
          offs.length > 1 ? 'one' : 'it',
        )
      : l10n.selectAtLeast1ServerA;
}

/// What stops a chain draft from being saved, one text per end (`chainProblems`, translated).
List<String> chainWarns(AppLocalizations l10n, Catalog catalog, Chain d) {
  String one(String name, List<NodeRef> refs, List<NodeRef> all, String? uid) {
    if (refs.isNotEmpty) return '';
    final off = catalog.offReasons(all);
    if (off.isNotEmpty) {
      return l10n.theSwitchItOnThereOr(
        name,
        offReasonsText(l10n, catalog, off),
      );
    }
    return catalog.unitRefs(uid).isNotEmpty
        ? l10n.selectAtLeast1ServerOf(name)
        : '';
  }

  return [
    one(
      l10n.entry2,
      catalog.chainEntryRefs(d),
      catalog.chainEntryRefs(d, withOff: true),
      d.inId,
    ),
    one(
      l10n.exit2,
      catalog.chainExitRefs(d),
      catalog.chainExitRefs(d, withOff: true),
      d.outId,
    ),
  ].where((s) => s.isNotEmpty).toList();
}

/// Small text helpers of the Nodes screen (mockup 30-nodes.js `timeAgo`, `shortAgo`, `fmtDate`).

/// "just now", "5 min ago", "3 h ago", "2 d ago" for an epoch-ms [ts] (`timeAgo`).
String timeAgo(AppLocalizations l10n, num ts, {int? nowMs}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final m = ((now - ts) / 60000).round();
  if (m < 1) return l10n.justNow;
  if (m < 60) return l10n.minAgo(m);
  final h = (m / 60).round();
  if (h < 24) return l10n.hAgo(h);
  return l10n.dAgoPlural((h / 24).round());
}

/// The same, as short as the meta line of a card wants: "now", "16m", "3h", "2d" (`shortAgo`).
String shortAgo(AppLocalizations l10n, num ts, {int? nowMs}) {
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final m = ((now - ts) / 60000).round();
  if (m < 1) return l10n.now2;
  if (m < 60) return l10n.m(m);
  final h = (m / 60).round();
  return h < 24 ? l10n.h(h) : l10n.d2((h / 24).round());
}

/// `2026-10-03` -> `03.10.2026` (`fmtDate`); anything that is not a date comes back as it was.
String fmtDate(Object? iso) {
  final s = '$iso';
  final p = s.split('-');
  if (p.length != 3) return s;
  final day = p[2].split(RegExp(r'[T ]')).first;
  return '$day.${p[1]}.${p[0]}';
}

/// A traffic figure in GB: whole numbers plain, else one decimal.
String fmtGb(num v) =>
    v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);
