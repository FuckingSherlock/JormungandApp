import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'form_parts.dart';
import 'rules_parts.dart';

/// The Nodes screens that carry a round ? (mockup 58-help.js `HELP`: nodes, srcadvanced, profile,
/// sourceentry, chain).
enum NodesHelp { nodes, srcAdvanced, profile, sourceEntry, chain }

/// `.help-btn` of a Nodes screen: opens its tips.
class NodesHelpButton extends StatelessWidget {
  const NodesHelpButton(this.topic, {super.key, this.tight = false});

  final NodesHelp topic;

  /// No space before it (inside a row that already has a gap).
  final bool tight;

  @override
  Widget build(BuildContext context) =>
      RoundHelp(tight: tight, onTap: () => showNodesHelp(context, topic));
}

Future<void> showNodesHelp(BuildContext context, NodesHelp topic) {
  final l10n = context.l10n;
  final (title, items) = switch (topic) {
    NodesHelp.nodes => (
      l10n.nodes,
      [
        (l10n.nodes, l10n.everythingTrafficCanGoThroughCreate),
        (l10n.simpleProfiles, l10n.twoTabsSwipeBetweenThemSubscriptions),
        (l10n.order, l10n.theOrderHereIsTheRoute),
        (l10n.tapAServer, l10n.itsMenuPingCopySwitchOff),
        (l10n.edit2, l10n.dragToReorderSwitchSubscriptionsOn),
        (l10n.off, l10n.hiddenEverywhereSettingsKeptSwitchIt),
        (l10n.unavailable, l10n.removedByTheProviderSettingsKept2),
      ],
    ),
    NodesHelp.srcAdvanced => (
      l10n.advanced,
      [
        ('User-Agent', l10n.howTheAppIntroducesItselfTo),
        (l10n.downloadVia, l10n.fetchTheSubscriptionDirectlyOrThrough),
        (l10n.sendXHwid, l10n.sendsADeviceIdRandomMade),
        (l10n.keepProviderRules, l10n.useTheRoutingRulesThatCome),
        (l10n.filter, l10n.keepOnlyServersWhoseNameMatches),
        (l10n.decryptPassword, l10n.onlyForSubscriptionsTheProviderEncrypted),
      ],
    ),
    NodesHelp.profile => (
      l10n.profiles,
      [
        (l10n.profile, l10n.yourOwnSetOfServersFrom),
        (l10n.tickASubscription, l10n.takeAllItsServersNewOnes),
        (l10n.openItTapServers, l10n.takeOnlyThoseFramed),
        (fastestLabel, l10n.connectsThroughTheQuickestWorkingServer),
        (l10n.priority, l10n.theFirstWorkingServerFromThe2),
        (l10n.useInAuto, l10n.autoMayPickThisProfileOff),
      ],
    ),
    NodesHelp.sourceEntry => (
      l10n.serversOfThisEntry,
      [
        (l10n.framed, l10n.serversThisEntryMayUseTap),
        (fastestLabel, l10n.connectsThroughTheQuickestWorkingServer),
        (l10n.priority, l10n.theFirstWorkingServerFromThe2),
        (l10n.useInAuto, l10n.autoMayPickThisEntryOff),
        (l10n.offInNodes2, l10n.notListedHereYourChoicesFor),
        (l10n.unavailable, l10n.removedByTheProviderKept15),
      ],
    ),
    NodesHelp.chain => (
      l10n.chains,
      [
        (l10n.chain, l10n.yourTrafficGoesToTheEntry),
        (l10n.entry, l10n.alwaysItsFastestSelectedServer),
        (l10n.exit, l10n.fastestOrPriorityTheFirstWorking),
        (l10n.framed, l10n.serversTheChainMayUseTap),
        (l10n.checkRoute, l10n.testsWhichPairsWorkAndHow),
      ],
    ),
  };
  return showTermsSheet(context, title, items);
}
