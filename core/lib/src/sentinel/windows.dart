/// How long each detector's failure must last before the Sentinel may call it real: the persistence
/// windows (docs/failures.md → Окна). One place, one constant per kind; the tests use [instant].
library;

/// The longest a suspicion is parked behind a failed node (docs/failures.md -> Парковка); after it: `deferred`,
/// `parked.expired`, nothing is written.
const parkLimit =Duration(minutes: 10);

class FailureWindows {
  const FailureWindows({
    this.connFailing = const Duration(seconds: 10),
    this.connLost = const Duration(seconds: 12),
    this.tunTcpDead = const Duration(seconds: 10),
    this.autoUnstable = Duration.zero,
    this.siteBlocked = Duration.zero,
    this.siteUnreachable = Duration.zero,
    this.netBlip = const Duration(seconds: 10),
    this.siteChecker = const Duration(seconds: 40),
    this.dnsDown = const Duration(seconds: 1),
  });

  /// Every window zero: a failure is judged at once (the tests).
  const FailureWindows.instant()
      : connFailing = Duration.zero,
        connLost = Duration.zero,
        tunTcpDead = Duration.zero,
        autoUnstable = Duration.zero,
        siteBlocked = Duration.zero,
        siteUnreachable = Duration.zero,
        netBlip = Duration.zero,
        siteChecker = const Duration(seconds: 40),
        dnsDown = Duration.zero;

  /// `conn/failing`: counted from the first failure of the streak (the streak itself is up to 60 s).
  final Duration connFailing;

  /// `conn/lost`: no route answers (Auto has already waited its own rounds).
  final Duration connLost;

  /// `core/tunTcpDead`: counted from the first orphaned look-up of the dead window.
  final Duration tunTcpDead;

  /// `auto/unstable`: Auto's flap guard has counted the drops already.
  final Duration autoUnstable;

  /// `site/blocked`, `site/unreachable`: Auto re-tried the site itself before it told, so no wait.
  final Duration siteBlocked, siteUnreachable;

  /// `conn/offline`: the network has to stay gone this long to be an event; shorter, the journal gets a `blip`.
  final Duration netBlip;

  /// The external site checker's own limit (it polls for up to 20 s).
  final Duration siteChecker;

  /// `dns/failed`: a DNS server missed; counted from its first miss. The same as the failover's old rule
  /// «down after `failAfter` misses, `retryPause` apart» at the defaults (2 x 0.5 s).
  final Duration dnsDown;

  Map<String, dynamic> toJson() => {
        'dnsDown': dnsDown.inMilliseconds,
        'connFailing': connFailing.inMilliseconds,
        'connLost': connLost.inMilliseconds,
        'tunTcpDead': tunTcpDead.inMilliseconds,
        'autoUnstable': autoUnstable.inMilliseconds,
        'siteBlocked': siteBlocked.inMilliseconds,
        'siteUnreachable': siteUnreachable.inMilliseconds,
        'netBlip': netBlip.inMilliseconds,
        'siteChecker': siteChecker.inMilliseconds,
      };
}
