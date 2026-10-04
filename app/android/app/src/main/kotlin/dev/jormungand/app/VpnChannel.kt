package dev.jormungand.app

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * What the service and the channel hand each other: the pending start request and the event sink.
 * Same process, so the config (can be megabytes: a Binder extra would not carry it) never leaves
 * memory.
 */
object VpnBridge {
    class Pending(val config: String, val done: (String?) -> Unit)

    @Volatile
    var sink: EventChannel.EventSink? = null

    private var pending: Pending? = null
    private val main = Handler(Looper.getMainLooper())

    @Synchronized
    fun begin(p: Pending) {
        pending?.done?.invoke("replaced by a newer start")
        pending = p
    }

    @Synchronized
    fun takePending(): Pending? = pending.also { pending = null }

    fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
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
 *  status   -> Map      {running: Boolean} (the tunnel)
 *  apps     -> List     the installed apps: [{pkg, name, system}] (Rules -> Per-app routing)
 *  appIcon  -> bytes?   args {pkg}: the app's icon as a 96 px PNG, null when it has none
 *
 *  events: {type: 'stopped', reason: 'revoked'} — the tunnel went away on its own (the user or
 *  another VPN app took the VPN away). A plain `stop` does not send one.
 *
 * TODO: request POST_NOTIFICATIONS (Android 13+) before the first start.
 */
class VpnChannel(private val activity: Activity) {
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
                val intent = Intent(activity, JormungandVpnService::class.java)
                    .setAction(JormungandVpnService.ACTION_START)
                activity.startForegroundService(intent) // minSdk 26
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
                    val box = LibboxBox(activity.applicationContext, LibboxPlatform(activity.applicationContext))
                    try {
                        boxes.remove(id)?.stop()
                        box.start(config)
                        boxes[id] = box
                        main.post { result.success(null) }
                    } catch (e: Throwable) {
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
            "status" -> result.success(mapOf("running" to (JormungandVpnService.instance?.isUp == true)))
            // the update feed's asset keys come from this (docs/updates.md: updatePlatforms)
            "abis" -> result.success(android.os.Build.SUPPORTED_ABIS.toList())
            // the installed version (versionName / versionCode) the updater compares against
            "appVersion" -> {
                @Suppress("DEPRECATION")
                val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
                @Suppress("DEPRECATION")
                val code = if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                result.success(mapOf("name" to (info.versionName ?: ""), "code" to code))
            }
            // Rules -> Per-app routing: the installed apps, then their icons one by one
            "apps" -> io.execute {
                try {
                    val pm = activity.packageManager
                    val list = pm.getInstalledApplications(0)
                        .filter { it.packageName != activity.packageName }
                        .map {
                            // a system app the user has updated (Chrome, Play services) counts as a user one
                            val sys = (it.flags and ApplicationInfo.FLAG_SYSTEM) != 0 &&
                                (it.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) == 0
                            mapOf("pkg" to it.packageName, "name" to pm.getApplicationLabel(it).toString(), "system" to sys)
                        }
                    main.post { result.success(list) }
                } catch (e: Throwable) {
                    main.post { result.error("apps_failed", e.message ?: e.toString(), null) }
                }
            }
            "appIcon" -> {
                val pkg = call.argument<String>("pkg")
                if (pkg.isNullOrEmpty()) {
                    result.success(null)
                    return
                }
                io.execute {
                    val png = try {
                        val d = activity.packageManager.getApplicationIcon(pkg)
                        val size = 96
                        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                        d.setBounds(0, 0, size, size)
                        d.draw(Canvas(bmp))
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                        out.toByteArray()
                    } catch (e: Throwable) {
                        null
                    }
                    main.post { result.success(png) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        val consent = VpnService.prepare(activity)
        if (consent == null) {
            result.success(true) // already granted
            return
        }
        pendingPrepare?.success(false) // a second ask replaces the first
        pendingPrepare = result
        activity.startActivityForResult(consent, REQUEST_PREPARE)
    }

    /** Called from MainActivity.onActivityResult; true when the request code was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_PREPARE) return false
        pendingPrepare?.success(resultCode == Activity.RESULT_OK)
        pendingPrepare = null
        return true
    }
}
