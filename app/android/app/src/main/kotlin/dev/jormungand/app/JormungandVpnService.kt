package dev.jormungand.app

import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.TunOptions
import java.net.InetAddress
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The tunnel: a foreground VpnService that runs libbox (sing-box) with the config the Dart core
 * built. The core stays the owner of the config (routing plan, rules, DNS, the `tun` inbound with
 * its addresses and routes); this class only opens the tun for libbox ([openTunInternal]) and
 * keeps the process alive.
 *
 * Lifecycle: VpnChannel `start` leaves a request in [VpnBridge] and starts the service; the
 * service starts libbox on its worker thread and answers the request (null = up, else the
 * reason). A second `start` while it runs restarts libbox inside the same service. `stop`
 * ([stopTunnel]) and the system revoking the VPN ([onRevoke]) close libbox, the tun and the
 * service; the revoke is also reported to Dart (event `stopped`).
 *
 * The app itself is INSIDE the VPN (never addDisallowedApplication of our own package; with a per-app
 * allow list ours is added to it): sing-box's `system` / `mixed` stacks terminate TCP in a listener of
 * this process, and a process outside the VPN would send the replies past the tun. Our own traffic
 * therefore enters the tun and the core's routing sends it out by its `package_name` rule (direct);
 * sing-box's own sockets (to the servers, direct outbounds) are protected one by one
 * ([LibboxPlatform.autoDetectInterfaceControl]), as are those of the throwaway libbox of a latency
 * test while a tunnel is up, so a ping still measures the real path.
 *
 * TODO: live speed in the notification text while connected (the text, "Disconnect" and the tap are in [AppNotifier]).
 */
class JormungandVpnService : VpnService() {
    companion object {
        const val ACTION_START = "dev.jormungand.app.vpn.START"

        /** The notification's Disconnect button (see [AppNotifier.vpnNotification]). */
        const val ACTION_DISCONNECT = "dev.jormungand.app.vpn.DISCONNECT"
        private const val TAG = "JormungandVpn"
        internal const val NOTIFICATION_ID = 1

        /** When the service last left (ms): Dart resends the name only when it changes, not on a restart. */
        @Volatile
        private var leftAt = 0L
        private const val NAME_KEPT_MS = 15_000L

        @Volatile
        var instance: JormungandVpnService? = null
            private set
    }

    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private var box: LibboxBox? = null

    @Volatile
    private var tunFd: ParcelFileDescriptor? = null

    @Volatile
    var isUp = false
        private set

    /** The tun is established (openTunInternal .. closeBoxLocked): only then does [protect] take a socket out of it. */
    internal val tunOpen: Boolean get() = tunFd != null

    /** Guards [started] / [onShade] with the calls into startForeground / stopForeground. */
    private val shadeLock = Any()

    /** Between entering the foreground in onStartCommand and [leave]. */
    private var started = false

    /** The service is a foreground one, i.e. its notification is on the shade. */
    private var onShade = false

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            disconnectFromNotification()
            return START_NOT_STICKY
        }
        // a start soon after a stop is a restart of the same connection (a new plan, a reconnect):
        // the name stays; a later one is another connection until Dart says where it goes (see [leave])
        if (System.currentTimeMillis() - leftAt > NAME_KEPT_MS) AppNotifier.vpnNode = null
        enterForeground() // within 5 s of startForegroundService, whatever happens next
        val request = VpnBridge.takePending()
        if (request == null) {
            leave() // started with nothing to do
        } else {
            worker.execute { startTunnel(request) }
        }
        // Not sticky: a restart without the Dart side could not rebuild the config.
        return START_NOT_STICKY
    }

    // Swiped from Recents: the tunnel stays (stopWithTask=false), and so does the engine with the Dart
    // core (AppEngine); nothing to do, the line is for the log
    override fun onTaskRemoved(rootIntent: Intent?) {
        VpnBridge.log("info", "tunnel: the app was swiped away, the tunnel keeps running")
        super.onTaskRemoved(rootIntent)
    }

    override fun onRevoke() {
        // The user (or another VPN app) took the VPN away.
        worker.execute {
            synchronized(lock) { closeBoxLocked() }
            ResumeStore.tunnelDown(applicationContext, "revoked") // taken away: not "on" for a later update
            VpnBridge.emit(mapOf("type" to "stopped", "reason" to "revoked"))
            leave()
        }
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        // for the resume trail: the service going away with no stop / revoke before it is what an update looks like
        ResumeStore.note(applicationContext, "service onDestroy (tunnel up: $isUp)")
        worker.execute { synchronized(lock) { closeBoxLocked() } }
        worker.shutdown()
        super.onDestroy()
    }

    /** Closes libbox and the tun, ends the service; [done] runs after that (a worker thread). */
    fun stopTunnel(done: () -> Unit) {
        worker.execute {
            synchronized(lock) { closeBoxLocked() }
            ResumeStore.tunnelDown(applicationContext, "stop") // switched off on purpose (dock, tile, notification)
            leave()
            done()
        }
    }

    private fun startTunnel(request: VpnBridge.Pending) {
        try {
            synchronized(lock) {
                closeBoxLocked()
                val b = LibboxBox(applicationContext, VpnPlatform(this), "tunnel")
                box = b
                b.start(request.config)
                isUp = true
            }
            TileBridge.refresh(this)
            ResumeStore.tunnelUp(applicationContext)
            request.done(null)
        } catch (e: Throwable) {
            Log.e(TAG, "start", e)
            synchronized(lock) { closeBoxLocked() }
            ResumeStore.tunnelDown(applicationContext, "start failed")
            request.done(e.message ?: e.toString())
            leave()
        }
    }

    private fun closeBoxLocked() {
        isUp = false
        VpnBridge.record = null // what Dart kept for taking this tunnel over is void with it
        TileBridge.refresh(this) // the Quick Settings tile follows the tunnel, Dart or not
        box?.stop()
        box = null
        runCatching { tunFd?.close() }
        tunFd = null
    }

    private fun leave() {
        // The name is kept for a restart (NAME_KEPT_MS): Dart sends it once per connection and stays
        // "connected" across a restart of the tunnel (new plan, adoption), so it would not send it again.
        leftAt = System.currentTimeMillis()
        synchronized(shadeLock) {
            started = false
            onShade = false
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        stopSelf()
    }

    /**
     * The Disconnect button: the Dart core owns the connection state (system proxy, journal, UI), so
     * it is asked to disconnect; when nobody answers (the app's engine is gone) the tunnel is closed here.
     */
    private fun disconnectFromNotification() {
        val dart = NotifyChannel.dart
        if (dart == null) {
            stopTunnel {}
            return
        }
        dart.invokeMethod("disconnect", null, object : MethodChannel.Result {
            override fun success(result: Any?) {}
            override fun error(code: String, message: String?, details: Any?) = stopTunnel {}
            override fun notImplemented() = stopTunnel {}
        })
    }

    /**
     * The notification again with what [AppNotifier] knows now: the entry / server Dart pushed and
     * whether it is to be on the shade at all (Settings -> Notifications). Hidden: the service drops
     * out of the foreground (the VPN keeps running, see [enterForeground]); shown again: it re-enters.
     */
    fun refreshNotification() {
        synchronized(shadeLock) {
            if (!started) return
            val want = AppNotifier.vpnShown(this)
            when {
                want && onShade ->
                    getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, AppNotifier.vpnNotification(this))
                want -> try {
                    startForegroundLocked()
                } catch (e: Throwable) {
                    // e.g. Android 12+ refusing a foreground start from the background: stays hidden
                    Log.w(TAG, "notification not shown", e)
                }
                else -> hideLocked()
            }
        }
    }

    /**
     * Foreground within 5 s of startForegroundService, whatever the user chose; with the notification
     * switched off it is dropped from the shade right after. The VPN keeps running: while the tunnel is
     * established the system itself binds this service (BIND_VPN_SERVICE) and the process keeps the
     * priority of a foreground one (as in WireGuard, which shows no notification at all).
     */
    private fun enterForeground() {
        synchronized(shadeLock) {
            started = true
            startForegroundLocked()
            if (!AppNotifier.vpnShown(this)) hideLocked()
        }
    }

    private fun startForegroundLocked() {
        val notification = AppNotifier.vpnNotification(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        onShade = true
    }

    private fun hideLocked() {
        if (!onShade) return
        stopForeground(STOP_FOREGROUND_REMOVE)
        onShade = false
    }

    /** libbox's openTun: the `tun` inbound's options -> a VpnService.Builder -> the descriptor. */
    internal fun openTunInternal(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("Jormungand")
            .setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        for (a in options.inet4Address.all()) builder.addAddress(a.address(), a.prefix())
        for (a in options.inet6Address.all()) builder.addAddress(a.address(), a.prefix())

        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dns = options.dnsServerAddress
                while (dns.hasNext()) builder.addDnsServer(dns.next())
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // routes and exclusions as the config says
                val v4 = options.inet4RouteAddress.all()
                if (v4.isNotEmpty()) {
                    for (r in v4) addRoute33(builder, r)
                } else if (options.inet4Address.all().isNotEmpty()) {
                    builder.addRoute("0.0.0.0", 0)
                }
                val v6 = options.inet6RouteAddress.all()
                if (v6.isNotEmpty()) {
                    for (r in v6) addRoute33(builder, r)
                } else if (options.inet6Address.all().isNotEmpty()) {
                    builder.addRoute("::", 0)
                }
                for (r in options.inet4RouteExcludeAddress.all()) excludeRoute33(builder, r)
                for (r in options.inet6RouteExcludeAddress.all()) excludeRoute33(builder, r)
            } else {
                // before Android 13 there is no excludeRoute: libbox computes the ranges that remain
                for (r in options.inet4RouteRange.all()) builder.addRoute(r.address(), r.prefix())
                for (r in options.inet6RouteRange.all()) builder.addRoute(r.address(), r.prefix())
            }

            // Our own package is never excluded (see the class comment): an exclude entry for it is
            // dropped, and in an allow list it is added, else the system stack's listener stays outside.
            val include = options.includePackage.allStrings()
            val exclude = options.excludePackage.allStrings()
            try {
                if (include.isNotEmpty()) {
                    for (p in (include + packageName).distinct()) allow(builder, p)
                } else {
                    for (p in exclude) {
                        if (p == packageName) {
                            VpnBridge.log("warn", "tunnel: the app's own package in exclude_package is ignored")
                        } else {
                            disallow(builder, p)
                        }
                    }
                }
            } catch (e: IllegalArgumentException) {
                Log.e(TAG, "per-app lists", e)
            }
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        runCatching { tunFd?.close() }
        tunFd = pfd
        VpnBridge.log("info", "tunnel: tun opened (fd ${pfd.fd}, mtu ${options.mtu}, auto route ${options.autoRoute})")
        return pfd.fd
    }

    private fun allow(builder: Builder, pkg: String) {
        try {
            builder.addAllowedApplication(pkg)
        } catch (e: NameNotFoundException) {
            Log.w(TAG, "addAllowedApplication $pkg", e)
        }
    }

    private fun disallow(builder: Builder, pkg: String) {
        try {
            builder.addDisallowedApplication(pkg)
        } catch (e: NameNotFoundException) {
            Log.w(TAG, "addDisallowedApplication $pkg", e)
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.TIRAMISU)
    private fun addRoute33(builder: Builder, r: RoutePrefix) {
        builder.addRoute(IpPrefix(InetAddress.getByName(r.address()), r.prefix()))
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.TIRAMISU)
    private fun excludeRoute33(builder: Builder, r: RoutePrefix) {
        builder.excludeRoute(IpPrefix(InetAddress.getByName(r.address()), r.prefix()))
    }
}

/** The tunnel's platform: [LibboxPlatform] plus the tun and socket protection from the service. */
class VpnPlatform(private val service: JormungandVpnService) : LibboxPlatform(service) {
    // protect() itself is [LibboxPlatform.autoDetectInterfaceControl]; the tunnel always has its service
    override fun protector(): VpnService = service

    override fun openTun(options: TunOptions): Int = service.openTunInternal(options)
}

private fun io.nekohasekai.libbox.RoutePrefixIterator.all(): List<RoutePrefix> {
    val out = mutableListOf<RoutePrefix>()
    while (hasNext()) out.add(next())
    return out
}

private fun io.nekohasekai.libbox.StringIterator.allStrings(): List<String> {
    val out = mutableListOf<String>()
    while (hasNext()) out.add(next())
    return out
}
