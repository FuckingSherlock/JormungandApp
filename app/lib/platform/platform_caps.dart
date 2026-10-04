import '../core/core_host.dart';

/// What this platform's build of the app can do: the one place that knows the difference between
/// Android and the desktop, so pages ask `host.caps.systemProxy` instead of checking the platform
/// themselves (and tests fake it with `FakeCoreHost(android: true)`).
///
/// Android is always the VPN (the VpnService is the TUN, there is nothing like the Windows system
/// proxy), so everything that exists only for the system proxy or for the TUN | Proxy choice is
/// hidden there. Everything else of Settings is the same on both.
class PlatformCaps {
  const PlatformCaps({required this.android});

  final bool android;

  /// Home: the Sys proxy switch; Settings -> Connection: the System proxy row.
  bool get systemProxy => !android;

  /// Home: the TUN | Proxy switch (Android is always TUN).
  bool get tunSwitch => !android;

  /// Settings -> Connection: the Kill switch group (kill switch, also after disconnect, also while
  /// the app is closed, remove the proxy when the VPN cannot recover). The core's kill switch
  /// works through the system proxy, which Android does not have.
  bool get killSwitch => !android;

  /// Settings -> DNS: "Without TUN -> Resolve for IP rules" exists for the proxy port and the
  /// system proxy, i.e. only where TUN can be off.
  bool get dnsResolveForIp => !android;

  /// Nodes -> + -> Scan QR code: the camera scanner (flutter_zxing over the `camera` plugin) is
  /// wired for Android only; on the desktop the QR of a screenshot goes through Import config file.
  bool get cameraScan => android;
}

extension HostCaps on CoreHost {
  PlatformCaps get caps => PlatformCaps(android: isAndroid);
}
