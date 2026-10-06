package dev.jormungand.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `jormungand/network` + EventChannel `jormungand/network_events` (Dart side:
 * lib/platform/network_channel.dart): is the network the phone really uses a metered one. Settings ->
 * Data "Auto-download" (Wi-Fi only) asks it; the core downloads an update only while it says "no".
 *
 *  metered -> Boolean   now
 *  events: Boolean      every change (and the current value at once on listen)
 *
 * Our own VPN declares itself unmetered, so `activeNetwork` would answer "unmetered" through a
 * cellular link while the tunnel is up. The answer is therefore taken from the underlying
 * (non-VPN) networks: unmetered = some validated internet network that is not a VPN has
 * NET_CAPABILITY_NOT_METERED.
 */
class NetworkChannel(private val app: Context) {
    companion object {
        const val NAME = "jormungand/network"
        const val EVENTS = "jormungand/network_events"
    }

    private val main = Handler(Looper.getMainLooper())
    private val cm: ConnectivityManager = app.getSystemService(ConnectivityManager::class.java)
    private var sink: EventChannel.EventSink? = null
    private var last: Boolean? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = recheck()
        override fun onLost(network: Network) = recheck()
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = recheck()
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler(::onCall)
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                last = null
                // the default request is NOT_VPN + NOT_RESTRICTED: the underlying networks only
                val request = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                runCatching { cm.registerNetworkCallback(request, callback) }
                recheck()
            }

            override fun onCancel(arguments: Any?) {
                runCatching { cm.unregisterNetworkCallback(callback) }
                sink = null
            }
        })
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "metered" -> result.success(metered())
            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun metered(): Boolean = try {
        val unmetered = cm.allNetworks.any { n ->
            val c = cm.getNetworkCapabilities(n)
            c != null &&
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        }
        !unmetered
    } catch (e: Throwable) {
        true // unknown: do not spend the user's traffic
    }

    private fun recheck() {
        // the callbacks come on a system thread, a capabilities change may be followed by more of them
        main.post {
            val s = sink ?: return@post
            val now = metered()
            if (now != last) {
                last = now
                s.success(now)
            }
        }
    }
}
