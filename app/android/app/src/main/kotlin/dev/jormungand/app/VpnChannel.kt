package dev.jormungand.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import io.nekohasekai.libbox.Libbox
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * What the service and the channel hand each other: the pending start request and the event sink.
 * Same process, so the config (can be megabytes: a Binder extra would not carry it) never leaves
 * memory.
 */
object VpnBridge {
    class Pending(val config: String, val done: (String?) -> Unit)

    // Dart's listener comes and goes; what is said meanwhile waits (the newest [KEEP]) for the next one
    private val waiting = ArrayDeque<Map<String, Any?>>()
    private const val KEEP = 300

    @Volatile
    var sink: EventChannel.EventSink? = null
        set(value) {
            field = value
            if (value != null) {
                main.post {
                    val now = synchronized(waiting) { waiting.toList().also { waiting.clear() } }
                    for (e in now) value.success(e)
                }
            }
        }

    private var pending: Pending? = null
    private val main = Handler(Looper.getMainLooper())

    /**
     * What the Dart core kept next to the running tunnel (`remember`): the plan and ports a new
     * engine needs to take the tunnel over. Opaque to Kotlin. It lives exactly as long as the tunnel
     * ([JormungandVpnService] clears it when libbox closes), so it can never describe a tunnel that
     * is gone.
     */
    @Volatile
    var record: String? = null

    /**
     * A line for the app's raw log (Dart: `[android] <text>`), and for logcat. [level]: debug, info, warn, error.
     * The native side has no log of its own that the user can see, and a failed ping or a silent
     * network is the kind of thing only these lines explain.
     */
    fun log(level: String, text: String) {
        when (level) {
            "error" -> android.util.Log.e("Jormungand", text)
            "warn" -> android.util.Log.w("Jormungand", text)
            else -> android.util.Log.i("Jormungand", text)
        }
        emit(mapOf("type" to "log", "level" to level, "text" to text))
    }

    @Synchronized
    fun begin(p: Pending) {
        pending?.done?.invoke("replaced by a newer start")
        pending = p
    }

    @Synchronized
    fun takePending(): Pending? = pending.also { pending = null }

    fun emit(event: Map<String, Any?>) {
        main.post {
            val s = sink
            if (s != null) {
                s.success(event)
            } else {
                synchronized(waiting) {
                    waiting.addLast(event)
                    while (waiting.size > KEEP) waiting.removeFirst()
                }
            }
        }
    }
}

/**
 * MethodChannel `jormungand/vpn` + EventChannel `jormungand/vpn_events`
 * (Dart side: lib/platform/vpn_channel.dart).
 *
 *  prepare  -> Boolean  VPN consent: true when the app may start the VPN (asks the system dialog if needed)
 *  start    -> null     args {config: String}: starts / restarts the tunnel (JormungandVpnService, libbox)
 *                       and answers when sing-box is up; error `start_failed` carries sing-box's reason
 *  stop     -> null     closes the tunnel and the service, answers when done
 *  startBox -> null     args {id: String, config: String}: a throwaway libbox WITHOUT a tunnel (latency
 *                       tests, Speed Test) under [id]; answers when it is up
 *  stopBox  -> null     args {id}
 *  status   -> Map      {running: Boolean, record: String?} (the tunnel; the record `remember` kept for it)
 *  remember -> null     args {record: String}: kept with the running tunnel (dropped when it stops); a new
 *                       engine takes the tunnel over from it instead of starting another one
 *
 *  events: {type: 'stopped', reason: 'revoked'} — the tunnel went away on its own (the user or
 *  another VPN app took the VPN away). A plain `stop` does not send one.
 *
 * The notification permission (Android 13+) and the system notifications are NotifyChannel's.
 */
class VpnChannel(private val app: Context) {
    companion object {
        const val NAME = "jormungand/vpn"
        const val EVENTS = "jormungand/vpn_events"
        private const val REQUEST_PREPARE = 0x4A4D // "JM"
    }

    private var pendingPrepare: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private val boxes = ConcurrentHashMap<String, LibboxBox>()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler(::onCall)
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                VpnBridge.sink = events
            }

            override fun onCancel(arguments: Any?) {
                VpnBridge.sink = null
            }
        })
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepare(result)
            "start" -> {
                val config = call.argument<String>("config")
                if (config.isNullOrEmpty()) {
                    result.error("bad_args", "config is empty", null)
                    return
                }
                VpnBridge.begin(
                    VpnBridge.Pending(config) { err ->
                        main.post {
                            if (err == null) result.success(null) else result.error("start_failed", err, null)
                        }
                    },
                )
                val intent = Intent(app, JormungandVpnService::class.java)
                    .setAction(JormungandVpnService.ACTION_START)
                try {
                    app.startForegroundService(intent) // minSdk 26
                } catch (e: Throwable) {
                    // e.g. Android 12+ refusing a foreground service started from the background
                    VpnBridge.takePending()?.done?.invoke("the VPN service could not be started: ${e.message ?: e}")
                }
            }
            "stop" -> {
                val service = JormungandVpnService.instance
                if (service == null) {
                    result.success(null)
                } else {
                    service.stopTunnel { main.post { result.success(null) } }
                }
            }
            "startBox" -> {
                val id = call.argument<String>("id")
                val config = call.argument<String>("config")
                if (id.isNullOrEmpty() || config.isNullOrEmpty()) {
                    result.error("bad_args", "id and config are required", null)
                    return
                }
                io.execute {
                    val box = LibboxBox(app, LibboxPlatform(app), id)
                    try {
                        boxes.remove(id)?.stop()
                        box.start(config)
                        boxes[id] = box
                        main.post { result.success(null) }
                    } catch (e: Throwable) {
                        VpnBridge.log("error", "$id: startBox failed: ${e.javaClass.simpleName}: ${e.message}")
                        main.post { result.error("start_failed", e.message ?: e.toString(), null) }
                    }
                }
            }
            "stopBox" -> {
                val id = call.argument<String>("id")
                val box = if (id == null) null else boxes.remove(id)
                if (box == null) {
                    result.success(null)
                } else {
                    io.execute {
                        box.stop()
                        main.post { result.success(null) }
                    }
                }
            }
            "status" -> {
                val up = JormungandVpnService.instance?.isUp == true
                result.success(mapOf("running" to up, "record" to (if (up) VpnBridge.record else null)))
            }
            "remember" -> {
                // only for a tunnel that is up: a record outliving it would be a lie
                if (JormungandVpnService.instance?.isUp == true) VpnBridge.record = call.argument<String>("record")
                result.success(null)
            }
            // the update feed's asset keys come from this (docs/updates.md: updatePlatforms)
            "abis" -> result.success(android.os.Build.SUPPORTED_ABIS.toList())
            // the device for the support report (model, manufacturer, Android release and API level)
            "device" -> result.success(
                mapOf(
                    "model" to android.os.Build.MODEL,
                    "manufacturer" to android.os.Build.MANUFACTURER,
                    "brand" to android.os.Build.BRAND,
                    "androidApi" to android.os.Build.VERSION.SDK_INT,
                    "androidRelease" to android.os.Build.VERSION.RELEASE,
                ),
            )
            // the sing-box version inside libbox (Settings -> Data); null when it cannot be read
            "libboxVersion" -> result.success(runCatching { Libbox.version() }.getOrNull())
            // the installed version (versionName / versionCode) the updater compares against
            "appVersion" -> {
                @Suppress("DEPRECATION")
                val info = app.packageManager.getPackageInfo(app.packageName, 0)
                @Suppress("DEPRECATION")
                val code = if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                result.success(mapOf("name" to (info.versionName ?: ""), "code" to code))
            }
            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        val consent = VpnService.prepare(app)
        if (consent == null) {
            result.success(true) // already granted
            return
        }
        val window = AppEngine.activity
        if (window == null) {
            result.success(false) // the consent dialog needs a window; the app is not on screen
            return
        }
        pendingPrepare?.success(false) // a second ask replaces the first
        pendingPrepare = result
        window.startActivityForResult(consent, REQUEST_PREPARE)
    }

    /** Called from MainActivity.onActivityResult; true when the request code was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_PREPARE) return false
        pendingPrepare?.success(resultCode == Activity.RESULT_OK)
        pendingPrepare = null
        return true
    }
}
