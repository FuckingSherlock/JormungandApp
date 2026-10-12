import 'package:jormungand_core/jormungand_core.dart';

/// The value types the Nodes forms hand to the [CoreHost] and the small helpers of those forms
/// (mockup 32-nodes-forms.js, 70-profile-forms.js). The host does the work, the forms only fill
/// these in.

/// The subscription form's fields besides the URL and the name (mockup `saveSrcForm`). They live
/// on the source next to what the core owns (`Source.unknown`), the strings are the values the
/// mockup stores (English, shown translated).
class SubscriptionSettings {
  const SubscriptionSettings({
    this.updateInterval = 'auto',
    this.reloadAfterUpdate = true,
    this.testAfterUpdate = true,
    this.hwid = false,
    this.keepRules = false,
    this.filter = '',
    this.password = '',
    this.website = '',
    this.userAgent = 'Auto',
    this.channel = 'Auto',
  });

  /// What the form shows for [s] (the mockup's defaults for what it never set).
  factory SubscriptionSettings.of(Source s) {
    final u = s.unknown;
    bool flag(String k, bool dflt) => u.containsKey(k) ? _truthy(u[k]) : dflt;
    return SubscriptionSettings(
      updateInterval: u['updateInterval'] is num ? u['updateInterval'] : 'auto',
      reloadAfterUpdate: flag('reloadAfterUpdate', true),
      testAfterUpdate: flag('testAfterUpdate', true),
      hwid: flag('hwid', false),
      keepRules: flag('keepRules', false),
      filter: '${u['filter'] ?? ''}',
      password: '${u['password'] ?? ''}',
      website: '${u['website'] ?? ''}',
      userAgent: '${u['userAgent'] ?? 'Auto'}',
      channel: normalizeSubscriptionChannel(u['channel']),
    );
  }

  /// `'auto'` (the provider's period, else the global one) or whole hours (0 = never).
  final Object updateInterval;
  final bool reloadAfterUpdate;
  final bool testAfterUpdate;
  final bool hwid;
  final bool keepRules;

  /// A regular expression over server names, empty = all.
  final String filter;
  final String password;
  final String website;

  /// `Auto` | `sing-box` | `mihomo` | `v2ray`.
  final String userAgent;

  /// `Auto` | `Proxy` | `Direct` (the old `Direct first` / `Proxy first` count as `Auto`).
  final String channel;

  Map<String, dynamic> toJson() => {
    'updateInterval': updateInterval,
    'reloadAfterUpdate': reloadAfterUpdate,
    'testAfterUpdate': testAfterUpdate,
    'hwid': hwid,
    'keepRules': keepRules,
    'filter': filter,
    'password': password,
    'website': website,
    'userAgent': userAgent,
    'channel': channel,
  };

  static bool _truthy(Object? v) =>
      v != null && v != false && v != 0 && v != '';
}

const subscriptionUserAgents = ['Auto', 'sing-box', 'mihomo', 'v2ray'];
const subscriptionChannels = ['Auto', 'Proxy', 'Direct'];

/// A stored "Download via" value as one of [subscriptionChannels]: `Direct first`, `Proxy first` and a missing one are `Auto`.
String normalizeSubscriptionChannel(Object? v) => v == 'Proxy' || v == 'Direct' ? '$v' : 'Auto';

/// The protocol chips of the manual server form (`PROTO_CHIP`): UI protocol -> label.
const protocolChips = <String, String>{
  'vless': 'VLESS',
  'vmess': 'VMess',
  'trojan': 'Trojan',
  'ss': 'SS',
  'hy2': 'HY2',
  'tuic': 'TUIC',
  'anytls': 'AnyTLS',
  'socks': 'SOCKS',
};

/// What the secret field holds per protocol (`SECRET_FIELD`): the core reads it the same way
/// (manual.dart). [label] / [hint] are English keys of the l10n dictionary.
const secretFields = <String, ({String label, String hint})>{
  'vless': (label: 'UUID', hint: '8c1f3a52-7d0e-4e2b-9d71-…'),
  'vmess': (label: 'UUID', hint: '8c1f3a52-7d0e-4e2b-9d71-…'),
  'trojan': (label: 'Password', hint: '••••••••••••'),
  'hy2': (label: 'Password', hint: '••••••••••••'),
  'anytls': (label: 'Password', hint: '••••••••••••'),
  'ss': (label: 'Method:password', hint: 'aes-256-gcm:secret'),
  'tuic': (label: 'UUID:password', hint: 'uuid:password'),
  'socks': (label: 'User:password (optional)', hint: 'user:password'),
};

/// The secret as the form shows it, from the server's outbound (`nodeSecret`).
String nodeSecret(CatalogNode n) {
  final o = n.outbound;
  if (o == null) return '';
  final type = o['type'];
  if (type == 'shadowsocks') return '${o['method']}:${o['password']}';
  if (type == 'tuic') return '${o['uuid']}:${o['password'] ?? ''}';
  if (type == 'socks') {
    final user = o['username'];
    return user != null && '$user'.isNotEmpty
        ? '$user:${o['password'] ?? ''}'
        : '';
  }
  return '${o['uuid'] ?? o['password'] ?? ''}';
}

/// The manual server form (`saveNodeForm`): a [link] (one per line adds them all) or the fields.
/// [editSid] / [editNid] name the server being edited; [group] is a manual group id, or
/// [newGroup].
class NodeFormInput {
  const NodeFormInput({
    this.link = '',
    this.protocol = 'vless',
    this.address = '',
    this.port = '',
    this.secret = '',
    this.name = '',
    this.nameTouched = false,
    this.editSid,
    this.editNid,
    this.group = newGroup,
  });

  static const newGroup = '__new';

  final String link;
  final String protocol;
  final String address;
  final String port;
  final String secret;
  final String name;

  /// A name typed by hand wins over the link's `#name`.
  final bool nameTouched;
  final String? editSid;
  final String? editNid;
  final String group;

  bool get editing => editNid != null;
}

enum SaveNodeOutcome { added, edited, duplicate, failed }

class SaveNodeResult {
  const SaveNodeResult(
    this.outcome, {
    this.added = 0,
    this.duplicates = 0,
    this.error,
  });

  final SaveNodeOutcome outcome;

  /// Servers put into the group.
  final int added;

  /// Servers of the form that were in the group already.
  final int duplicates;

  /// The core's English text of a failure.
  final String? error;

  bool get ok =>
      outcome == SaveNodeOutcome.added || outcome == SaveNodeOutcome.edited;
}

/// A profile as the editor builds it (`saveCreateProfile`). [id] null = a new one.
class ProfileDraft {
  const ProfileDraft({
    this.id,
    this.name = '',
    this.sources = const [],
    this.nodes = const [],
    this.inAuto = true,
    this.pickMode = 'fastest',
    this.pickOrder = const [],
  });

  final String? id;
  final String name;

  /// Whole sources.
  final List<String> sources;

  /// Single servers, `sid::nid`.
  final List<String> nodes;
  final bool inAuto;
  final String pickMode;
  final List<String> pickOrder;
}

/// A chain as the editor builds it (`saveCreateChain`). [id] null = a new one, living on the
/// Nodes tab [mode] (`simple` | `profiles`).
class ChainDraft {
  const ChainDraft({
    this.id,
    this.mode = 'simple',
    this.name = '',
    this.inId,
    this.outId,
    this.inOff = const [],
    this.outOff = const [],
    this.inOn = const [],
    this.outOn = const [],
    this.exitMode = 'fastest',
    this.exitOrder = const [],
    this.inAuto = true,
  });

  final String? id;
  final String mode;
  final String name;
  final String? inId;
  final String? outId;
  final List<String> inOff;
  final List<String> outOff;

  /// Servers the source's own editor has off, switched on for this chain.
  final List<String> inOn;
  final List<String> outOn;
  final String exitMode;
  final List<String> exitOrder;
  final bool inAuto;
}
