/// Everything of ours that opens a connection or a process of its own and therefore has to work
/// OUTSIDE the tunnel: the app is inside the VPN (Android no longer excludes itself, the desktop
/// never did), so a connection it makes enters the TUN like any app's and, unless something takes
/// it out, loops back into the proxy it is meant to check, or never leaves because the proxy is down.
///
/// This list is the checklist. `test/outside_tunnel_test.dart` (core) and
/// `app/test/outside_tunnel_guard_test.dart` scan the sources for network API usage and fail on a
/// file that is not listed here (and on a listed file that no longer uses one); the message says
/// what to do. A new feature that opens its own connection — or functionality brought over from the
/// other platform's version — gets its entry here, with the way it stays out of the tunnel; the
/// platform differences go to docs/platforms.md → «Работа вне туннеля».
///
/// Adding an entry is not the fix by itself, [how] must be true: `ownRule` needs the code to run in
/// the process the self rule matches (config.dart → [selfRules]), `protectedSocket` needs the
/// platform to protect the sockets, `loopback` needs 127.0.0.1.
library;

/// How an entry's connections stay outside the tunnel.
enum OutsideHow {
  /// The connection is made by this app's own process (the Dart HTTP clients, DNS probes, the
  /// desktop sing-box helper processes of ping / speed test) and enters the TUN. The self rule
  /// (config.dart → `selfRules`: Android `package_name`, desktop `process_path`) sends it direct,
  /// ahead of the user's rules, and its DNS lookups are answered by a direct DNS server
  /// (`selfDnsRules`).
  ownRule,

  /// Android: sockets the platform keeps out of the VPN itself — the sockets of a libbox instance
  /// that has no tunnel (ping, speed test; `VpnService.protect`) and the system resolver bound to
  /// the underlying network. They never enter the TUN, so no rule is involved.
  protectedSocket,

  /// 127.0.0.1 only (the sing-box API service, the probe / tunnel / mixed inbounds, free-port
  /// checks): never enters the TUN.
  loopback,

  /// Starts a local tool or asks the OS and opens no connection (`reg`, `id`, `sing-box version`,
  /// network-state callbacks). Listed so that a new use of a process API is looked at once.
  noConnection,
}

class OutsideEntry {
  const OutsideEntry(this.id, this.what, this.how, this.files);

  /// Stable name (also what the tests print).
  final String id;

  /// What it does, and what is asked from the tunnel's side.
  final String what;
  final OutsideHow how;

  /// Repo-relative paths of the sources that open the connection (or start the process).
  final List<String> files;
}

/// See the library comment. One entry per feature; a file may belong to several.
const outsideTunnel = <OutsideEntry>[
  // ── the app's own process: the self rule ──
  OutsideEntry(
    'subscription-fetch',
    'Subscription download and refresh (fetch.dart), direct or "via proxy" through tunnel-in: the direct '
        'one is the app\'s own connection, so it needs the self rule and a DNS that works with every node dead',
    OutsideHow.ownRule,
    ['core/lib/src/fetch.dart'],
  ),
  OutsideEntry(
    'ruleset-download',
    'Rule lists (rule sets, geo) downloaded by the core, direct or via tunnel-in',
    OutsideHow.ownRule,
    ['core/lib/src/rulesets.dart'],
  ),
  OutsideEntry(
    'app-update',
    'App update: feed manifest, delta and full download, direct or via tunnel-in',
    OutsideHow.ownRule,
    ['core/lib/src/appupdate.dart'],
  ),
  OutsideEntry(
    'exit-ip-check',
    'Public-IP services asked through the proxy port, or directly while disconnected',
    OutsideHow.ownRule,
    ['core/lib/src/exitip.dart'],
  ),
  OutsideEntry(
    'site-check',
    'The external site checker (what is down for everyone), direct or via tunnel-in',
    OutsideHow.ownRule,
    ['core/lib/src/sitecheck.dart'],
  ),
  OutsideEntry(
    'report-upload',
    'Send report: the encrypted report is POSTed to the receiving Worker (report_upload.dart, '
        'HttpReportUploader): a direct reachability probe first — a direct upload is needed exactly '
        'when the proxy is broken — and, when the probe finds no direct path while the tunnel is up, '
        'the upload goes via tunnel-in instead; the self rule and a DNS that works with every node dead',
    OutsideHow.ownRule,
    ['core/lib/src/report_upload.dart'],
  ),
  OutsideEntry(
    'dns-probe',
    'Settings → DNS pings: a real query from this machine straight to the server (UDP / TCP / DoT / DoH) '
        'and the system resolver; must reach the tested server, so the self rule stands before the '
        'DNS hijack of port 53 (only the tunnel\'s own resolver is hijacked first)',
    OutsideHow.ownRule,
    ['core/lib/src/dns_probe.dart'],
  ),
  OutsideEntry(
    'singbox-process',
    'Desktop: the sing-box processes the core starts (the connection, throwaway ping / speed-test ones); '
        'their path is in selfProcessPaths, so the helper instances go direct instead of looping',
    OutsideHow.ownRule,
    ['core/lib/src/runtime.dart'],
  ),

  // ── Android: kept out by the platform ──
  OutsideEntry(
    'android-tunnel-sockets',
    'The tunnel\'s libbox: every socket of sing-box (servers, direct outbounds) is protect()ed by the '
        'VpnService one by one (autoDetectInterfaceControl)',
    OutsideHow.protectedSocket,
    ['app/android_overlay/kotlin/JormungandVpnService.kt.tmpl'],
  ),
  OutsideEntry(
    'android-throwaway-boxes',
    'Libbox instances without a tunnel (latency tests, Speed Test, route checks): their sockets are '
        'protect()ed by the VpnService when it is up, so they measure the real path',
    OutsideHow.protectedSocket,
    [
      'app/android_overlay/kotlin/LibboxBox.kt.tmpl',
      'app/android_overlay/kotlin/LibboxPlatform.kt.tmpl',
      'app/android_overlay/kotlin/VpnChannel.kt.tmpl',
    ],
  ),
  OutsideEntry(
    'android-local-dns',
    'sing-box\'s `local` DNS server on Android: DnsResolver bound to the underlying (non-VPN) network',
    OutsideHow.protectedSocket,
    ['app/android_overlay/kotlin/LocalResolver.kt.tmpl'],
  ),

  // ── loopback ──
  OutsideEntry(
    'singbox-api',
    'The core\'s gRPC line to the sing-box API service (groups, connections, traffic, clash mode)',
    OutsideHow.loopback,
    ['core/lib/src/sbapi.dart'],
  ),
  OutsideEntry(
    'probe-inbound',
    'Latency / DNS / site probes: SOCKS5 + TLS + HTTP through the probe-in inbound',
    OutsideHow.loopback,
    ['core/lib/src/probe.dart'],
  ),
  OutsideEntry(
    'free-port',
    'Free-port search for the inbounds and the API service (binds 127.0.0.1)',
    OutsideHow.loopback,
    ['core/lib/src/runtime.dart'],
  ),

  // ── no connection of ours ──
  OutsideEntry(
    'singbox-version',
    '`sing-box version` for Settings → Data',
    OutsideHow.noConnection,
    ['core/lib/src/logbook.dart'],
  ),
  OutsideEntry(
    'desktop-os-tools',
    'Desktop: reg (system proxy, model name), id (elevation), powershell (killing the orphaned sing-box)',
    OutsideHow.noConnection,
    [
      'core/lib/src/device.dart',
      'core/lib/src/elevation.dart',
      'core/lib/src/killjob.dart',
      'core/lib/src/sysproxy.dart',
    ],
  ),
  OutsideEntry(
    'windows-file-dialog',
    'Windows: the backup\'s open / save dialogs through powershell',
    OutsideHow.noConnection,
    ['app/lib/platform/files_channel.dart'],
  ),
  OutsideEntry(
    'android-network-state',
    'Android: callbacks for the default network and its interfaces (libbox\'s monitor, the UI\'s '
        'network state); they ask the system, they open nothing',
    OutsideHow.noConnection,
    [
      'app/android_overlay/kotlin/DefaultNetworkMonitor.kt.tmpl',
      'app/android_overlay/kotlin/NetworkChannel.kt.tmpl',
    ],
  ),
];
