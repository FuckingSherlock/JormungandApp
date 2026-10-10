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

    private fun register(cm: ConnectivityManager) {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        when {
            Build.VERSION.SDK_INT >= 31 -> registerBestMatching(cm, request)
            // REQUEST, not LISTEN: only the network that is THE default (needs CHANGE_NETWORK_STATE).
            // Not registerDefaultNetworkCallback below 28: the app is inside the VPN, so the default
            // network is the VPN itself for it; the NOT_VPN request names the underlying one.
            else -> cm.requestNetwork(request, callback, handler)
        }
    }

    @android.annotation.TargetApi(31)
    private fun registerBestMatching(cm: ConnectivityManager, request: NetworkRequest) {
        cm.registerBestMatchingNetworkCallback(request, callback, handler)
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
