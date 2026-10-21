import 'package:flutter/widgets.dart';

/// Where a tap in one screen leads to another (mockup: `openRuleForm`, `openAppAct`, `openRules`,
/// `openDnsSettings`, `openRuleSets`, `openNodes`, `openProfiles`...). The shell owns the tabs and
/// the sheets, the screens only ask. A link that is null is not wired: the row that needs it
/// simply is not shown, so a screen never offers a tap that goes nowhere.
@immutable
class AppLinks {
  const AppLinks({
    this.openNodesEntry,
    this.openNodesAdd,
    this.openRules,
    this.openRuleForm,
    this.openAppAct,
    this.openDns,
    this.openConn,
    this.openRuleSets,
    this.newRuleFor,
    this.openAppRule,
    this.openRoute,
    this.openLogsEvent,
  });

  /// Nodes at the card of a source / profile / chain, unfolded and in view.
  final void Function(String id)? openNodesEntry;

  /// Nodes on [tab] (`simple` / `profiles`) with its "+" open (an empty mode of Route).
  final void Function({String? tab})? openNodesAdd;

  /// Rules, at a service / quick rule (`svc:telegram`, `quick:ads`, `lan`) or just the screen.
  final void Function([String? at])? openRules;

  /// A user rule's form.
  final void Function(String id)? openRuleForm;

  /// The per-app route dialog of an app (package).
  final void Function(String pkg)? openAppAct;

  /// Settings -> DNS.
  final VoidCallback? openDns;

  /// Settings -> Connection (the proxy port of a failed connect, `fix: settings`).
  final VoidCallback? openConn;

  /// Rules -> Rule sets.
  final VoidCallback? openRuleSets;

  /// The form of a new rule for a host (a domain or an address) or an app, with the target
  /// preset to the entry that opens it (the "Create rule" of a blocked site).
  final void Function({String? host, String? app, String? via})? newRuleFor;

  /// A rule of an app: the sheet of the app (package) with the form over it. With [ruleId] the form of
  /// that rule; without, a new rule (the exact domain [host], Fallback = Proxy through the node [via]).
  final void Function({required String app, String? ruleId, String? host, String? via})? openAppRule;

  /// The Route sheet; [edit] opens it in edit mode (the "Nothing in Auto" alert).
  final void Function({bool edit})? openRoute;

  /// Logs -> Events at an event.
  final void Function(int id)? openLogsEvent;
}

class AppLinksScope extends InheritedWidget {
  const AppLinksScope({super.key, required this.links, required super.child});

  final AppLinks links;

  /// The links of the nearest scope; none wired when there is no shell above (a test of one screen).
  static AppLinks of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLinksScope>()?.links ??
      const AppLinks();

  @override
  bool updateShouldNotify(AppLinksScope old) => links != old.links;
}
