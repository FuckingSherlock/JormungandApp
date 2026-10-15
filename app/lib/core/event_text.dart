import 'package:intl/intl.dart';
import 'package:jormungand_core/jormungand_core.dart'
    show
        AppRulesOps,
        Catalog,
        EventGroup,
        EventRecord,
        ruleTitle,
        serviceTitles,
        targetName;

import '../l10n/l10n.dart';
import '../widgets/app_mark.dart' show appDisplayName;
import 'format.dart' show fmtBytes;
import '../widgets/node_row.dart' show nodeProtoLabel;

/// The words of the Events journal (mockup 47-events.js `evDescribe`, `evValue`, `evWhyRows`): the
/// structured data of an event as sentences, ids resolved to names through the catalog (falling
/// back to the raw id). The core and the models decide what happened and what is shown; this
/// only says it in the user's language.
class EventWords {
  EventWords(this.l10n, this.catalog);

  final AppLocalizations l10n;
  final Catalog catalog;

  // ── labels ──

  String catLabel(String cat) => switch (cat) {
    'conn' => l10n.connection,
    'auto' => 'Auto',
    'site' => l10n.sites,
    'sub' => l10n.subscriptions,
    'rules' => l10n.rules,
    'dns' => 'DNS',
    'speed' => l10n.speedTest2,
    'core' => l10n.core,
    _ => cat,
  };

  String typeLabel(String cat, String type) => switch ('$cat/$type') {
    'conn/connected' => l10n.connected,
    'conn/disconnected' => l10n.disconnected,
    'conn/connectFailed' => l10n.connectFailed,
    'conn/lost' => l10n.connectionLost,
    'conn/restored' => l10n.connectionRestored,
    'conn/offline' => l10n.noNetwork,
    'conn/online' => l10n.networkBack,
    'auto/switched' => l10n.entryOrServerSwitched,
    'auto/fastest' => l10n.fastestMoved,
    'auto/unstable' => l10n.unstableEntry,
    'site/blocked' => l10n.siteDoesNotOpen,
    'site/unreachable' => l10n.siteDoesNotOpenOnAny,
    'sub/updated' => l10n.updated,
    'sub/failed' => l10n.updateFailed,
    'sub/removed' => l10n.serversRemoved,
    'sub/back' => l10n.serversBack,
    'sub/dead' => l10n.serversDoNotRespond,
    'sub/diverged' => l10n.subscriptionServersDiffer,
    'rules/fallback' => l10n.ruleTargetUnavailable,
    'rules/targetBack' => l10n.ruleTargetBack,
    'rules/ruleSetFailed' => l10n.ruleSetNotDownloaded,
    'rules/ruleSetUpdated' => l10n.ruleSetUpdated,
    'dns/switched' => l10n.dnsServerSwitched,
    'dns/failed' => l10n.dnsServerDoesNotAnswer,
    'dns/failedOnNode' => l10n.dnsServerDoesNotAnswerOn,
    'node/addressMissing' => l10n.serverAddressDoesNotExist,
    'speed/done' => l10n.speedTestFinished,
    'speed/failed' => l10n.speedTestFailed,
    'core/crashed' => l10n.singBoxStopped,
    'core/restarted' => l10n.singBoxStartedAgain,
    'core/restartFailed' => l10n.couldNotStartAgain,
    'core/tunNeedsAdmin' => l10n.tunNeedsAdministratorRights,
    'core/down' => l10n.vpnIsDown,
    'core/sysProxy' => l10n.systemProxy,
    'core/deprecated' => l10n.deprecatedSetting,
    'core/stateRestored' => l10n.savedDataRestored,
    'core/stateLost' => l10n.savedDataLost,
    'conn/failing' => l10n.connectionsAreFailing,
    'core/updateAvailable' => l10n.appUpdateAvailable,
    'core/updateFailed' => l10n.appUpdateFailed,
    'core/updateChannelEmpty' => l10n.noAppReleaseInTheChannel,
    'core/updateDownloaded' => l10n.appUpdateDownloaded,
    'core/updateDeltaFailed' => l10n.updatePatchFailed,
    'core/updateInstalled' => l10n.appUpdated,
    'core/tunTcpDead' => l10n.tcpDoesNotPassTheTunnel,
    'core/tunTcpBack' => l10n.tcpPassesTheTunnelAgain,
    _ => '$cat / $type',
  };

  // ── names ──

  String entry(Object? id) {
    if (id == null || '$id'.isEmpty) return '';
    return catalog.connectEntry('$id')?.name ?? '$id';
  }

  String server(Object? key) {
    if (key == null || '$key'.isEmpty) return '';
    return catalog.nodeOfKey('$key')?.name ?? '$key';
  }

  String source(Object? sid, [Object? name]) {
    final s = catalog.sourcesData['$sid']?.name;
    if (s != null && s.isNotEmpty) return s;
    if (name != null && '$name'.isNotEmpty) return '$name';
    return sid == null ? '' : '$sid';
  }

  /// A switch between two servers: when both show the same name (another protocol, or another
  /// address), the protocol is appended ("· HY2"), and when that is the same too, the address.
  (String, String) serverPair(Object? from, Object? to) {
    final a = server(from), b = server(to);
    if (from == null || to == null || '$from'.isEmpty || '$to'.isEmpty || a != b) {
      return (a, b);
    }
    final na = catalog.nodeOfKey('$from'), nb = catalog.nodeOfKey('$to');
    if (na == null || nb == null || '$from' == '$to') return (a, b);
    final pa = nodeProtoLabel(na), pb = nodeProtoLabel(nb);
    return pa != pb
        ? ('$a · $pa', '$b · $pb')
        : ('$a · ${na.address}:${na.port}', '$b · ${nb.address}:${nb.port}');
  }

  /// `sid::nid` is a server, anything else an entry.
  String nameOf(Object? k) => '$k'.contains('::') ? server(k) : entry(k);

  String dnsName(Object? id) {
    final n = catalog.dnsServers['$id']?.name;
    return n != null && n.isNotEmpty ? n : '$id';
  }

  String target(Object? t) => '$t' == 'proxy' ? l10n.mainFlow2 : targetName(catalog, '$t');

  String duration(num ms) {
    final s = (ms / 1000).round();
    if (s < 90) return l10n.s(s);
    if (s < 5400) return l10n.min((s / 60).round());
    return l10n.hMin(s ~/ 3600, ((s % 3600) / 60).round());
  }

  String stamp(int t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    return '${DateFormat.MMMd(l10n.localeName).format(d)} ${clock(t, seconds: true)}';
  }

  String clock(int t, {bool seconds = false}) {
    final d = DateTime.fromMillisecondsSinceEpoch(t);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}${seconds ? ':${two(d.second)}' : ''}';
  }

  String dayLabel(int t, int now) {
    final a = DateTime.fromMillisecondsSinceEpoch(now), b = DateTime.fromMillisecondsSinceEpoch(t);
    final diff = DateTime.utc(a.year, a.month, a.day).difference(DateTime.utc(b.year, b.month, b.day)).inDays;
    if (diff == 0) return l10n.today;
    if (diff == 1) return l10n.yesterday;
    return DateFormat.MMMEd(l10n.localeName).format(b);
  }

  // ── sentences ──

  String _reason(Map<String, dynamic> d) {
    final isRoute = d['route'] != null && '${d['route']}'.isNotEmpty;
    final (from, to) = isRoute
        ? serverPair(d['from'], d['to'])
        : (entry(d['from']), entry(d['to']));
    final reason = d['reason'];
    if (reason == 'failover') {
      final fails = d['fails'];
      return fails is num && fails > 0
          ? l10n.failedChecksPlural(fails, from)
          : l10n.failedItsChecks(from);
    }
    if (reason == 'back') return l10n.isBackReturnedToIt(to);
    if (reason == 'preferred') return l10n.isHigherInTheOrderMoved(to);
    if (reason == 'fastest') return l10n.isFaster(to);
    return reason == null ? '' : '$reason';
  }

  String _noRoute(Map<String, dynamic> d) =>
      d['retries'] == 'off' ? l10n.retriesThroughOtherRoutesAreOff : l10n.noOtherWorkingRouteToTry;

  String _destHost(String dest) {
    final i = dest.lastIndexOf(':');
    return i > 0 && !dest.contains(']') && dest.indexOf(':') == i ? dest.substring(0, i) : dest;
  }

  String host(Map<String, dynamic> d) {
    final h = d['host'];
    return h is String && h.isNotEmpty ? h : _destHost('${d['dest'] ?? ''}');
  }

  /// The rule (or, when no rule is involved, the app) of a fallback event: "Streaming and 2 more".
  String _who(Map<String, dynamic> d) {
    final base = _isRule(d) ? '${d['rule']}' : '${d['app']}';
    final more = d['more'];
    return more is num && more > 0 ? '$base ${l10n.and(l10n.more2(more))}' : base;
  }

  bool _isRule(Map<String, dynamic> d) => d['rule'] != null && '${d['rule']}'.isNotEmpty;

  String _fallbackText(Map<String, dynamic> d) {
    final to = '${d['to'] ?? ''}', who = _who(d), rule = _isRule(d);
    switch (to) {
      case 'block':
        return rule ? l10n.ruleBlockedWhileItIsDown(who) : l10n.appBlockedWhileItIsDown(who);
      case 'direct':
        return rule ? l10n.ruleGoesDirect(who) : l10n.appGoesDirect(who);
      case 'main':
        return rule ? l10n.ruleGoesThroughTheMainFlow(who) : l10n.appGoesThroughTheMainFlow(who);
    }
    if (to.contains(':')) {
      final t = targetName(catalog, to);
      return rule ? l10n.ruleGoesThrough(who, t) : l10n.appGoesThrough(who, t);
    }
    return '${rule ? l10n.rule : l10n.app} $who $to';
  }

  String _modeText(Object? m) => m == 'tun' ? 'TUN' : m == 'proxy' ? 'Proxy' : '';
  String _routeText(Object? r) => r == 'global' ? l10n.global : r == 'rules' ? l10n.byRules : '';

  String _lines(Iterable<String?> parts, [String sep = ' · ']) =>
      parts.where((s) => s != null && s.isNotEmpty).join(sep);

  /// `sub/diverged` `why` (the core's `copyFreshness` codes) in words; null for an unknown code.
  String? _divergedWhy(Object? why) => switch (why) {
    'newer: lastModified' => l10n.itIsTheNewerOneBy,
    'newer: age' => l10n.itIsTheNewerOneBy2,
    'unknown' => l10n.theHeadersCannotTellWhichCopy,
    _ => null,
  };

  /// The line of the row: title and detail.
  ({String title, String detail}) describe(EventRecord e) {
    final d = e.data;
    (String, String) r(String a, [String b = '']) => (a, b);
    final (title, detail) = switch ((e.cat, e.type)) {
      ('user', 'connect') => r(l10n.youConnected, entry(d['entry'])),
      ('user', 'disconnect') => r(l10n.youDisconnected),
      ('user', 'pin') => d['server'] != null && '${d['server']}'.isNotEmpty
          ? r(l10n.youPinned2(server(d['server'])), entry(d['entry']))
          : r(l10n.youUnpinnedTheServer, entry(d['entry'])),
      ('user', 'mode') => r(d['value'] == 'tun' ? l10n.youSwitchedToTunMode : l10n.youSwitchedToProxyMode),
      ('user', 'route') => r(d['value'] == 'global' ? l10n.youSwitchedToGlobal : l10n.youSwitchedToByRules),
      ('user', 'sysProxy') => r(d['on'] == true ? l10n.youTurnedTheSystemProxyOn : l10n.youTurnedTheSystemProxyOff),
      ('conn', 'connected') => r(
        d['entry'] != null && '${d['entry']}'.isNotEmpty ? l10n.connected2(entry(d['entry'])) : l10n.connected,
        _lines([
          d['server'] != null ? server(d['server']) : null,
          _modeText(d['mode']),
          _routeText(d['route']),
        ]),
      ),
      ('conn', 'disconnected') => r(
        l10n.disconnected,
        d['by'] == 'error' ? '${d['reason'] ?? l10n.theConnectionDropped}' : l10n.youDisconnected,
      ),
      ('conn', 'connectFailed') => r(l10n.couldNotConnect, '${d['reason'] ?? ''}'),
      ('conn', 'lost') => r(l10n.connectionLost, l10n.noRouteAnswersWaitingForThe),
      ('conn', 'restored') => r(l10n.connectionRestored, d['downMs'] is num ? l10n.downFor2(duration(d['downMs'] as num)) : ''),
      ('conn', 'offline') => r(l10n.noNetwork, l10n.theSystemReportsNoConnection),
      ('conn', 'online') => r(l10n.networkIsBack, d['downMs'] is num ? l10n.downFor2(duration(d['downMs'] as num)) : ''),
      ('auto', 'switched') => () {
        final (f, t) = serverPair(d['from'], d['to']);
        final hasRoute = d['route'] != null && '${d['route']}'.isNotEmpty;
        return r(
          hasRoute
              ? 'Auto: ${entry(d['route'])} — $f → $t'
              : 'Auto: ${entry(d['from'])} → ${entry(d['to'])}',
          _reason(d),
        );
      }(),
      ('auto', 'fastest') => () {
        final (f, t) = serverPair(d['from'], d['to']);
        return r('Fastest: ${entry(d['route'])} — $f → $t', l10n.isNowTheFastest(t));
      }(),
      ('auto', 'unstable') => r(
        l10n.isUnstable2(entry(d['id'])),
        l10n.droppedBackToItAfterMin(
          d['strikes'] is num ? d['strikes'] as num : 0,
          d['holdMs'] is num ? ((d['holdMs'] as num) / 60000).round().clamp(1, 1 << 30) : 1,
        ),
      ),
      ('node', 'addressMissing') => r(() {
        final more = d['nodes'] is num ? (d['nodes'] as num) - 1 : 0;
        return more > 0
            ? l10n.serverAddressOfAndMoreDoes('${d['host'] ?? ''}', '${d['node'] ?? ''}', more)
            : l10n.serverAddressOfDoesNotExist('${d['host'] ?? ''}', '${d['node'] ?? ''}');
      }()),
      ('site', 'blocked') => r(
        l10n.doesNotOpen(host(d)),
        _lines([
          _entryMark('⚠️', d['entry'] ?? d['route'], d['server']),
          d['via'] != null && '${d['via']}'.isNotEmpty ? _entryMark('✅', d['via'], d['viaServer']) : null,
          whyText(d),
        ], '   '),
      ),
      ('site', 'unreachable') => () {
        final tried = d['tried'] is List ? d['tried'] as List : const [];
        // down everywhere: the site is down, our routes are no part of it
        final routes = !downEverywhere(d);
        return r(
          l10n.doesNotOpen(host(d)),
          _lines([
            if (routes) ...[
              _entryMark('⚠️', d['entry'] ?? d['route'], d['server']),
              for (final x in tried)
                if (x is Map) _entryMark('⚠️', x['entry'], x['server']),
              if (tried.isEmpty) _noRoute(d),
            ],
            whyText(d),
            checkText(d),
          ], '   '),
        );
      }(),
      ('sub', 'updated') => r(
        l10n.updated3(source(d['source'], d['name'])),
        _lines([
          d['total'] is num ? l10n.serversPlural(d['total'] as num) : null,
          d['added'] is num && (d['added'] as num) > 0 ? l10n.newText(d['added'] as num) : null,
          d['removed'] is num && (d['removed'] as num) > 0 ? l10n.removed2(d['removed'] as num) : null,
        ]),
      ),
      ('sub', 'failed') => r(l10n.updateFailed2(source(d['source'], d['name'])), '${d['error'] ?? ''}'),
      ('sub', 'removed') => r(
        l10n.theProviderRemovedServersPlural(d['count'] is num ? d['count'] as num : 0, source(d['source'], d['name'])),
        l10n.seeUnavailableInNodesTheirSettings,
      ),
      ('sub', 'back') => r(
        l10n.serversAreBackPlural(d['count'] is num ? d['count'] as num : 0, source(d['source'], d['name'])),
        l10n.previousSettingsRestored,
      ),
      ('sub', 'dead') => r(l10n.itsServersDoNotRespond(source(d['source'], d['name'])), l10n.contactTheSubscriptionProviderSSupport),
      ('sub', 'diverged') => r(
        l10n.theDirectAndTheVpnCopies(source(d['source'], d['name'])),
        _lines([
          switch (d['used']) {
            'direct' => l10n.theDirectCopyIsUsed,
            'merged' => l10n.copiesMergedBothListsAreUsed,
            _ => l10n.theVpnCopyIsUsed,
          },
          _divergedWhy(d['why']),
        ], ' '),
      ),
      ('rules', 'ruleSetFailed') => r(
        l10n.ruleSetNotDownloaded2('${d['tag']}'),
        _lines([d['error'] != null ? '${d['error']}' : null, l10n.theLastCopyIsUsed], ' — '),
      ),
      ('rules', 'ruleSetUpdated') => r(l10n.ruleSetUpdated2('${d['tag']}')),
      ('rules', 'fallback') => r(l10n.doesNotAnswer(target(d['target'])), _fallbackText(d)),
      ('rules', 'targetBack') => r(
        l10n.answersAgain(target(d['target'])),
        _isRule(d) ? l10n.ruleBackThroughIt(_who(d)) : l10n.appBackThroughIt(_who(d)),
      ),
      ('dns', 'switched') => r(
        l10n.dns(dnsName(d['from']), dnsName(d['to'])),
        d['reason'] == 'failover'
            ? l10n.doesNotAnswer(dnsName(d['from']))
            : d['reason'] == 'back'
            ? l10n.answersAgainReturnedToIt(dnsName(d['to']))
            : l10n.switchAutomaticallyIsOffTheFirst,
      ),
      ('dns', 'failed') => r(l10n.doesNotAnswer(dnsName(d['server']))),
      ('dns', 'failedOnNode') => r(
        l10n.doesNotAnswer(dnsName(d['server'])),
        l10n.doesNotAnswerThroughItAnswers(server(d['node']), server(d['via'])),
      ),
      ('speed', 'done') => () {
        String mbps(Object? bps) {
          final v = ((bps as num?) ?? 0) / 1e6;
          return v >= 100 ? '${v.round()}' : v.toStringAsFixed(1);
        }

        final lat = (d['latency'] as num?)?.toInt() ?? 0;
        return r(
          l10n.speedTestMbps(mbps(d['down']), mbps(d['up'])),
          lat > 0 ? l10n.latencyMs('$lat') : '',
        );
      }(),
      ('speed', 'failed') => r(l10n.speedTestFailed, '${d['error'] ?? ''}'),
      ('core', 'crashed') => r(
        l10n.singBoxStopped,
        d['code'] is num ? l10n.exitCodeStartingItAgain(d['code'] as num) : l10n.startingItAgain,
      ),
      ('core', 'restarted') => r(
        l10n.singBoxStartedAgain,
        _lines([
          d['attempt'] is num ? l10n.attempt2(d['attempt'] as num) : null,
          d['downMs'] is num ? l10n.wasDown2(duration(d['downMs'] as num)) : null,
        ]),
      ),
      ('core', 'down') => r(
        l10n.vpnIsDown,
        d['proxy'] == 'kept' ? l10n.internetIsBlockedTheSystemProxy : l10n.trafficGoesDirectStillTrying,
      ),
      ('core', 'tunNeedsAdmin') => r(l10n.tunNeedsAdministratorRights, l10n.runTheAppAsAdministratorOr),
      ('core', 'restartFailed') => r(
        l10n.singBoxCouldNotStartAgain,
        _lines([
          d['attempt'] is num ? l10n.attempt2(d['attempt'] as num) : null,
          d['error'] != null ? '${d['error']}' : null,
        ]),
      ),
      ('core', 'sysProxy') => d['by'] == 'user'
          ? r(d['on'] == true ? l10n.youSetTheSystemProxy : l10n.youRemovedTheSystemProxy, l10n.fromTheVpnIsDownKill)
          : r(
              d['error'] != null && '${d['error']}'.isNotEmpty
                  ? (d['on'] == true ? l10n.systemProxyCouldNotBeSet : l10n.systemProxyCouldNotBeRestored)
                  : (d['on'] == true ? l10n.systemProxyOn : l10n.systemProxyOff),
              '${d['error'] ?? ''}',
            ),
      ('core', 'deprecated') => r(l10n.singBoxADeprecatedSetting, '${d['text'] ?? ''}'),
      ('core', 'stateRestored') => r(
        l10n.savedDataWasDamagedRestoredFrom,
        d['savedAt'] is num ? l10n.backupFromLaterChangesAreLost(stamp((d['savedAt'] as num).toInt())) : l10n.laterChangesAreLost,
      ),
      ('core', 'stateLost') => r(l10n.savedDataWasDamagedAndCould, l10n.startingEmptyTheDamagedFileIs),
      ('conn', 'failing') => () {
        final port = d['port'] is num && (d['port'] as num) > 0 ? ':${d['port']}' : '';
        final more = d['more'];
        final dest = '${d['host'] ?? ''}$port${more is num && more > 0 ? ' ${l10n.and(l10n.more2(more))}' : ''}';
        final who = appName(d);
        final win = d['windowMs'] is num ? ((d['windowMs'] as num) / 1000).round() : 60;
        final out = _outbound(d);
        return r(
          who.isEmpty ? l10n.connectionsToAreFailing(dest) : l10n.connectionsToAreFailing2(who, dest),
          _lines([
            _failKind(d['kind']),
            d['count'] is num ? l10n.failuresInS(d['count'] as num, win) : null,
            out.isEmpty ? null : l10n.through(out),
          ]),
        );
      }(),
      ('core', 'tunTcpDead') => () {
        final apps = d['apps'] is List ? [for (final a in d['apps'] as List) _appOrProcess('$a')] : <String>[];
        final stack = '${d['stack'] ?? ''}';
        return r(
          l10n.tcpDoesNotPassTheTunnel,
          apps.isEmpty
              ? l10n.stackTcpOfAppsIsNot(stack)
              : l10n.stackTcpOfIsNotReaching(stack, apps.join(', ')),
        );
      }(),
      ('core', 'tunTcpBack') => r(
        l10n.tcpPassesTheTunnelAgain,
        l10n.stackBackAfterWithoutTcp('${d['stack'] ?? ''}', d['deadMs'] is num ? duration(d['deadMs'] as num) : ''),
      ),
      ('core', 'updateAvailable') => r(
        l10n.versionIsAvailable('${d['version'] ?? ''}'),
        _lines([
          '${d['channel'] ?? ''}',
          d['forced'] == true ? l10n.requiredUpdate : null,
          _updateVia(d['via']),
        ]),
      ),
      ('core', 'updateFailed') => r(
        switch (d['stage']) {
          'check' => l10n.couldNotCheckForAnUpdate,
          'verify' => l10n.theDownloadedUpdateFailedVerification,
          'install' => l10n.theUpdateWasNotInstalled,
          _ => l10n.couldNotDownloadTheUpdate,
        },
        '${d['error'] ?? ''}',
      ),
      ('core', 'updateChannelEmpty') => r(
        l10n.noReleaseInTheChannel('${d['channel'] ?? ''}'),
        d['attempts'] is List ? l10n.feedsAsked((d['attempts'] as List).length) : '',
      ),
      ('core', 'updateDownloaded') => r(
        l10n.versionDownloaded('${d['version'] ?? ''}'),
        _lines([
          d['delta'] == true && d['downloaded'] is num && d['size'] is num
              ? l10n.patchInsteadOf(fmtBytes(d['downloaded'] as num), fmtBytes(d['size'] as num))
              : d['size'] is num
              ? fmtBytes(d['size'] as num)
              : null,
          _updateVia(d['via']),
        ]),
      ),
      ('core', 'updateDeltaFailed') => r(l10n.thePatchDidNotDownloadThe, '${d['error'] ?? ''}'),
      ('core', 'updateInstalled') => r(l10n.updatedTo('${d['to'] ?? ''}'), l10n.was('${d['from'] ?? ''}')),
      _ => r('${e.cat} / ${e.type}'),
    };
    return (title: title, detail: detail);
  }

  /// How a request of `conn/failing` ended (`ConnKind.name`).
  String _failKind(Object? k) => switch (k) {
    'refused' => l10n.refusedByTheFarSide,
    'reset' => l10n.droppedAfterConnecting,
    'timeout' => l10n.noAnswerInTime,
    'stalled' => l10n.sentNothingCameBack,
    'instantRefusal' => l10n.closedAtOnce,
    'dnsFail' => l10n.theNameDidNotResolve,
    _ => k == null ? '' : '$k',
  };

  /// The route a failing connection went through (`route`: `proxy` / `direct` / `block` / a tag).
  String _outbound(Map<String, dynamic> d) {
    final r = '${d['route'] ?? ''}';
    if (r.isEmpty) return '${d['outbound'] ?? ''}';
    return switch (r) {
      'proxy' => l10n.mainFlow2,
      'direct' => 'Direct',
      'block' => 'Block',
      _ => entry(r),
    };
  }

  /// An app of `tunTcpDead` as sing-box named it: a package (Android) or a process path.
  String _appOrProcess(String a) {
    if (a.isEmpty || a.contains('\\') || a.contains('/')) {
      return a.split(RegExp(r'[\\/]')).last;
    }
    return appDisplayName(l10n, catalog, a);
  }

  /// `data.via` of an update event: the route the feed was reached by.
  String? _updateVia(Object? v) => switch (v) {
    'direct' => l10n.through('Direct'),
    'tunnel' => l10n.through(l10n.vpn),
    _ => null,
  };

  String _entryMark(String mark, Object? id, Object? srv) {
    if (id == null || '$id'.isEmpty) return '';
    final s = srv != null && '$srv'.isNotEmpty ? ' (${server(srv)})' : '';
    return '$mark ${entry(id)}$s';
  }

  /// One line, for a notification and the export.
  String text(EventRecord e) {
    final d = describe(e);
    return d.detail.isEmpty ? d.title : '${d.title} — ${d.detail}';
  }

  /// What the search of the Events filter looks in: the sentence, the values of the data, and the
  /// words of the type and the category ("Unstable entry", "Subscriptions") so that a type is found
  /// by the name the filter sheet shows.
  String searchText(EventRecord e) =>
      '${text(e)} ${typeLabel(e.cat, e.type)} ${catLabel(e.cat)} ${e.cat} ${e.type} ${e.data.values.join(' ')}';

  // ── why: the rule that decided a request ──

  String processName(Map<String, dynamic> d) {
    final p = d['process'];
    if (p is Map) return '${p['name'] ?? p['path'] ?? ''}';
    return '';
  }

  /// The Android package of the app that made the request (event data `app`; '' = none).
  String eventApp(Map<String, dynamic> d) => d['app'] is String ? d['app'] as String : '';

  /// The name of that app for a line: the installed-apps name, the package id when unknown, «Android
  /// System» for the system; on desktop the file name of the process ('' = unknown).
  String appName(Map<String, dynamic> d) {
    final a = eventApp(d);
    return a.isNotEmpty ? appDisplayName(l10n, catalog, a) : processName(d);
  }

  Map? _ruleOf(Map<String, dynamic> d) => d['rule'] is Map ? d['rule'] as Map : null;

  /// What routing decided and where to look at it; null = an event without it.
  WhyRow? why(Map<String, dynamic> d) {
    final r = _ruleOf(d);
    if (r == null) return null;
    final id = '${r['id'] ?? ''}';
    final name = '${r['name'] ?? ''}';
    switch ('${r['kind']}') {
      case 'final':
        return WhyRow(l10n.rule, l10n.noneMainFlow, go: WhyGo.route);
      case 'user':
        final x = catalog.rulesData[id];
        return WhyRow(l10n.rule, x != null ? ruleTitle(x) : (name.isNotEmpty ? name : id), go: x != null ? WhyGo.user : WhyGo.none, id: id);
      case 'app':
        final known = catalog.appRules.containsKey(id) || catalog.appInfo?.call(id) != null;
        return WhyRow(l10n.app, known ? catalog.appLabel(id) : (name.isNotEmpty ? name : id), go: known ? WhyGo.app : WhyGo.none, id: id, icon: eventApp(d) == id ? id : '');
      case 'service':
        return WhyRow(l10n.service, serviceTitles[id] ?? (name.isNotEmpty ? name : id), go: WhyGo.rules, id: id, at: 'svc:$id');
      case 'quick':
        return WhyRow(l10n.rule, name.isNotEmpty ? name : id, go: WhyGo.rules, id: id, at: 'quick:$id');
      case 'system' when id == 'private':
        return WhyRow(l10n.rule, name.isNotEmpty ? name : id, go: WhyGo.rules, id: id, at: 'lan');
      default:
        final t = name.isNotEmpty ? name : '${r['text'] ?? r['kind'] ?? ''}';
        return WhyRow(l10n.rule, t);
    }
  }

  /// The line of the notification and the export.
  String whyText(Map<String, dynamic> d) {
    final w = why(d), p = appName(d);
    return _lines([
      if (w != null) w.go == WhyGo.route ? l10n.noRuleMainFlow : '${w.key} ${w.name}',
      if (p.isNotEmpty) '${l10n.app} $p',
    ], '   ');
  }

  /// The package of the event's app: `data.app` on Android, else the process among the apps with their
  /// own route ('' = not known).
  String appPkg(Map<String, dynamic> d) {
    if (eventApp(d).isNotEmpty) return eventApp(d); // Android: the package itself
    final p = d['process'];
    if (p is! Map) return '';
    final n = '${p['name'] ?? ''}'.toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
    if (n.isEmpty) return '';
    for (final pkg in catalog.appRules.keys) {
      if (pkg.toLowerCase() == n || pkg.split('.').last.toLowerCase() == n || catalog.appLabel(pkg).toLowerCase() == n) {
        return pkg;
      }
    }
    return '';
  }

  String _half(String act, String tgt) => switch (act) {
    'proxy' => tgt.isNotEmpty ? '→ ${targetName(catalog, tgt)}' : 'Proxy',
    'direct' => 'Direct',
    'block' => 'Block',
    _ => 'Default',
  };

  String appActText(String pkg) {
    final a = catalog.appRules[pkg];
    if (a == null) return '';
    if (!a.split) return _half(a.tcp.act, a.tcp.target);
    return 'TCP ${_half(a.tcp.act, a.tcp.target)} · UDP ${_half(a.udp.act, a.udp.target)}';
  }

  bool _appHasOwn(String pkg) {
    final a = catalog.appRules[pkg];
    return a != null && a.halves.any((h) => h.$2.act != 'default');
  }

  /// Where a rule (the `data.rule` shape) leads now; '' = not known. With today's settings.
  String ruleTo(Map r) {
    final id = '${r['id'] ?? ''}';
    switch ('${r['kind']}') {
      case 'user':
        final x = catalog.rulesData[id];
        if (x == null) return '';
        if (x.action == 'direct') return 'Direct';
        if (x.action == 'block') return 'Block';
        return x.target.isNotEmpty ? '→ ${targetName(catalog, x.target)}' : 'Proxy';
      case 'app':
        return appActText(id);
      case 'service':
        final v = catalog.quickCfg.services[id];
        return v == 'vpn' ? l10n.vpn : v == 'direct' ? 'Direct' : '';
      case 'quick':
        return id == 'ads' ? 'Block' : id == 'region' ? 'Direct' : '';
      case 'system':
        return id == 'private' ? 'Direct' : '';
      case 'final':
        return switch (catalog.quickCfg.finalAction) { 'proxy' => 'Proxy', 'direct' => 'Direct', 'block' => 'Block', _ => '' };
    }
    return '';
  }

  /// The rows of the "why" block: what routing applied (with where it leads now) and the app that
  /// sent the request. With an app route that the matched rule overrode, the applied row says so.
  List<WhyRow> whyRows(Map<String, dynamic> d) {
    final rows = <WhyRow>[];
    final w = why(d), proc = appName(d), pkg = appPkg(d);
    final r = _ruleOf(d);
    final byApp = r != null && r['kind'] == 'app';
    if (w != null) rows.add(w.withTo(ruleTo(r!)));
    if (proc.isNotEmpty && !byApp) {
      final own = pkg.isNotEmpty && _appHasOwn(pkg);
      rows.add(WhyRow(
        l10n.app,
        pkg.isNotEmpty ? appDisplayName(l10n, catalog, pkg) : proc,
        go: pkg.isNotEmpty ? WhyGo.app : WhyGo.none,
        id: pkg,
        icon: eventApp(d),
        to: own ? appActText(pkg) : '',
        mark: own ? (r != null && r['kind'] == 'final' ? l10n.notApplied : l10n.overriddenByRule) : null,
        dim: own,
      ));
    }
    if (w != null && rows.any((x) => x.dim)) rows[0] = rows[0].withMark(l10n.applied);
    return rows;
  }

  // ── fields of an opened row ──

  String fieldLabel(String k, [EventRecord? e]) => switch (k) {
    'count' when e?.cat == 'conn' => l10n.failures,
    'code' when e?.cat == 'core' => l10n.code,
    'via' when e?.cat == 'core' => l10n.route,
    'directNodes' when e?.cat == 'sub' => l10n.serversDirect,
    'tunnelNodes' when e?.cat == 'sub' => l10n.serversViaVpn,
    'onlyDirect' when e?.cat == 'sub' => l10n.onlyDirect,
    'onlyTunnel' when e?.cat == 'sub' => l10n.onlyViaVpn,
    'directStatus' when e?.cat == 'sub' => l10n.directStatus,
    'tunnelStatus' when e?.cat == 'sub' => l10n.vpnStatus,
    'directMs' when e?.cat == 'sub' => l10n.directTime,
    'tunnelMs' when e?.cat == 'sub' => l10n.vpnTime,
    'directPath' when e?.cat == 'sub' => l10n.directPath,
    'tunnelPath' when e?.cat == 'sub' => l10n.vpnPath,
    'why' when e?.cat == 'sub' => l10n.reason,
    'directFresh' when e?.cat == 'sub' => l10n.directCopyHeaders,
    'tunnelFresh' when e?.cat == 'sub' => l10n.vpnCopyHeaders,
    'used' when e?.cat == 'sub' => l10n.copyUsed,
    'kind' => l10n.failure,
    'stage' => l10n.stage,
    'version' => l10n.version,
    'build' => l10n.build,
    'channel' => l10n.channel,
    'forced' => l10n.requiredText,
    'size' => l10n.size,
    'delta' => l10n.patch,
    'downloaded' => l10n.downloaded,
    'outbound' => l10n.outbound,
    'port' => l10n.port,
    'stack' => l10n.stack,
    'apps' => l10n.apps,
    'synSeen' => l10n.connectionsSeen,
    'accepted' => l10n.accepted,
    'windowMs' => l10n.window,
    'deadMs' => l10n.downFor,
    'attempts' => l10n.attempts,
    'entry' || 'id' => l10n.entry,
    'server' => l10n.server,
    'mode' => l10n.mode,
    'route' => l10n.route,
    'from' => l10n.from,
    'to' => l10n.to,
    'reason' => l10n.reason,
    'by' => l10n.by,
    'host' => l10n.site,
    'dest' => l10n.address,
    'via' => l10n.opensVia,
    'source' => l10n.subscription,
    'name' => l10n.name,
    'added' => l10n.newServers,
    'removed' => l10n.removed,
    'total' || 'count' => l10n.servers,
    'error' => l10n.error,
    'tag' => l10n.ruleSet,
    'url' => 'URL',
    'code' => l10n.exitCode,
    'rule' => l10n.rule,
    'app' || 'process' => l10n.app,
    'target' => l10n.target,
    'more' => l10n.moreRulesAndApps,
    'tried' => l10n.alsoTried,
    'retries' => l10n.retriesThroughOtherRoutes,
    'savedAt' => l10n.backupSaved,
    'kept' => l10n.damagedFileKeptAs,
    'attempt' => l10n.attempt,
    'downMs' => l10n.downFor,
    'holdMs' => l10n.waits,
    'strikes' => l10n.drops,
    'fails' => l10n.failedChecks,
    'on' => l10n.state,
    'action' => l10n.action,
    'value' => l10n.value,
    'text' => l10n.text,
    _ => k.isEmpty ? k : k[0].toUpperCase() + k.substring(1),
  };

  String fieldValue(String k, Object? v, EventRecord e) {
    if (e.cat == 'dns') {
      if (k == 'from' || k == 'to') return dnsName(v);
      if (e.type == 'failedOnNode' && (k == 'node' || k == 'via')) return server(v);
      if (k == 'reason') {
        return switch (v) {
          'failover' => l10n.itStoppedAnswering,
          'back' => l10n.aHigherServerAnswersAgain,
          'off' => l10n.switchAutomaticallyTurnedOff,
          _ => '$v',
        };
      }
    }
    if (e.cat == 'rules') {
      if (k == 'target') return target(v);
      if (k == 'to') return switch (v) { 'block' => 'Block', 'direct' => 'Direct', 'main' => l10n.mainFlow2, _ => '$v' };
    }
    if (e.cat == 'core' && (e.type == 'stateRestored' || e.type == 'stateLost')) {
      if (k == 'from') return switch (v) { 'bak' => l10n.lastBackup, 'bak2' => l10n.olderBackup, _ => '$v' };
      if (k == 'reason') {
        return switch (v) {
          'nul' => l10n.theFileWasEmptyAPower,
          'empty' => l10n.theFileWasEmpty,
          'invalid' || 'notObject' => l10n.theFileWasNotReadable,
          'unreadable' => l10n.theFileCouldNotBeOpened,
          'missing' => l10n.theFileWasMissing,
          _ => '$v',
        };
      }
      if (k == 'savedAt' && v is num) return stamp(v.toInt());
    }
    if (e.cat == 'sub' && e.type == 'diverged') {
      if ((k == 'directMs' || k == 'tunnelMs') && v is num) return duration(v);
      if (k == 'used') return v == 'direct' ? l10n.directCopy : (v == 'merged' ? l10n.bothCopiesMerged : l10n.vpnCopy);
      if (k == 'why') return _divergedWhy(v) ?? '$v';
      if ((k == 'directFresh' || k == 'tunnelFresh') && v is Map) {
        final lines = [
          if (v['lastModified'] != null) l10n.lastModified('${v['lastModified']}'),
          if (v['origin'] != null) l10n.leftTheOrigin('${v['origin']}'),
        ];
        return lines.isEmpty ? l10n.noFreshnessHeaders : lines.join('\n');
      }
      if ((k == 'onlyDirect' || k == 'onlyTunnel') && v is List) {
        final total = e.data[k == 'onlyDirect' ? 'onlyDirectCount' : 'onlyTunnelCount'];
        final n = total is num ? total.toInt() : v.length;
        return [
          '$n',
          ...v.map((x) => '$x'),
          if (n > v.length) l10n.andMore2(n - v.length),
        ].join('\n');
      }
    }
    if (k == 'tried' && v is List) {
      if (v.isEmpty) return _noRoute(e.data);
      return v
          .map((x) => x is Map ? entry(x['entry']) + (x['server'] != null && '${x['server']}'.isNotEmpty ? ' (${server(x['server'])})' : '') : '$x')
          .join(', ');
    }
    if (k == 'rule' && v is Map) {
      final w = why({'rule': v});
      if (w == null) return '$v';
      return w.key == l10n.rule ? w.name : '${w.key} · ${w.name}';
    }
    if (k == 'app' && e.cat == 'site' && v is String && v.isNotEmpty) {
      final n = appDisplayName(l10n, catalog, v);
      return n == v ? v : '$n ($v)';
    }
    if (k == 'process' && v is Map) {
      final name = '${v['name'] ?? ''}', path = '${v['path'] ?? ''}';
      return path.isNotEmpty && path != name ? '$name ($path)' : name;
    }
    if (k == 'kind' && e.cat == 'conn') return _failKind(v);
    if (k == 'via' && e.cat == 'core') return v == 'tunnel' ? l10n.vpn : v == 'direct' ? 'Direct' : '$v';
    if (k == 'stage' && e.cat == 'core') {
      return switch (v) {
        'check' => l10n.couldNotCheckForAnUpdate,
        'verify' => l10n.theDownloadedUpdateFailedVerification,
        'install' => l10n.theUpdateWasNotInstalled,
        _ => l10n.couldNotDownloadTheUpdate,
      };
    }
    if ((k == 'size' || k == 'downloaded') && v is num) return fmtBytes(v);
    if (k == 'apps' && v is List) return v.map((x) => _appOrProcess('$x')).join(', ');
    if (k == 'attempts' && v is List) {
      return v.map((x) => x is Map ? "${x['url'] ?? ''} — ${x['error'] ?? x['code'] ?? ''}" : '$x').join('\n');
    }
    if (k == 'retries') return v == 'off' ? l10n.off : '$v';
    if (v is bool) return k == 'on' ? (v ? l10n.onText : l10n.off) : (v ? l10n.yes : l10n.no);
    if ((k == 'downMs' || k == 'holdMs' || k == 'windowMs' || k == 'deadMs') && v is num) return duration(v);
    if (k == 'mode') return _modeText(v).isNotEmpty ? _modeText(v) : '$v';
    if (k == 'route' && (v == 'global' || v == 'rules')) return _routeText(v);
    if (k == 'by') return v == 'user' ? l10n.you : l10n.anError;
    if (k == 'source') return source(v);
    if ((k == 'from' || k == 'to') && e.cat == 'auto' && e.data['route'] != null && '${e.data['route']}'.isNotEmpty && v is String) {
      final (a, b) = serverPair(e.data['from'], e.data['to']);
      return k == 'from' ? a : b;
    }
    if (const ['entry', 'server', 'route', 'from', 'to', 'via', 'id'].contains(k) && v is String) return nameOf(v);
    return v is Map || v is List ? '$v' : '$v';
  }

  /// Every field of the event in words: time(s), the event's name, then its data.
  List<(String, String)> fields(EventGroup g) {
    final e = g.ev;
    final times = [for (final x in g.items) ...x.occurrences];
    final out = <(String, String)>[
      if (times.length > 1)
        (l10n.times, times.map((t) => clock(t, seconds: true)).join(', '))
      else
        (l10n.time, stamp(e.at)),
      (l10n.event, '${e.cat} / ${e.type}${e.own ? ' ${l10n.yours}' : ''}'),
    ];
    final noRoutes = e.cat == 'site' && e.type == 'unreachable' && downEverywhere(e.data);
    for (final x in e.data.entries) {
      final v = x.value;
      if (v == null || (v is String && v.isEmpty)) continue;
      if (noRoutes && const ['entry', 'server', 'tried', 'retries'].contains(x.key)) continue; // down everywhere: not our routes
      if (x.key == 'source' && e.cat == 'conn') continue; // 'closed': where the core saw it, not a subscription
      if (x.key == 'repeat') continue; // shown as the row's times
      if (e.cat == 'sub' && (x.key == 'onlyDirectCount' || x.key == 'onlyTunnelCount')) continue; // folded into the list's value
      if (x.key == 'check' && v is Map) {
        out.addAll(checkFields(v));
        continue;
      }
      out.add((fieldLabel(x.key, e), fieldValue(x.key, v, e)));
    }
    return out;
  }

  /// The external checker's verdict on a site event (`data.check`, docs/connect-model.md → «Внешний
  /// чекер»): one sentence, or null when there is nothing to say (the check is off, or the event has none).
  String? checkText(Map<String, dynamic> d) {
    final c = d['check'];
    if (c is! Map) return null;
    return switch (c['state']) {
      'opens' => l10n.opensElsewhereNotThroughYourRoutes,
      'down' => l10n.downEverywhereCheckHost,
      'pending' => l10n.askingCheckHost,
      'failed' => l10n.theCheckerDidNotAnswer,
      _ => null,
    };
  }

  /// The external checker could not open the site either (`data.check.state == 'down'` of a `site/unreachable`): the
  /// site is down for everyone, so the event shows none of our routes (entry, server, the routes tried, the retries
  /// note); they stay in the data, the trail and the raw log for diagnosis.
  bool downEverywhere(Map<String, dynamic> d) {
    final c = d['check'];
    return c is Map && c['state'] == 'down';
  }

  /// The checker's rows of an opened event: the verdict, then one row per node of the checker
  /// («Germany, Frankfurt» → «OK 200 · 0.2 s» / the error).
  List<(String, String)> checkFields(Map c) {
    final out = <(String, String)>[];
    final verdict = checkText({'check': c});
    if (verdict != null) out.add((l10n.checker, verdict));
    if (c['state'] == 'failed' && c['error'] != null && '${c['error']}'.isNotEmpty) out.add((l10n.error, '${c['error']}'));
    final nodes = c['nodes'];
    if (nodes is List) {
      for (final n in nodes) {
        if (n is! Map) continue;
        final where = [for (final k in ['country', 'city']) if (n[k] != null && '${n[k]}'.isNotEmpty) '${n[k]}'].join(', ');
        final ms = n['ms'] is num ? l10n.ms(n['ms'] as num) : null;
        final what = n['ok'] == true
            ? ['OK', if (n['code'] != null) '${n['code']}', if (ms != null) '· $ms'].join(' ')
            : '${n['error'] ?? l10n.error}';
        out.add((where.isEmpty ? '${n['cc'] ?? ''}' : where, what));
      }
    }
    return out;
  }
}

enum WhyGo { none, route, user, app, rules }

/// A row of the "why" block of a site event.
class WhyRow {
  const WhyRow(this.key, this.name, {this.go = WhyGo.none, this.id = '', this.at = '', this.to = '', this.mark, this.dim = false, this.icon = ''});

  final String key, name;
  final WhyGo go;
  final String id, at, to;
  final String? mark;
  final bool dim;

  /// The package whose icon the row shows ('' = none: a rule, or an app known only by a process name).
  final String icon;

  WhyRow withTo(String t) => WhyRow(key, name, go: go, id: id, at: at, to: t, mark: mark, dim: dim, icon: icon);
  WhyRow withMark(String m) => WhyRow(key, name, go: go, id: id, at: at, to: to, mark: m, dim: dim, icon: icon);
}
