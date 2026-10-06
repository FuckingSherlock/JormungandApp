package dev.jormungand.app

import android.content.Context
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * MethodChannel `jormungand/apps` (Dart side: lib/platform/apps_io.dart): the installed apps for
 * Rules -> Per-app routing.
 *
 *  list -> List    every installed app but this one: [{pkg, name, system}]. The whole list, not only the
 *                  launchable apps: the System filter shows Play services, the download manager... which
 *                  have no launcher icon; Android 11+ hides those without QUERY_ALL_PACKAGES (manifest).
 *  icon -> bytes?  args {pkg}: the app's icon as a 96 px PNG, null when it has none
 *
 * Icons are asked for one per visible row: they go through two threads, never one thread per row.
 */
class AppsChannel(private val context: Context) {
    companion object {
        const val NAME = "jormungand/apps"
        private const val ICON_SIZE = 96
    }

    private val main = Handler(Looper.getMainLooper())
    private val lister = Executors.newSingleThreadExecutor()
    private val icons = Executors.newFixedThreadPool(2)

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler(::onCall)
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> lister.execute {
                try {
                    val pm = context.packageManager
                    val list = pm.getInstalledApplications(0)
                        .filter { it.packageName != context.packageName }
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
            "icon" -> {
                val pkg = call.argument<String>("pkg")
                if (pkg.isNullOrEmpty()) {
                    result.success(null)
                    return
                }
                icons.execute {
                    val png = try {
                        val d = context.packageManager.getApplicationIcon(pkg)
                        val bmp = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
                        d.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
                        d.draw(Canvas(bmp))
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                        bmp.recycle()
                        out.toByteArray()
                    } catch (e: Throwable) {
                        null // not installed any more, or an icon that cannot be drawn: the letter tile stays
                    }
                    main.post { result.success(png) }
                }
            }
            else -> result.notImplemented()
        }
    }
}
