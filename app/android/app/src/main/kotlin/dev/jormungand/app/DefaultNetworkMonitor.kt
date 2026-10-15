package dev.jormungand.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.NetworkInterface

/**
 * The default (non-VPN) network, which libbox needs to bind its sockets to and to resolve DNS
 * through. One monitor for every libbox in the process (the tunnel and the throwaway ones for
 * pings): it listens to the system while at least one libbox listens to it.
 *
 * The request carries NOT_VPN (the Builder default), so the answer is the underlying network even
 * while our own VPN is up. Follows sing-box-for-android's DefaultNetworkListener / Monitor.
 */
object DefaultNetworkMonitor {
    private const val TAG = "DefaultNetwork"

    @Volatile
    var defaultNetwork: Network? = null
        private set

    private val lock = Any()
    private val listeners = LinkedHashSet<InterfaceUpdateListener>()
    private var connectivity: ConnectivityManager? = null
    private var registered = false
    private val handler: Handler by lazy {
        Handler(HandlerThread("jorm-network").apply { start() }.looper)
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            defaultNetwork = network
            publish(network)
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            if (network == defaultNetwork) publish(network)
        }

        override fun onLost(network: Network) {
            if (network == defaultNetwork) {
                defaultNetwork = null
                publish(null)
            }
        }
    }

    fun add(context: Context, listener: InterfaceUpdateListener) {
        val network: Network?
        synchronized(lock) {
            val cm = connectivity ?: context.applicationContext
                .getSystemService(ConnectivityManager::class.java).also { connectivity = it }
            listeners.add(listener)
            if (!registered) {
                register(cm)
                registered = true
                // until the callback answers: the underlying network (our own VPN is never the answer)
                if (defaultNetwork == null) defaultNetwork = underlyingActive(cm)
                VpnBridge.log("debug", "network: monitor on, default ${defaultNetwork ?: "unknown yet"}")
            }
            network = defaultNetwork
        }
        // the first answer to a new listener must not wait for the next change
        if (network != null) publishTo(listener, network)
    }

    fun remove(listener: InterfaceUpdateListener) {
        synchronized(lock) {
            listeners.remove(listener)
            if (listeners.isEmpty() && registered) {
                runCatching { connectivity?.unregisterNetworkCallback(callback) }
                registered = false
                defaultNetwork = null
            }
        }
    }

    /**
     * A first guess until the callback answers. The app is inside the VPN, so while the tunnel is up
     * `activeNetwork` is the VPN itself for it: then the best of the other networks (validated first,
     * the fastest transport first) stands in.
     */
    @Suppress("DEPRECATION")
    private fun underlyingActive(cm: ConnectivityManager): Network? {
        fun underlying(n: Network): NetworkCapabilities? {
            val caps = cm.getNetworkCapabilities(n) ?: return null
            val ok = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            return if (ok) caps else null
        }
        cm.activeNetwork?.let { if (underlying(it) != null) return it }
        return try {
            cm.allNetworks
                .mapNotNull { n -> underlying(n)?.let { n to it } }
                .maxByOrNull { (_, c) ->
                    var score = 0
                    if (c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 10
                    if (c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) score += 3
                    if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) score += 2
                    if (c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) score += 1
                    score
                }?.first
        } catch (e: Exception) {
            null
        }
    }

    private fun register(cm: ConnectivityManager, cb: ConnectivityManager.NetworkCallback = callback) {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        when {
            Build.VERSION.SDK_INT >= 31 -> registerBestMatching(cm, request, cb)
            // REQUEST, not LISTEN: only the network that is THE default (needs CHANGE_NETWORK_STATE).
            // Not registerDefaultNetworkCallback below 28: the app is inside the VPN, so the default
            // network is the VPN itself for it; the NOT_VPN request names the underlying one.
            else -> cm.requestNetwork(request, cb, handler)
        }
    }

    @android.annotation.TargetApi(31)
    private fun registerBestMatching(cm: ConnectivityManager, request: NetworkRequest, cb: ConnectivityManager.NetworkCallback) {
        cm.registerBestMatchingNetworkCallback(request, cb, handler)
    }

    // ── the network's identity for the core (CoreApi.setNetwork, docs/failures.md → network context) ──
    // A watcher of its own, apart from the libbox listeners above: it runs while Dart listens (NetworkChannel
    // `jormungand/network_state`), tunnel up or not. The same NOT_VPN request: the underlying network, never our VPN.

    private val stateLock = Any()
    private val stateListeners = LinkedHashSet<(Map<String, Any?>) -> Unit>()
    private var stateConnectivity: ConnectivityManager? = null
    private var stateRegistered = false
    @Volatile
    private var stateNetwork: Network? = null
    private var stateLast: Map<String, Any?>? = null

    private val stateCallback = object : ConnectivityManager.NetworkCallback() {
        // `at`: the moment the system called back (wall-clock ms), taken first thing: the core classifies the failures of
        // connections by it (a connection that closed after it is the network's), not by when this message reaches it.
        override fun onAvailable(network: Network) {
            val at = System.currentTimeMillis()
            synchronized(stateLock) { stateNetwork = network }
            publishState(at)
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            val at = System.currentTimeMillis()
            if (network == stateNetwork) publishState(at)
        }

        override fun onLost(network: Network) {
            val at = System.currentTimeMillis()
            val mine = synchronized(stateLock) {
                if (network == stateNetwork) {
                    stateNetwork = null
                    true
                } else {
                    false
                }
            }
            if (mine) publishState(at)
        }
    }

    /**
     * Starts [listener] on the state of the underlying default network, the current one at once, then on
     * every change: `{connected, validated, captive, type (wifi | cellular | ethernet | vpn | other), id, at}`.
     * `id` is `Network.getNetworkHandle()` as a string: another Wi-Fi is another id on the same `wlan0`. `at` is the
     * wall-clock ms at which the system called back (`onLost` / `onAvailable` / `onCapabilitiesChanged`); for the first
     * answer, the moment of the call. It is not part of the state compared for repeats.
     * The first answer comes on the caller's thread, the later ones on the monitor's own thread.
     */
    fun addStateListener(context: Context, listener: (Map<String, Any?>) -> Unit) {
        val at = System.currentTimeMillis()
        val now: Map<String, Any?>
        synchronized(stateLock) {
            val cm = stateConnectivity ?: context.applicationContext
                .getSystemService(ConnectivityManager::class.java).also { stateConnectivity = it }
            stateListeners.add(listener)
            if (!stateRegistered) {
                register(cm, stateCallback)
                stateRegistered = true
                stateNetwork = underlyingActive(cm)
                stateLast = null
            }
            now = stateNow()
            if (stateLast == null) stateLast = now
        }
        listener(now + ("at" to at))
    }

    fun removeStateListener(listener: (Map<String, Any?>) -> Unit) {
        synchronized(stateLock) {
            stateListeners.remove(listener)
            if (stateListeners.isEmpty() && stateRegistered) {
                runCatching { stateConnectivity?.unregisterNetworkCallback(stateCallback) }
                stateRegistered = false
                stateNetwork = null
                stateLast = null
            }
        }
    }

    private fun publishState(at: Long) {
        val targets: List<(Map<String, Any?>) -> Unit>
        val now: Map<String, Any?>
        synchronized(stateLock) {
            now = stateNow()
            if (now == stateLast) return
            stateLast = now
            targets = stateListeners.toList()
        }
        val told = now + ("at" to at)
        VpnBridge.log("debug", "network: state $told")
        for (l in targets) l(told)
    }

    /** Under [stateLock]. No network (or one that has just gone) = `connected: false`. */
    private fun stateNow(): Map<String, Any?> {
        val network = stateNetwork
        val caps = if (network == null) null else try {
            stateConnectivity?.getNetworkCapabilities(network)
        } catch (e: Exception) {
            null
        }
        if (network == null || caps == null) return mapOf("connected" to false)
        val type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
        return mapOf(
            "connected" to true,
            "validated" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            "captive" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL),
            "type" to type,
            "id" to network.networkHandle.toString(),
        )
    }

    private fun publish(network: Network?) {
        val targets = synchronized(lock) { listeners.toList() }
        for (l in targets) publishTo(l, network)
    }

    private fun publishTo(listener: InterfaceUpdateListener, network: Network?) {
        if (network == null) {
            VpnBridge.log("warn", "network: no default network")
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        val cm = connectivity ?: return
        // the link properties lag behind onAvailable for a moment
        for (attempt in 0 until 10) {
            val name = cm.getLinkProperties(network)?.interfaceName
            val index = try {
                if (name == null) null else NetworkInterface.getByName(name)?.index
            } catch (e: Exception) {
                null
            }
            if (name != null && index != null) {
                VpnBridge.log("debug", "network: default is $name (index $index)")
                listener.updateDefaultInterface(name, index, false, false)
                return
            }
            Thread.sleep(100)
        }
        VpnBridge.log("warn", "network: no interface for the default network $network (link properties missing)")
    }
}
