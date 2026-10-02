/// Checks before something is saved or connected: what the mockup refuses with a toast, an
/// alert or a disabled Save (`toggleMain` in 50-home.js, `chainProblems` / `saveCreateChain` /
/// `renderCreateProfileSources` in 70-profile-forms.js). The texts are the mockup's (English);
/// the app localises by [ConnectCheck.code].
library;

import 'catalog.dart';
import 'models.dart';
import 'plan_builder.dart';

/// Why Connect cannot start: [code] `nothingInAuto` | `catalogEmpty` | `nothingToConnect` |
/// `noUsableServer`.
class ConnectCheck {
  const ConnectCheck(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

extension CatalogValidate on Catalog {
  /// What stops the power button (null = go ahead): Auto with every entry off Auto, nothing to
  /// connect in this mode, or a plan the core cannot take (`toggleMain` + `livePlan`'s throws).
  ConnectCheck? checkBeforeConnect() {
    if (nothingInAuto()) {
      return ConnectCheck('nothingInAuto',
          'Every entry in Route is switched off Auto, so Auto has nothing to connect through. Turn Use in Auto on for at least one entry, or pick one yourself with MANUAL.');
    }
    if (catalogEmpty()) {
      return ConnectCheck('catalogEmpty', simpleMode ? 'Add a subscription or a server first' : 'Create a profile first');
    }
    try {
      livePlan();
    } on CatalogException catch (e) {
      return ConnectCheck(e.code, e.message);
    }
    return null;
  }

  /// A profile draft (whole [sources] + single [nodes]) with nothing to use cannot be saved;
  /// the text says why, or null when it is fine (`renderCreateProfileSources`).
  String? profileProblem(List<String> sources, List<String> nodes) {
    if (profileRefsOf(sources, nodes).isNotEmpty) return null;
    final offs = offReasons(profileRefsOf(sources, nodes, withOff: true));
    return offs.isNotEmpty
        ? '${reasonsText(offs)} — switch ${offs.length > 1 ? 'one' : 'it'} on there or select another server'
        : 'Select at least 1 server — a profile with none can’t connect';
  }

  /// Each end needs at least one ticked server, and nothing it stands on switched off in
  /// Nodes (`chainProblems`). Empty = the chain can be saved.
  List<String> chainProblems(Chain d) {
    String one(String name, List<NodeRef> refs, List<NodeRef> all, String? uid) {
      if (refs.isNotEmpty) return '';
      final off = offReasons(all);
      if (off.isNotEmpty) return 'The $name: ${reasonsText(off)} — switch it on there or select another server';
      return unitRefs(uid).isNotEmpty ? 'Select at least 1 server of the $name' : '';
    }

    return [
      one('entry', chainEntryRefs(d), chainEntryRefs(d, withOff: true), d.inId),
      one('exit', chainExitRefs(d), chainExitRefs(d, withOff: true), d.outId),
    ].where((s) => s.isNotEmpty).toList();
  }

  /// [chainProblems] plus the one `saveCreateChain` adds: the ends must differ.
  String? chainSaveProblem(Chain d) {
    final p = chainProblems(d);
    if (p.isNotEmpty) return p.join('. ');
    return d.inId == d.outId ? 'Entry and exit must be different' : null;
  }
}
