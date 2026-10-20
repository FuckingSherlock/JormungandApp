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
import 'rules_text.dart' show lostWhyText;
import '../widgets/node_row.dart' show nodeProtoLabel;

/// The words of the Events journal (mockup 47-events.js `evDescribe`, `evValue`, `evWhyRows`): the
/// structured data of an event as sentences, ids resolved to names through the catalog (falling
/// back to the raw id). The core and the models decide what happened and what is shown; this
/// only says it in the user's language.
class EventWords {
  EventWords(this.l10n, this.catalog);

  final AppLocalizations l10n;
  final Catalog catalog;

  /// The mark in front of a route that failed, in a detail line.
  static const warnMark = '⚠️';

  /// A detail as lines: the parts a [describe] joins with three spaces (rule, app, routes, the checker's verdict).
  List<String> detailLines(String detail) => [
    for (final s in detail.split('   ')) if (s.trim().isNotEmpty) s.trim(),
  ];

  // ── labels ──

  String catLabel(String cat) => switch (cat) {
    'conn' => l10n.connection,
    'net' => l10n.network,
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
    'conn/reconnected' => l10n.reconnected,
    'net/switched' => l10n.networkSwitched,
    'conn/disconnected' => l10n.disconnected,
    'conn/connectFailed' => l10n.connectFailed,
    'conn/lost' => l10n.connectionLost,
    'conn/restored' => l10n.connectionRestored,
    'conn/vpnDown' => l10n.vpnIsDown,
    'conn/vpnUp' => l10n.vpnOutageEnded,
    'conn/offline' => l10n.noNetwork,
    'conn/online' => l10n.internetAvailableAgain,
    'auto/switched' => l10n.entryOrServerSwitched,
    'auto/fastest' => l10n.autoChangedServerFastest,
    'auto/unstable' => l10n.unstableEntry,
    'site/blocked' => l10n.siteDoesNotOpen,
    'site/unreachable' => l10n.siteDoesNotOpenOnAny,
    'sub/updated' => l10n.subscriptionUpdated,
    'sub/failed' => l10n.subscriptionUpdateFailed,
    'sub/removed' => l10n.providerRemovedServers,
    'sub/back' => l10n.serversReturnedToTheSubscription,
    'sub/dead' => l10n.serversDoNotRespond,
    'node/lost' => l10n.serversInUseSwitchedOffOr,
    'node/back' => l10n.serversInUseSwitchedOn,
    'sub/diverged' => l10n.subscriptionServersDiffer,
    'rules/fallback' => l10n.ruleTargetUnavailable,
    'rules/targetBack' => l10n.ruleTargetBack,
    'rules/targetLost' => l10n.ruleTargetLost,
    'rules/targetFound' => l10n.ruleTargetFound,
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
    'core/restartFailed' => l10n.singBoxRestartFailed,
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
        return rule ? l10n.ruleTrafficIsBlockedIfUnavailable(who) : l10n.appTrafficIsBlockedIfUnavailable(who);
      case 'direct':
        return rule ? l10n.ruleTrafficGoesDirectIfUnavailable(who) : l10n.appTrafficGoesDirectIfUnavailable(who);
      case 'main':
        return rule ? l10n.ruleTrafficGoesThroughTheMain(who) : l10n.appTrafficGoesThroughTheMain(who);
    }
    if (to.contains(':')) {
      final t = targetName(catalog, to);
      return rule ? l10n.ruleTrafficGoesThrough(who, t) : l10n.appTrafficGoesThrough(who, t);
    }
    return '${rule ? l10n.rule : l10n.app} $who $to';
  }

  /// Where a lost target's traffic goes ("If unavailable"): like [_fallbackText], a block says "is blocked".
  String _lostText(Map<String, dynamic> d) {
    if ('${d['to']}' == 'block') {
      return _isRule(d) ? l10n.ruleIsBlocked(_who(d)) : l10n.appIsBlocked(_who(d));
    }
    return _fallbackText(d);
  }

  /// The traffic of a rule or an app comes back to its target («… goes through the target again»).
  String _backThroughTarget(Map<String, dynamic> d) => _isRule(d)
      ? l10n.ruleTrafficGoesThroughTheTarget(_who(d))
      : l10n.appTrafficGoesThroughTheTarget(_who(d));

  /// The names of a list, the rest counted by the total the event carries: «A, B and 3 more».
  String _namesOf(Object? list, Object? total, String Function(Object?) name) {
    final xs = list is List ? [for (final x in list) if ('$x'.isNotEmpty) name(x)] : <String>[];
    final more = (total is num ? total.toInt() : xs.length) - xs.length;
    return _lines([xs.join(', '), more > 0 ? l10n.and(l10n.more2(more)) : null], ' ');
  }

  /// The affected settings in short («the connection, 1 rule, 2 apps»); '' when none is affected.
  String _affectedBrief(Object? affected) {
    final xs = affected is List ? [for (final a in affected) if (a is Map) a] : const <Map>[];
    int count(String kind) => xs.where((a) => a['kind'] == kind).length;
    String counted(String kind, String one, String Function(num) many) {
      final n = count(kind);
      return n == 0 ? '' : (n == 1 ? one : many(n));
    }

    return _lines([
      count('connection') > 0 ? l10n.theConnection : null,
      counted('rule', l10n.n1Rule, l10n.rulesPlural),
      counted('app', l10n.n1App, l10n.appsPlural),
      counted('chain', l10n.n1Chain, l10n.chainsPlural),
      counted('profile', l10n.n1Profile, l10n.profilesPlural),
    ], ', ');
  }

  /// The detail of `sub/back` and `node/back`: the settings the servers carry again; '' when none is affected.
  String _affectedBack(Object? affected) {
    final brief = _affectedBrief(affected);
    return brief.isEmpty ? '' : l10n.trafficOfGoesThroughThemAgain(brief);
  }

  /// The causes of a `conn/vpnDown` / `vpnUp` (`core`, `network`, `routes`).
  List<String> _causes(Map<String, dynamic> d) =>
      d['causes'] is List ? [for (final c in d['causes'] as List) '$c'] : <String>[];

  /// The row of `conn/vpnDown`: «Waiting for network» while the network is the only cause (the VPN is on, not a failure),
  /// «Checking routes» while no cause is left but `pending: routes` (the network is back over silent routes), else
  /// «VPN is down» with the causes under it.
  (String, String) _vpnDownRow(Map<String, dynamic> d, {int attempts = 0}) {
    final causes = _causes(d);
    if (causes.length == 1 && causes.first == 'network') return (l10n.waitingForNetworkVpnIsOn, '');
    if (causes.isEmpty && d['pending'] == 'routes') return (l10n.checkingRoutesTheNetworkIsBack, '');
    return (l10n.vpnIsDown, _vpnDownReason(d, attempts: attempts));
  }

  /// Every `affected` entry of a `sub/updated` is a spare one of Auto's list (`spare: true`).
  static bool _allSpare(Object? affected) =>
      affected is List && affected.isNotEmpty && affected.every((a) => a is Map && a['spare'] == true);

  /// The closing row of `conn/vpnDown`: by the user or the system it is an outage that ended with a disconnect, not a
  /// recovery; else what the outage had (`causes`): sing-box running again, internet back, or both.
  String _vpnUpTitle(Map<String, dynamic> d) {
    if (d['by'] == 'user' || d['by'] == 'system' || d['by'] == 'app') return l10n.vpnOutageEndedVpnDisconnected;
    final causes = _causes(d);
    final parts = [
      if (causes.contains('core')) l10n.singBoxIsRunning,
      if (causes.contains('network')) l10n.internetIsAvailable,
      if (causes.contains('routes')) l10n.aRouteAnswers,
    ];
    return parts.isEmpty ? l10n.vpnWorksAgain : l10n.vpnWorksAgain2(parts.join(', '));
  }

  /// Kind of an affected setting (`affected[].kind`) as a label.
  String affectedKindLabel(String kind) => switch (kind) {
    'connection' => l10n.connection,
    'rule' => l10n.rule,
    'app' => l10n.app,
    'chain' => l10n.chain,
    'profile' => l10n.profile,
    _ => kind,
  };

  /// Where an affected setting's traffic goes now (`affected[].to`): a target's name, or the words of the block /
  /// direct / main flow, or «not working» for a chain or a profile that does not work.
  String affectedToLabel(Map a) => switch ('${a['to'] ?? ''}') {
    'block' => 'Block',
    'direct' => 'Direct',
    'main' => l10n.mainFlow2,
    'none' => l10n.notWorking,
    final to => target(to),
  };

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
      ('conn', 'disconnected') => () {
        // who: in the title («by you» / «by the system or another app» / «error: …»), no «By» field below
        if (d['by'] == 'user') return r(l10n.vpnDisconnectedByYou);
        if (d['by'] == 'app') return r(l10n.vpnDisconnectedTheAppWasClosed);
        if (d['by'] != 'error') return r(l10n.vpnDisconnectedByTheSystemOr);
        if (d['reason'] == 'pinLost') {
          // a server gone from its subscription has no name left (`pick` empty): the text names none
          final pick = '${d['pick'] ?? ''}';
          return r(pick.isEmpty
              ? l10n.vpnDisconnectedErrorServerIsUnavailable2(_pinLostWhy(d['why']))
              : l10n.vpnDisconnectedErrorServerIsUnavailable(pick, _pinLostWhy(d['why'])));
        }
        if (d['reason'] == 'down' && d['attempts'] is num) {
          final n = d['attempts'] as num;
          return r(n == 1 ? l10n.vpnDisconnectedErrorSingBoxDid : l10n.vpnDisconnectedErrorSingBoxDid2(n));
        }
        final reason = d['reason'];
        return r(reason == null ? l10n.vpnDisconnectedAfterAnError : l10n.vpnDisconnectedAfterAnError2('$reason'));
      }(),
      ('conn', 'reconnected') => () {
        final tookMs = d['tookMs'];
        final took = tookMs is num ? duration(tookMs) : '';
        // the duration closes the title, after « · »: «Reconnected · rule lists · 3 s»
        String t(String title) => _lines([title, took]);
        switch (d['reason']) {
          case 'settings':
            final ch = d['changed'];
            final parts = <String>[
              if (ch is String && ch.isNotEmpty) ch, // the text form of what changed
              if (ch is Map && ch['mode'] is Map)
                l10n.mode2(_modeText(ch['mode']['from']), _modeText(ch['mode']['to'])),
              if (ch is Map && ch['route'] is Map)
                l10n.route2(_routeText(ch['route']['from']), _routeText(ch['route']['to'])),
            ];
            return parts.isEmpty
                ? r(t(l10n.reconnected))
                : r(t(l10n.reconnectedSettings(parts.join(', '))));
          case 'lists':
            return r(t(l10n.reconnectedRuleLists));
          case 'reresolve':
            return r(t(l10n.reconnectedServerAddresses));
          case 'user':
            final down = d['downMs'] ?? d['tookMs'];
            return down is num
                ? r(t(l10n.reconnectedByYouVpnWasOff(duration(down))))
                : r(t(l10n.reconnected));
        }
        return r(t(l10n.reconnected));
      }(),
      ('net', 'switched') => () {
        final from = _netSide(d['from']), to = _netSide(d['to']);
        final down = d['downMs'];
        return r(
          down is num && down > 0
              ? l10n.networkSwitchedNoNetworkFor(from, to, duration(down))
              : l10n.networkSwitched2(from, to),
        );
      }(),
      ('conn', 'connectFailed') => r(l10n.couldNotConnect, '${d['reason'] ?? ''}'),
      ('conn', 'lost') => r(
        e.verdict == 'confirmed' ? l10n.noConnectionThroughTheVpnThe : l10n.noConnectionThroughTheVpnInternet,
      ),
      ('conn', 'restored') => d['downMs'] is num
          ? r(l10n.connectionRestoredBreakOf(duration(d['downMs'] as num)))
          : r(l10n.connectionRestored),
      ('conn', 'offline') => r(
        d['source'] == null || d['source'] == 'system'
            ? l10n.noInternetConnectionTheSystemReports2
            : l10n.noInternetConnectionDirectChecksFail,
      ),
      ('conn', 'online') => d['downMs'] is num
          ? r(l10n.internetIsAvailableAgainWasUnavailable(duration(d['downMs'] as num)))
          : r(l10n.internetIsAvailableAgain),
      ('auto', 'switched') => () {
        final (f, t) = serverPair(d['from'], d['to']);
        final hasRoute = d['route'] != null && '${d['route']}'.isNotEmpty;
        return r(
          hasRoute ? l10n.auto5(f, t) : l10n.auto5(entry(d['from']), entry(d['to'])),
          _lines([hasRoute ? entry(d['route']) : null, _reason(d)]),
        );
      }(),
      ('auto', 'fastest') => () {
        final (f, t) = serverPair(d['from'], d['to']);
        return r(l10n.fastest2(f, t), _lines([entry(d['route']), l10n.isNowTheFastest(t)]));
      }(),
      ('auto', 'unstable') => () {
        final strikes = d['strikes'] is num ? d['strikes'] as num : 0;
        final min = d['holdMs'] is num ? ((d['holdMs'] as num) / 60000).round().clamp(1, 1 << 30) : 1;
        // a spare entry (not the route the connection is on): the same facts, said so
        return r(d['spare'] == true
            ? l10n.spareEntryIsUnstableFailuresExcluded(entry(d['id']), strikes, min)
            : l10n.isUnstableFailuresExcludedForMin(entry(d['id']), strikes, min));
      }(),
      ('node', 'addressMissing') => r(
        l10n.domainDoesNotExistServers(
          source(d['source'], d['name'] ?? d['node']),
          '${d['host'] ?? ''}',
          d['nodes'] is num ? d['nodes'] as num : 1,
        ),
      ),
      ('site', 'blocked') => () {
        final via = d['via'] != null && '${d['via']}'.isNotEmpty ? _entryMark('', d['via'], d['viaServer']).trim() : '';
        final route = _entryMark('', d['entry'] ?? d['route'], d['server']).trim();
        return r(
          route.isEmpty ? l10n.doesNotOpen(host(d)) : l10n.doesNotOpenThrough2(host(d), route),
          _lines([via.isEmpty ? null : l10n.throughItOpens(via), whyText(d)], '   '),
        );
      }(),
      ('site', 'unreachable') => () {
        final tried = d['tried'] is List ? d['tried'] as List : const [];
        // down everywhere: the site is down, our routes are no part of it
        final routes = !downEverywhere(d);
        return r(
          routes ? l10n.doesNotOpenThroughAnyServer(host(d)) : l10n.doesNotOpen(host(d)),
          _lines([
            if (routes) ...[
              _entryMark(warnMark, d['entry'] ?? d['route'], d['server']),
              for (final x in tried)
                if (x is Map) _entryMark(warnMark, x['entry'], x['server']),
              if (tried.isEmpty) _noRoute(d),
            ],
            whyText(d),
            checkText(d),
          ], '   '),
        );
      }(),
      // warn: the update removed servers in use (`lost`, `affected`), the traffic that used them goes elsewhere
      ('sub', 'updated') when _allSpare(d['affected']) => r(
          l10n.subscriptionRemovedUsedBySpare(
            source(d['source'], d['name']),
            l10n.serversPlural(d['lostCount'] is num ? d['lostCount'] as num : (d['lost'] is List ? (d['lost'] as List).length : 0)),
            [for (final a in (d['affected'] as List)) '${(a as Map)['name'] ?? a['id']}'].join(', '),
          ),
          l10n.autoSkipsThemUntilTheProvider,
        ),
      ('sub', 'updated') => d['lost'] is List && (d['lost'] as List).isNotEmpty
          ? r(
              l10n.subscriptionRemovedServersInUse(
                source(d['source'], d['name']),
                _namesOf(d['lost'], d['lostCount'], (x) => '$x'),
              ),
              l10n.theirTrafficUsesIfUnavailableFor,
            )
          : r(
              l10n.subscriptionUpdated2(
                source(d['source'], d['name']),
                d['added'] is num ? d['added'] as num : 0,
                d['removed'] is num ? d['removed'] as num : 0,
              ),
              d['total'] is num ? l10n.serversPlural(d['total'] as num) : '',
            ),
      ('sub', 'failed') => r(l10n.couldNotUpdateSubscription(source(d['source'], d['name'])), '${d['error'] ?? ''}'),
      ('sub', 'removed') => r(
        l10n.theProviderRemovedServersPlural(d['count'] is num ? d['count'] as num : 0, source(d['source'], d['name'])),
        l10n.seeUnavailableInNodesTheirSettings,
      ),
      ('sub', 'back') => r(
        l10n.subscriptionReturnedServersInUse(
          source(d['source'], d['name']),
          _namesOf(d['names'], d['count'], (x) => '$x'),
        ),
        _affectedBack(d['affected']),
      ),
      ('node', 'lost') => () {
        final names = _namesOf(d['nodes'], d['nodeCount'], server);
        return d['action'] == 'deleted'
            ? r(l10n.youDeletedServersInUse(names), l10n.theirTrafficUsesIfUnavailable)
            : r(l10n.youSwitchedOffServersInUse(names), l10n.theirTrafficUsesIfUnavailableUntil);
      }(),
      ('node', 'back') => r(
        l10n.youSwitchedOnServersInUse(_namesOf(d['nodes'], d['nodeCount'], server)),
        _affectedBack(d['affected']),
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
        l10n.couldNotLoadRuleList('${d['tag']}'),
        d['hasCopy'] == true
            ? (d['copyAt'] is num ? l10n.usingTheCopyFrom(stamp((d['copyAt'] as num).toInt())) : l10n.theLastCopyIsUsed)
            : d['hasCopy'] == false
            ? l10n.noCopyRulesWithThisList
            : l10n.theLastCopyIsUsed,
      ),
      ('rules', 'ruleSetUpdated') => r(l10n.ruleSetUpdated2('${d['tag']}')),
      ('rules', 'fallback') => r(l10n.doesNotAnswer(target(d['target'])), _fallbackText(d)),
      ('rules', 'targetBack') => r(
        l10n.answersAgain(target(d['target'])),
        _backThroughTarget(d),
      ),
      ('rules', 'targetLost') => r(
        l10n.targetIsUnavailable(target(d['target'])),
        _lines([lostWhyText(l10n, '${d['why']}'), _lostText(d)], '. '),
      ),
      ('rules', 'targetFound') => r(
        l10n.isAvailableAgain(target(d['target'])),
        _backThroughTarget(d),
      ),
      ('dns', 'switched') => r(
        l10n.dns3('${d['side'] ?? ''}', dnsName(d['from']), dnsName(d['to'])),
        d['reason'] == 'failover'
            ? l10n.doesNotAnswer(dnsName(d['from']))
            : d['reason'] == 'back'
            ? l10n.answersAgainReturnedToIt(dnsName(d['to']))
            : l10n.switchAutomaticallyIsOffTheFirst,
      ),
      ('dns', 'failed') => r(l10n.dnsServerDoesNotAnswer2(dnsName(d['server']))),
      ('dns', 'failedOnNode') => r(
        d['via'] != null && '${d['via']}'.isNotEmpty
            ? l10n.dnsServerDoesNotAnswerThrough(dnsName(d['server']), server(d['node']), server(d['via']))
            : l10n.dnsServerDoesNotAnswer2(dnsName(d['server'])),
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
      ('core', 'crashed') => d['code'] is num
          ? r(l10n.singBoxCrashedCode(d['code'] as num))
          : r(l10n.singBoxStopped, l10n.startingItAgain),
      ('core', 'restarted') => d['downMs'] is num
          ? r(l10n.coreIsRunningAgainDownFor(duration(d['downMs'] as num)), d['attempt'] is num ? l10n.attempt2(d['attempt'] as num) : '')
          : r(l10n.singBoxStartedAgain, d['attempt'] is num ? l10n.attempt2(d['attempt'] as num) : ''),
      ('core', 'down') => d['proxy'] == 'kept'
          ? r(l10n.coreNotRunningFor30S)
          : r(l10n.vpnIsDown, l10n.trafficGoesDirectStillTrying),
      ('conn', 'vpnDown') => _vpnDownRow(d),
      ('conn', 'vpnUp') => r(_vpnUpTitle(d)),
      ('core', 'tunNeedsAdmin') => r(l10n.tunNeedsAdministratorRights, l10n.runTheAppAsAdministratorOr),
      ('core', 'restartFailed') => r(
        l10n.singBoxCouldNotStartAgain,
        _lines([
          d['attempt'] is num ? l10n.attempt2(d['attempt'] as num) : null,
          d['error'] != null ? '${d['error']}' : null,
        ]),
      ),
      ('core', 'sysProxy') => d['by'] == 'user'
          ? r(
              d['on'] == true ? l10n.youSetTheSystemProxy : l10n.youRemovedTheSystemProxy,
              d['on'] == true ? '' : l10n.removedWithTheRemoveSystemProxy,
            )
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
          who.isEmpty ? l10n.connectionsToAreFailing(dest) : l10n.connectionsAreNotEstablished(who),
          _lines([
            who.isEmpty ? null : dest,
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
        d['attempts'] is List ? l10n.updateSourcesChecked((d['attempts'] as List).length) : '',
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

  /// The reason line of `conn/vpnDown`: the causes (core, network) joined with " · ", then the system proxy left on.
  /// [attempts] — the newest `restartFailed` attempt among the events joined into the row, when the caller has them.
  String _vpnDownReason(Map<String, dynamic> d, {int? attempts}) {
    final n = d['routes'];
    return [
      for (final c in _causes(d))
        switch (c) {
          'core' => attempts != null && attempts > 0 ? l10n.singBoxStoppedAndHasNot2(attempts) : l10n.singBoxStoppedAndHasNot,
          'network' => l10n.noInternetConnection,
          'routes' => n is int && n > 1 ? l10n.noneOfRoutesAnswersTheInternet('$n') : l10n.noRouteAnswersTheInternetWorks,
          _ => '',
        },
      if (d['proxy'] == 'kept') l10n.systemProxyIsStillSetSo,
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  /// How a request of `conn/failing` ended (`ConnKind.name`).
  String _failKind(Object? k) => switch (k) {
    'refused' => l10n.refusedByTheFarSide,
    'reset' => l10n.droppedAfterConnecting,
    'timeout' => l10n.noAnswerInTime,
    'stalled' => l10n.sentNothingCameBack,
    'instantRefusal' => l10n.noAnswerConnectionEndedInUnder,
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
      '${text(e)} ${typeLabel(e.cat, e.type)} ${catLabel(e.cat)} ${e.cat} ${e.type} ${e.data.values.join(' ')} '
      '${reasonOf(e) ?? ''} ${[for (final r in trailRows(e)) r.text].join(' ')}';

  // ── rows of the Events list: groups, the reason, the status lines, the checks ──

  /// Title and detail of a whole row (a plain event, an operation's result, a group of consequences).
  (String, String) describeGroup(EventGroup g) {
    if (g.isGroup) {
      final code = g.whyCode ?? '';
      if (code == 'net.captive') return (l10n.theNetworkRequiresSignInLogin2(g.times), '');
      return (whyPhrase(g.ev.why) ?? code, '');
    }
    final first = g.head!;
    switch (g.opKind) {
      case 'subUpdateAll':
        final all = <String>{}, ok = <String>{};
        for (final x in g.items) {
          if (x.cat != 'sub') continue;
          final s = '${x.data['source']}';
          if (x.type == 'updated') ok.add(s);
          if (x.type == 'updated' || x.type == 'failed') all.add(s);
        }
        return (l10n.subscriptionsUpdatedOf(ok.length, all.length), '');
      case 'appUpdate':
        final last = g.items.last;
        String ver = '';
        for (final x in g.items.reversed) {
          final v = x.data['version'] ?? x.data['to'];
          if (v != null && '$v'.isNotEmpty) {
            ver = '$v';
            break;
          }
        }
        switch ('${last.cat}/${last.type}') {
          case 'core/updateAvailable':
            return (l10n.updateAvailable2(ver), '');
          case 'core/updateDownloaded':
            return (l10n.updateDownloaded(ver), '');
          case 'core/updateInstalled':
            return (l10n.updateInstalled(ver), '');
          case 'core/updateFailed':
            final stage = switch (last.data['stage']) {
              'check' => l10n.check,
              'verify' => l10n.signatureCheck,
              'install' => l10n.installation,
              _ => l10n.download2,
            };
            return (l10n.updateFailedAt(ver, stage), '');
        }
        final d = describe(last);
        return (d.title, d.detail);
      case 'reconnect':
        final r = g.items.where((x) => x.key == 'conn/reconnected');
        final d = describe(r.isEmpty ? g.ev : r.last);
        return (d.title, d.detail);
      case 'ruleSets':
        final ok = g.items.where((x) => x.key == 'rules/ruleSetUpdated').length;
        final bad = g.items.where((x) => x.key == 'rules/ruleSetFailed').length;
        if (bad > 1) return (l10n.couldNotLoadRuleLists(bad), '');
        if (bad == 0 && ok > 0) return (l10n.ruleListsUpdated(ok), '');
    }
    final e = g.ev;
    // a crash merged into «VPN is down» (joins): the row takes its title and status from vpnDown / vpnUp
    // (a lone vpnUp, its vpnDown pruned or filtered out, is worded by itself below)
    final down = g.items.where((x) => x.key == 'conn/vpnDown').toList();
    if (down.isNotEmpty) {
      // closed by vpnUp: the row is still «VPN is down», the closing is its status (closedLine)
      final src = down.last;
      var attempts = 0;
      for (final x in g.items) {
        final a = x.key == 'core/restartFailed' ? x.data['attempt'] : null;
        if (a is num && a > attempts) attempts = a.toInt();
      }
      return _vpnDownRow(src.data, attempts: attempts);
    }
    if (first.key == 'core/crashed' && g.items.length > 1) {
      final last = g.last;
      if (last.key == 'core/restartFailed' && last.data['attempt'] is num) {
        return (l10n.restartingAttempt(last.data['attempt'] as num), '');
      }
      final d = describe(last.key == 'core/crashed' ? first : last);
      return (d.title, d.detail);
    }
    if (e.key == 'auto/switched' && g.closed && e.data['route'] == null) {
      return (
        l10n.autoInsteadOfThenBackTo(entry(e.data['to']), entry(e.data['from']), duration(g.closedAfter!)),
        '',
      );
    }
    if (e.key == 'dns/switched' && g.closed) {
      return (
        l10n.dnsInsteadOfThenBack(
          '${e.data['side'] ?? ''}',
          dnsName(e.data['from']),
          dnsName(e.data['to']),
          duration(g.closedAfter!),
        ),
        '',
      );
    }
    if (e.key == 'auto/fastest' && g.times > 1) {
      final (_, t) = serverPair(e.data['from'], e.data['to']);
      return (l10n.fastestSwitchesNow(g.times, t), '');
    }
    if (e.key == 'core/deprecated' && g.times > 1) return (l10n.singBoxDeprecatedConfigOptions(g.times), '');
    final d = describe(e);
    return (d.title, d.detail);
  }

  /// The reason line of a row; null = none. [find] looks an event up by id when the root of a consequence is not
  /// in the row (the feed); the line never repeats the title or a line of the detail (detail = what, reason = why).
  String? reasonLine(EventGroup g, {EventRecord? Function(int id)? find}) {
    if (g.isGroup) return null;
    final r = reasonOf(g.ev, find: (id) => g.items.where((x) => x.id == id).firstOrNull ?? find?.call(id));
    if (r == null) return null;
    final (title, detail) = describeGroup(g);
    // the detail (or the title) already says it: once is enough
    final t = r.trim();
    return title.contains(t) || detail.contains(t) ? null : r;
  }

  /// The reason of one event: what the Sentinel found (`verdict`, `why`), else the reason the type carries in its data.
  /// A consequence reads «Cause: <title of its root>» ([find] gets the root by its id); with no root at hand, its own `why`.
  String? reasonOf(EventRecord e, {EventRecord? Function(int id)? find}) {
    final why = whyPhrase(e.why);
    final shown = describe(e);
    bool known(String s) => s.isEmpty || shown.title.contains(s) || shown.detail.contains(s);
    switch (e.verdict) {
      case 'consequence':
        final root = e.cause == null ? null : find?.call(e.cause!);
        if (root != null) return l10n.cause(describe(root).title);
        return why == null ? null : l10n.cause(why);
      case 'blip':
        // «Recovered on its own · after N s»: the time is in `why.params` (`recovered`) and in the trail step
        final wp = e.why?['params'];
        if (wp is Map && wp['afterMs'] is num) return l10n.recoveredOnItsOwnAfter(duration(wp['afterMs'] as num));
        for (final s in e.trail ?? const <Map<String, dynamic>>[]) {
          final p = s['params'];
          if (s['code'] == 'blip.recovered' && p is Map && p['afterMs'] is num) {
            return l10n.recoveredOnItsOwnAfter(duration(p['afterMs'] as num));
          }
        }
        return l10n.recoveredBeforeAVerdictWasReached;
      case 'workaround':
        // `via` is the route the event names; `by` is the check that found the way
        final p = e.why?['params'];
        final raw = [if (p is Map) p['via'], e.data['via'], if (p is Map) p['by']].firstWhere(
          (x) => x != null && '$x'.isNotEmpty,
          orElse: () => null,
        );
        final via = raw == null ? '' : nameOf(raw);
        return via.isEmpty ? null : l10n.opensThrough(via);
      case 'unexplained':
        return l10n.causeNotEstablishedSeeTheChecks;
    }
    if (e.whyCode == 'why.unknown') return l10n.causeNotEstablishedSeeTheChecks;
    if (why != null && !known(why)) return why;
    // these say their `reason` in the detail already (a code like `failover` / `down` is no reason line)
    if (e.cat == 'auto' || e.key == 'dns/switched' || e.key == 'conn/disconnected') return null;
    for (final k in const ['reason', 'why', 'error']) {
      final v = e.data[k];
      if (v == null || '$v'.isEmpty || v is Map || v is List) continue;
      final s = fieldValue(k, v, e);
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  /// The phrase of a `why.code`; null = a code with no phrase of its own (the title says it).
  String? whyPhrase(Map<String, dynamic>? why) {
    if (why == null) return null;
    final p = why['params'];
    switch (why['code']) {
      case 'net.offline':
        return l10n.noInternetConnectionTheSystemReports;
      case 'net.captive':
        return l10n.theNetworkRequiresSignInLogin;
      case 'core.down':
        return l10n.theSingBoxCoreIsNot;
      case 'svc.fetch':
        final ms = p is Map ? (p['ms'] ?? p['afterMs'] ?? p['elapsedMs']) : null;
        return l10n
            .noAnswerEitherDirectlyOrThrough(ms is num ? duration(ms) : '')
            .replaceFirst(RegExp(r'\s*·\s*$'), '');
      case 'dns.down':
        return l10n.theDnsServerDoesNotAnswer;
      case 'dns.node':
        return l10n.theDnsServerDoesNotAnswer2;
      case 'node.addressMissing':
        return l10n.theServerSDomainDoesNot;
      case 'recovered':
        return l10n.recoveredBeforeAVerdictWasReached;
      case 'why.unknown':
        return l10n.causeNotEstablishedSeeTheChecks;
    }
    return null;
  }

  /// «+N related» (+ the time of the last one); null = none.
  String? relatedLine(EventGroup g) {
    if (g.isGroup || g.relatedCount == 0) return null;
    return _lines([l10n.related2(g.relatedCount), g.relatedLastAt > 0 ? clock(g.relatedLastAt) : null]);
  }

  /// «Finished at HH:MM · lasted N» of a closed pair; null = not closed.
  String? closedLine(EventGroup g) {
    final c = g.closer;
    if (c == null) return null;
    return l10n.finishedAtLasted(clock(c.at), duration(g.closedAfter ?? 0));
  }

  /// «N times · from HH:MM to HH:MM»; null = once.
  String? repeatsLine(EventGroup g) {
    if (g.times <= 1) return null;
    final from = g.isGroup ? g.items.first.at : g.repeats.first.at;
    return l10n.timesFromTo(g.times, clock(from), clock(g.lastAt));
  }

  /// The checks of an event (`trail`) as rows; over 8 steps: the first 3, «N more», the last 3.
  List<TrailRow> trailRows(EventRecord e) {
    final t = e.trail;
    if (t == null || t.isEmpty) return const [];
    final start = (t.first['at'] as num?)?.toInt();
    TrailRow row(Map<String, dynamic> s) {
      final at = (s['at'] as num?)?.toInt();
      return TrailRow(
        switch (s['outcome']) {
          'pass' => '✓',
          'fail' => '✗',
          'inconclusive' => '?',
          _ => '·',
        },
        _trailText(s),
        at != null && start != null ? '+${((at - start) / 1000).toStringAsFixed(1)} ${l10n.s3}' : null,
      );
    }

    if (t.length <= 8) return [for (final s in t) row(s)];
    return [
      for (final s in t.take(3)) row(s),
      TrailRow('·', l10n.more2(t.length - 6), null),
      for (final s in t.skip(t.length - 3)) row(s),
    ];
  }

  String _trailText(Map<String, dynamic> s) {
    final code = '${s['code']}', pass = s['outcome'] == 'pass', p = s['params'];
    final params = p is Map ? p : const {};
    switch (code) {
      case 'suspect':
        return l10n.failureSuspected;
      case 'ctx.net':
        return pass
            ? l10n.networkIsUp
            : s['outcome'] == 'inconclusive'
            ? l10n.networkStateIsUnclear
            : l10n.noNetwork;
      case 'ctx.core':
        return pass ? l10n.coreIsRunning : l10n.coreIsNotRunning;
      case 'self.restarted':
        return l10n.theCoreRestartedTheWindowStarts;
      case 'net.switched':
        return params['stable'] == false ? l10n.theNetworkIsSwitchingWaitingFor : l10n.theNetworkSettledAfterTheSwitch;
      case 'self.reject':
        return l10n.notJudgedCausedByTheApp;
      case 'defer.timeout':
        return l10n.gaveUpWaitingForAVerdict;
      case 'root.covers':
        return l10n.alreadyCoveredByAnOpenCause;
      case 'check.skipped':
        return l10n.checkSkippedACauseIsAlready;
      case 'park':
        return l10n.waitingBehindAFailedServer;
      case 'resume':
        return l10n.theServerIsBackCheckingAgain;
      case 'park.expired':
        return l10n.waitedTooLongBehindAFailed;
      case 'persist.wait':
        return l10n.waitingToSeeWhetherItPersists;
      case 'persist.window':
        return l10n.stillFailingAfterTheWait;
      case 'blip.recovered':
        return params['afterMs'] is num
            ? l10n.recoveredOnItsOwnAfter(duration(params['afterMs'] as num))
            : l10n.recoveredBeforeAVerdictWasReached;
      case 'why.unknown':
        return l10n.noCauseFound;
      case 'root.closed':
        return l10n.causeClosed;
      case 'root.relinked':
        return l10n.linkedToAnotherCause;
    }
    // a code with no phrase: the code and its parameters
    return params.isEmpty ? code : '$code ${params.entries.map((x) => '${x.key}=${x.value}').join(' ')}';
  }

  /// A side of `net/switched` (`{type, provider?, operator?}`): "Wi-Fi (ISP)".
  String _netSide(Object? s) {
    if (s is! Map) return '';
    final label = switch (s['type']) {
      'wifi' => l10n.wiFi,
      'ethernet' => l10n.ethernet,
      'mobile' || 'cellular' => l10n.mobile,
      final t => '${t ?? ''}',
    };
    final who = s['type'] == 'mobile' || s['type'] == 'cellular' ? s['operator'] : s['provider'];
    return who is String && who.isNotEmpty ? l10n.nameWithDetail(label, who) : label;
  }

  /// `why` of a lost Manual pin (`deleted` / `off` / `unsupported`).
  String _pinLostWhy(Object? w) => switch (w) {
    'off' => l10n.switchedOff,
    'unsupported' => l10n.notSupported,
    _ => l10n.deleted2,
  };

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
    'why' when e?.cat == 'sub' || e?.cat == 'rules' => l10n.reason,
    'default' when e?.cat == 'rules' => l10n.ifUnavailableIsDefault,
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
    'host' => l10n.site,
    'dest' => l10n.address,
    'via' => l10n.opensVia,
    'source' => l10n.subscription,
    'name' => l10n.name,
    'added' => l10n.newServers,
    'removed' => l10n.removed,
    'total' || 'count' || 'nodeCount' || 'lostCount' => l10n.servers,
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
      if (k == 'why' && e.type == 'targetLost') return lostWhyText(l10n, '$v');
      if (k == 'to') return switch (v) { 'block' => 'Block', 'direct' => 'Direct', 'main' => l10n.mainFlow2, _ => '$v' };
    }
    if (e.cat == 'core' && (e.type == 'stateRestored' || e.type == 'stateLost')) {
      if (k == 'from') return switch (v) { 'bak' => l10n.lastBackup, 'bak2' => l10n.olderBackup, _ => '$v' };
      if (k == 'reason') {
        return switch (v) {
          'nul' => l10n.theFileContainedOnlyZeroBytes,
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
    if (k == 'source') return source(v);
    if ((k == 'from' || k == 'to') && e.cat == 'auto' && e.data['route'] != null && '${e.data['route']}'.isNotEmpty && v is String) {
      final (a, b) = serverPair(e.data['from'], e.data['to']);
      return k == 'from' ? a : b;
    }
    if (const ['entry', 'server', 'route', 'from', 'to', 'via', 'id'].contains(k) && v is String) return nameOf(v);
    return _plain(v, e);
  }

  /// A value no rule above knows, in words and never as Dart's own text: an epoch in ms is a time, a list is its
  /// items joined, a map is its `key: value` pairs (`from`/`to` of a change: «a → b»).
  String _plain(Object? v, EventRecord e) {
    if (v is num && v >= 1e12 && v < 1e14) return stamp(v.toInt()); // epoch ms (2001 … 5138)
    if (v is List) return v.map((x) => _plain(x, e)).where((s) => s.isNotEmpty).join(', ');
    if (v is Map) {
      if (v.length == 2 && v.containsKey('from') && v.containsKey('to')) return '${_plain(v['from'], e)} → ${_plain(v['to'], e)}';
      final name = v['name'];
      if (name is String && name.isNotEmpty) return name;
      return v.entries.where((x) => x.value != null).map((x) => '${x.key}: ${_plain(x.value, e)}').join(', ');
    }
    if (v is String && e.cat == 'dns') return dnsName(v); // `servers` of a dns event: ids of DNS servers
    if (v is String && v.contains('::')) return server(v);
    return '$v';
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
    // a field whose text repeats a field shown above is left out («Server cloudflare» / «Provider cloudflare»);
    // only text values: two flags both «Yes», or two equal counts, are not a repeat
    final seen = <String>{};
    for (final x in e.data.entries) {
      final v = x.value;
      if (v == null || (v is String && v.isEmpty)) continue;
      if (noRoutes && const ['entry', 'server', 'tried', 'retries'].contains(x.key)) continue; // down everywhere: not our routes
      if (x.key == 'source' && e.cat == 'conn') continue; // 'closed': where the core saw it, not a subscription
      if (x.key == 'by') continue; // who is in the title (VPN disconnected · by you …), no «By» field below
      if (x.key == 'repeat') continue; // shown as the row's times
      if (x.key == 'affected' || x.key == 'nodeIds') continue; // the affected list is drawn as its own rows; ids are for the buttons
      if (e.cat == 'sub' && (x.key == 'onlyDirectCount' || x.key == 'onlyTunnelCount')) continue; // folded into the list's value
      if (x.key == 'check' && v is Map) {
        out.addAll(checkFields(v));
        continue;
      }
      final text = fieldValue(x.key, v, e);
      if (text.isEmpty) continue;
      if (v is! num && v is! bool && !seen.add(text.trim().toLowerCase())) continue;
      out.add((fieldLabel(x.key, e), text));
    }
    return out;
  }

  /// The external checker's verdict on a site event (`data.check`, docs/connect-model.md → «Внешний
  /// чекер»): one sentence, or null when there is nothing to say (the check is off, or the event has none).
  String? checkText(Map<String, dynamic> d) {
    final c = d['check'];
    if (c is! Map) return null;
    return switch (c['state']) {
      'opens' => l10n.theExternalCheckerOpensItFrom,
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
        final ms = n['ms'] is num ? '${(n['ms'] as num).round()}${l10n.ms2}' : null;
        final what = n['ok'] == true
            ? ['OK', if (n['code'] != null) '${n['code']}', if (ms != null) '· $ms'].join(' ')
            : '${n['error'] ?? l10n.error}';
        out.add((where.isEmpty ? '${n['cc'] ?? ''}' : where, what));
      }
    }
    return out;
  }
}

/// The event says the Manual pick was lost (`conn/disconnected` by an error: `reason: pinLost`; `conn/connectFailed`:
/// `fix: pick`): the one way out is to choose a server (docs/logs.md → «По типам»).
bool eventPinLost(EventRecord e) {
  final d = e.data, err = d['error'];
  return d['pinLost'] == true ||
      d['reason'] == 'pinLost' ||
      (err is Map && err['reason'] == 'pinLost') ||
      (e.key == 'conn/connectFailed' && d['fix'] == 'pick');
}

/// The cause of a failed connect lies in the settings (`fix: settings`, the proxy port is taken): there the row offers
/// «Open settings» (Settings → Connection).
bool eventCauseInSettings(EventRecord e) => e.key == 'conn/connectFailed' && e.data['fix'] == 'settings';

/// A step of the checks of an event: [mark] is ✓ ✗ ? or ·, [at] the time since the first step ("+1.2 s").
class TrailRow {
  const TrailRow(this.mark, this.text, this.at);

  final String mark, text;
  final String? at;
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
