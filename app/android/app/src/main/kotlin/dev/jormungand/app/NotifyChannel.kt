package dev.jormungand.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `jormungand/notify` (Dart side: lib/platform/notify_channel.dart): the system
 * notifications. The notifications themselves are built by [AppNotifier].
 *
 *  permission    -> String  `granted` | `denied` (the Android 13 permission and the system switch together)
 *  request       -> String  args {once: Boolean}: asks for POST_NOTIFICATIONS (API 33+; before it only
 *                           reports); with `once` the dialog is shown at most once per install, so a
 *                           plain connect never nags. Answers with the state after the dialog
 *  openSettings  -> null    the app's system notification settings
 *  post          -> null    args {id: Int, title, text, actions?: [{id, label}], site?, via?, ignoredText?,
 *                           undoLabel?}: a journal event as a notification (grouped); a button opens the app and
 *                           comes back as `eventAct`, except `ignore`: that one works without the app
 *                           ([EventActionReceiver]; [ignoredText] / [undoLabel] are the texts it shows)
 *  takeIgnoreOps -> List<Map> [{op: ignore | unignore, site}] the «Ignore site» / «Undo» choices made on the shade
 *                           since the last call, in order (the queue is emptied)
 *  cancelEvent   -> null    args {id: Int}: removes that one event's notification (the summary follows)
 *  cancelEvents  -> null    removes the event notifications (the app came to the front)
 *  setStatus     -> null    args {node: String?, visible: Boolean}, either key optional: the entry / server
 *                           shown in the VPN notification; whether it is on the shade at all (kept natively,
 *                           the service obeys it with no Dart; hidden = the service leaves the foreground)
 *  takeLaunchEvent -> Int?  the event id of the notification that started / raised the app and has not
 *                           been handed over yet; the first call also tells Kotlin that Dart listens
 *
 *  takeLaunchAction -> Map? {id, act, site, via} of a button that started / raised the app and was not
 *                           handed over yet (what `eventAct` is when Dart is listening)
 *
 *  postUpdate    -> null    args {title, text, install: Boolean, installLabel, file?}: the app's own update ("Update
 *                           available" / "Update ready · Install") in its own slot ([AppNotifier.postUpdate]);
 *                           a tap opens the app at the update block. With `install` and `file` (the downloaded APK)
 *                           the button goes to the system installer with no window ([UpdateInstallActivity]);
 *                           `install` alone: the button opens the app, which starts the installer
 *  updateAnnounced / setUpdateAnnounced {version} -> String? / null  the version the user was last told about
 *                           (native record, shared with the background job: one notification per version)
 *  takeLaunchUpdate -> Bool? the update notification that started the app and was not handed over yet (install?)
 *
 *  Kotlin -> Dart: `openEvent` (Int; a tap on an event notification while Dart listens), `eventAct`
 *  (Map {id, act, site, via}; a button of an event notification while Dart listens) and
 *  `openUpdate` (Bool install; a tap on the update notification while Dart listens),
 *  `ignoreQueued` (no args; [EventActionReceiver] queued a choice, Dart reads it with `takeIgnoreOps`) and
 *  `disconnect` (the VPN notification's action; Dart answers true, any error = nobody listens and the
 *  service closes the tunnel itself, see [AppNotifier] / [JormungandVpnService]).
 */
class NotifyChannel(private val app: Context) {
    companion object {
        const val NAME = "jormungand/notify"
        private const val REQUEST_POST = 0x4A4F
        private const val PREFS = "jorm_notify"
        private const val ASKED = "asked"

        /** The live channel to Dart, or null while the Flutter engine is not there. */
        @Volatile
        var dart: MethodChannel? = null
    }

    private var pendingRequest: MethodChannel.Result? = null
    private var launchEvent: Int? = null
    private var launchAct: Map<String, Any>? = null
    private var launchUpdate: Boolean? = null // an update notification started the app: lead to install?
    private var dartReady = false

    /**
     * [primary]: the app's engine, the one Kotlin talks to ([dart]). The background update job's own
     * engine registers the channel only to post its notification and keep the "announced" record
     * ([UpdateJob]); it must not take [dart] over from the app.
     */
    fun register(messenger: BinaryMessenger, primary: Boolean = true) {
        val ch = MethodChannel(messenger, NAME)
        ch.setMethodCallHandler(::onCall)
        if (primary) dart = ch
    }

    fun unregister() {
        dart = null
    }

    private fun state() = if (AppNotifier.allowed(app)) "granted" else "denied"

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permission" -> result.success(state())
            "request" -> request(call.argument<Boolean>("once") == true, result)
            "openSettings" -> {
                val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
                runCatching { app.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                    .onFailure { VpnBridge.log("warn", "notifications: settings not opened: ${it.message}") }
                result.success(null)
            }
            "post" -> {
                val id = call.argument<Int>("id")
                if (id == null) {
                    result.error("bad_args", "id is required", null)
                    return
                }
                val actions = (call.argument<List<Map<String, Any?>>>("actions") ?: emptyList())
                    .mapNotNull { m ->
                        val aid = m["id"] as? String
                        val label = m["label"] as? String
                        if (aid == null || label == null) null else aid to label
                    }
                AppNotifier.postEvent(
                    app,
                    id,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("text") ?: "",
                    actions,
                    call.argument<String>("site") ?: "",
                    call.argument<String>("via") ?: "",
                    call.argument<String>("ignoredText") ?: "",
                    call.argument<String>("undoLabel") ?: "",
                )
                result.success(null)
            }
            "cancelEvent" -> {
                call.argument<Int>("id")?.let { AppNotifier.cancelEvent(app, it) }
                result.success(null)
            }
            "cancelEvents" -> {
                AppNotifier.cancelEvents(app)
                result.success(null)
            }
            "setStatus" -> {
                // each key only when it is sent: Dart sends the visibility alone while disconnected
                if (call.hasArgument("node")) AppNotifier.vpnNode = call.argument<String>("node")?.takeIf { it.isNotEmpty() }
                call.argument<Boolean>("visible")?.let { AppNotifier.setVpnShown(app, it) }
                JormungandVpnService.instance?.refreshNotification()
                result.success(null)
            }
            "takeLaunchEvent" -> {
                dartReady = true
                result.success(launchEvent)
                launchEvent = null
            }
            "takeLaunchAction" -> {
                result.success(launchAct)
                launchAct = null
            }
            "takeIgnoreOps" -> result.success(IgnoreQueue.take(app))
            "postUpdate" -> {
                AppNotifier.postUpdate(
                    app,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("text") ?: "",
                    call.argument<Boolean>("install") == true,
                    call.argument<String>("installLabel") ?: "",
                    call.argument<String>("file") ?: "",
                )
                result.success(null)
            }
            "updateAnnounced" -> result.success(AppNotifier.updateAnnounced(app))
            "setUpdateAnnounced" -> {
                call.argument<String>("version")?.let { AppNotifier.setUpdateAnnounced(app, it) }
                result.success(null)
            }
            "takeLaunchUpdate" -> {
                result.success(launchUpdate)
                launchUpdate = null
            }
            else -> result.notImplemented()
        }
    }

    private fun request(once: Boolean, result: MethodChannel.Result) {
        val prefs = app.getSharedPreferences(PREFS, 0)
        val granted = app.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val window = AppEngine.activity // the dialog needs a window; none on screen = nothing asked, nothing counted
        if (window == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || granted || (once && prefs.getBoolean(ASKED, false))) {
            result.success(state())
            return
        }
        prefs.edit().putBoolean(ASKED, true).apply()
        pendingRequest?.success(state()) // a second ask replaces the first
        pendingRequest = result
        window.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST)
    }

    /** From MainActivity.onRequestPermissionsResult; true when the request code was ours. */
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_POST) return false
        pendingRequest?.success(state())
        pendingRequest = null
        return true
    }

    /** From MainActivity (onCreate, onNewIntent): a tap on an event notification, or on a button of one. */
    fun onIntent(intent: Intent?) {
        if (intent?.action == AppNotifier.ACTION_OPEN_UPDATE) {
            val install = intent.getBooleanExtra(AppNotifier.EXTRA_INSTALL, false)
            intent.action = null // a recreated activity must not replay it
            intent.removeExtra(AppNotifier.EXTRA_INSTALL)
            val ch = dart
            if (dartReady && ch != null) {
                ch.invokeMethod("openUpdate", install)
            } else {
                launchUpdate = install || launchUpdate == true
            }
            return
        }
        if (intent?.action == AppNotifier.ACTION_EVENT_ACT && intent.hasExtra(AppNotifier.EXTRA_EVENT)) {
            val id = intent.getIntExtra(AppNotifier.EXTRA_EVENT, -1)
            val act = mapOf(
                "id" to id,
                "act" to (intent.getStringExtra(AppNotifier.EXTRA_ACT) ?: ""),
                "site" to (intent.getStringExtra(AppNotifier.EXTRA_SITE) ?: ""),
                "via" to (intent.getStringExtra(AppNotifier.EXTRA_VIA) ?: ""),
            )
            intent.action = null // a recreated activity must not replay it
            intent.removeExtra(AppNotifier.EXTRA_EVENT)
            AppNotifier.cancelEvent(app, id) // a button does not dismiss its notification
            val ch = dart
            if (dartReady && ch != null) {
                ch.invokeMethod("eventAct", act)
            } else {
                launchAct = act
            }
            return
        }
        if (intent?.action != AppNotifier.ACTION_OPEN_EVENT || !intent.hasExtra(AppNotifier.EXTRA_EVENT)) return
        val id = intent.getIntExtra(AppNotifier.EXTRA_EVENT, -1)
        intent.action = null // a recreated activity must not replay it
        intent.removeExtra(AppNotifier.EXTRA_EVENT)
        val ch = dart
        if (dartReady && ch != null) {
            ch.invokeMethod("openEvent", id)
        } else {
            launchEvent = id
        }
    }
}
