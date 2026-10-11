package dev.jormungand.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "The VPN was on" across the app's own update (docs/updates.md, "Подключение после обновления").
 *
 * Replacing the package kills the process and the tunnel with it, and nothing runs again until the
 * system sends MY_PACKAGE_REPLACED ([ResumeReceiver]). What survives is this file in
 * SharedPreferences, kept by the native side so it is right with no Dart running:
 *
 *  - `connected`: the tunnel is up and nobody switched it off. [JormungandVpnService] sets it when
 *    libbox is up ([tunnelUp]) and clears it on every explicit stop and when the system revokes the
 *    VPN ([tunnelDown]) - the user's Disconnect (dock, tile, notification) all end there. This is
 *    also what covers an update installed outside the app (a sideloaded APK, `adb install -r`).
 *  - `entry`, `fromCode`: the entry the app connected through and the versionCode of the build that
 *    wrote the record; Dart writes `entry` before it hands the APK to the installer ([save]) and
 *    [UpdateInstaller] writes `fromCode` / `connected` again right before the commit.
 *  - `armedAt`: when the replacement happened and the record qualified (connected, other
 *    versionCode). The first Dart start after it [take]s the record, which consumes it. No
 *    replacement, no `armedAt`: a crash or a kill never makes the app reconnect by itself.
 *
 * A process that starts with no tunnel and no armed record forgets `connected` ([processStarted]):
 * the app that died on its own (a crash, the system killing it) is not "was on" for a later update.
 * One exception: a record whose `fromCode` differs from this build's versionCode is from a build
 * that was replaced - the process may start (a window opened by the user, "Open" in the package
 * installer, the tile) before the system's MY_PACKAGE_REPLACED reaches [ResumeReceiver], and the
 * record is then armed right there, not wiped. Either order of the two arms the same record once
 * ([arm] is idempotent with [processStarted]), and [take] consumes it once.
 *
 *  - `trail`: the last decisions of this file (process start, receiver, take, tunnel up / down and
 *    why, hold), a few lines with time and versionCode. There is no logcat on the user's phone: Dart
 *    copies it into the app's log on every start (channel `trail`), so a failed resume can be read there.
 */
object ResumeStore {
    private const val PREFS = "jorm_resume"
    private const val TAG = "JormungandResume"
    private const val TRAIL_MAX = 30

    /** How long a replacement stays good for a resume; Dart checks the same (a stale one is dropped). */
    const val WINDOW_MS = 10 * 60 * 1000L
    private const val HOLD_MS = 45_000L

    private val main = Handler(Looper.getMainLooper())
    private var hold: BroadcastReceiver.PendingResult? = null

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Suppress("DEPRECATION")
    fun versionCode(ctx: Context): Long {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    }

    /** One line into [trail] (and logcat): what was decided and why. */
    @Synchronized
    fun note(ctx: Context, text: String) {
        val line = "${java.text.SimpleDateFormat("MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date())} v${versionCode(ctx)} $text"
        Log.i(TAG, line)
        val p = prefs(ctx)
        val lines = (p.getString("trail", "") ?: "").split('\n').filter { it.isNotEmpty() } + line
        p.edit().putString("trail", lines.takeLast(TRAIL_MAX).joinToString("\n")).commit()
    }

    /** The kept decisions, oldest first (Dart writes them into the app's log). */
    @Synchronized
    fun trail(ctx: Context): List<String> =
        (prefs(ctx).getString("trail", "") ?: "").split('\n').filter { it.isNotEmpty() }

    /** The tunnel is up (libbox started). */
    fun tunnelUp(ctx: Context) {
        prefs(ctx).edit()
            .putBoolean("connected", true)
            .putLong("fromCode", versionCode(ctx))
            .putLong("savedAt", System.currentTimeMillis())
            .commit()
        note(ctx, "tunnel up: connected=true")
        ResumeNotifier.cancel(ctx) // connected: "tap to connect" is void
        finishHold(ctx, "tunnel up")
    }

    /** The tunnel was stopped on purpose (or revoked, or failed to start): the user's state is "off". */
    fun tunnelDown(ctx: Context, why: String) {
        val p = prefs(ctx)
        val was = p.getBoolean("connected", false)
        p.edit().putBoolean("connected", false).commit()
        note(ctx, "tunnel down ($why): connected $was -> false")
        finishHold(ctx, "tunnel down")
    }

    /** Dart, before the installer: connected or not, through which entry. */
    fun save(ctx: Context, connected: Boolean, entry: String) {
        prefs(ctx).edit()
            .putBoolean("connected", connected)
            .putString("entry", entry)
            .putLong("fromCode", versionCode(ctx))
            .putLong("savedAt", System.currentTimeMillis())
            .commit()
        note(ctx, "save before install (Dart): connected=$connected entry=$entry")
    }

    /** [UpdateInstaller], right before the commit: what native knows, on top of Dart's answer. */
    fun beforeInstall(ctx: Context) {
        val p = prefs(ctx)
        val up = JormungandVpnService.instance?.isUp == true
        val was = p.getBoolean("connected", false)
        p.edit()
            .putBoolean("connected", was || up)
            .putLong("fromCode", versionCode(ctx))
            .putLong("savedAt", System.currentTimeMillis())
            .commit()
        note(ctx, "before install: connected=${was || up} (record $was, service up $up)")
    }

    /**
     * MY_PACKAGE_REPLACED: the record qualifies when the VPN was on and the version really changed.
     * Returns whether a resume is armed (and waits for Dart). Idempotent with [processStarted]: a
     * process that started first (a window) has armed the record already - that stays, and no
     * second arming is made; a record Dart already [take]s no longer says `connected`.
     */
    fun arm(ctx: Context): Boolean {
        val p = prefs(ctx)
        val now = System.currentTimeMillis()
        val at = p.getLong("armedAt", 0L)
        val connected = p.getBoolean("connected", false)
        val from = p.getLong("fromCode", 0L)
        if (at != 0L && now - at < WINDOW_MS) {
            note(ctx, "MY_PACKAGE_REPLACED: already armed ${(now - at) / 1000}s ago (the process started first), kept")
            return true
        }
        val qualifies = connected && from != versionCode(ctx)
        p.edit().putLong("armedAt", if (qualifies) now else 0L).commit()
        note(
            ctx,
            "MY_PACKAGE_REPLACED: connected=$connected fromCode=$from -> " +
                if (qualifies) "armed" else "not armed (" + (if (!connected) "the VPN was off" else "same versionCode") + ")",
        )
        return qualifies
    }

    /** Dart's first call after an update; consumes the record. Null = no update happened before this start. */
    fun take(ctx: Context): Map<String, Any?>? {
        val p = prefs(ctx)
        val at = p.getLong("armedAt", 0L)
        if (at == 0L) {
            note(ctx, "take: nothing armed (connected=${p.getBoolean("connected", false)})")
            return null
        }
        val rec = mapOf(
            "connected" to p.getBoolean("connected", false),
            "entry" to (p.getString("entry", "") ?: ""),
            "fromCode" to p.getLong("fromCode", 0L),
            "code" to versionCode(ctx),
            "at" to at,
        )
        p.edit().putLong("armedAt", 0L).putBoolean("connected", false).commit()
        note(ctx, "take: record connected=${rec["connected"]} fromCode=${rec["fromCode"]} armed ${(System.currentTimeMillis() - at) / 1000}s ago, consumed")
        return rec
    }

    /**
     * A new process with no tunnel (the engine is made): `connected` of a process that died on its
     * own is over - unless a resume waits, or the record is from another build (see the class text).
     */
    fun processStarted(ctx: Context) {
        val p = prefs(ctx)
        val now = System.currentTimeMillis()
        val at = p.getLong("armedAt", 0L)
        val connected = p.getBoolean("connected", false)
        val from = p.getLong("fromCode", 0L)
        val code = versionCode(ctx)
        if (at != 0L && now - at < WINDOW_MS) {
            note(ctx, "process start: record armed ${(now - at) / 1000}s ago, kept")
            return
        }
        if (at == 0L && connected && from != code) {
            // replaced since the record, and MY_PACKAGE_REPLACED has not been handled (yet): arm it here
            p.edit().putLong("armedAt", now).commit()
            note(ctx, "process start: package replaced since the record (v$from -> v$code), armed here before the receiver")
            return
        }
        p.edit().putLong("armedAt", 0L).putBoolean("connected", false).commit()
        note(ctx, "process start: no tunnel, connected=$connected fromCode=$from armedAt=${if (at == 0L) "none" else "${(now - at) / 1000}s ago (stale)"} -> cleared")
    }

    /**
     * The receiver stays open (goAsync) until the resume is dealt with (the tunnel is up, it failed,
     * or Dart says it is done), so the system keeps the process, and the right to start the
     * foreground service from the background, for as long as the connect takes.
     */
    @Synchronized
    fun hold(ctx: Context, r: BroadcastReceiver.PendingResult) {
        hold?.finish()
        hold = r
        main.postDelayed({ finishHold(ctx, "timeout ${HOLD_MS / 1000}s") }, HOLD_MS)
    }

    @Synchronized
    fun finishHold(ctx: Context, why: String) {
        val h = hold ?: return
        runCatching { h.finish() }
        hold = null
        note(ctx, "receiver released: $why")
    }
}

/** The package was replaced (an update, in the app or outside it): the VPN comes back if it was on. */
class ResumeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val app = context.applicationContext
        // the notification about an update that is installed now (or an older one) is stale; the background
        // update check is registered again (JobScheduler may lose its jobs when the package is replaced)
        runCatching { AppNotifier.cancelUpdate(app) }
        runCatching { UpdateJob.ensure(app) }
        if (!ResumeStore.arm(app)) return
        // No window may be started from here, so the Dart core comes up on the process's engine without one:
        // it takes the record, connects and the foreground service takes the process over.
        ResumeStore.hold(app, goAsync())
        try {
            // false: a window started the process first and its engine already runs Dart (it takes the record itself)
            val started = AppEngine.startDart(app)
            ResumeStore.note(app, if (started) "receiver: Dart started without a window" else "receiver: Dart already running, nothing to start")
        } catch (e: Throwable) {
            Log.e("JormungandResume", "headless start failed", e)
            ResumeStore.note(app, "receiver: headless start failed: $e")
            ResumeStore.finishHold(app, "headless start failed")
        }
    }
}

/** "Updated - tap to connect": the VPN could not come back by itself (the system consent is missing). */
object ResumeNotifier {
    private const val CHANNEL = "update"
    private const val ID = 3

    fun post(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (!nm.areNotificationsEnabled()) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, ctx.getString(R.string.jorm_channel_update), NotificationManager.IMPORTANCE_DEFAULT),
        )
        // the same request the tile makes: the app opens (the consent dialog needs a window) and connects
        val open = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(TileBridge.EXTRA_ACTION, "connect")
        val tap = PendingIntent.getActivity(ctx, ID, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        nm.notify(
            ID,
            Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(ctx.applicationInfo.icon)
                .setContentTitle("Jormungand")
                .setContentText(ctx.getString(R.string.jorm_resume_tap))
                .setContentIntent(tap)
                .setAutoCancel(true)
                .build(),
        )
    }

    fun cancel(ctx: Context) {
        runCatching { ctx.getSystemService(NotificationManager::class.java).cancel(ID) }
    }
}

/**
 * MethodChannel `jormungand/resume` (Dart side: lib/platform/resume_channel.dart).
 *
 *  save   -> null  args {connected: Boolean, entry: String}: before the installer
 *  take   -> Map?  {connected, entry, fromCode, code, at}: the record a package replacement armed, once; null otherwise
 *  prompt -> null  posts the "Updated - tap to connect" notification (consent for the VPN is missing)
 *  done   -> null  the resume is dealt with
 *  trail  -> List<String>  the kept decisions of [ResumeStore] (oldest first), for the app's log
 *  attached -> Boolean  whether a window has attached to the engine (a headless Dart start waits for one)
 *
 *  Kotlin -> Dart: `windowAttached` (MainActivity attached; the UI may start).
 */
class ResumeChannel(private val app: Context) {
    companion object {
        const val NAME = "jormungand/resume"
    }

    private var dart: MethodChannel? = null

    /** A window has attached to the engine (kept: Dart may ask later, see `attached`). */
    @Volatile
    private var attached = false

    fun register(messenger: BinaryMessenger) {
        val ch = MethodChannel(messenger, NAME)
        ch.setMethodCallHandler(::onCall)
        dart = ch
    }

    /**
     * MainActivity attached to the engine. A headless start ([AppEngine.startDart]) runs Dart's `main`
     * with no view and the UI waits for one; this tells it that one is coming, whatever else the
     * platform reports. Dart answers late (its handler is set after it starts): the flag is kept for `attached`.
     */
    fun windowAttached() {
        attached = true
        runCatching { dart?.invokeMethod("windowAttached", null) }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "save" -> {
                ResumeStore.save(app, call.argument<Boolean>("connected") == true, call.argument<String>("entry") ?: "")
                result.success(null)
            }
            "take" -> result.success(ResumeStore.take(app))
            "attached" -> result.success(attached)
            "prompt" -> {
                ResumeNotifier.post(app)
                result.success(null)
            }
            "done" -> {
                ResumeStore.finishHold(app, "Dart done")
                result.success(null)
            }
            "trail" -> result.success(ResumeStore.trail(app))
            else -> result.notImplemented()
        }
    }
}
