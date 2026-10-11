package dev.jormungand.app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * The update check while the app's process is not running (docs/updates.md, section 6, "Фоновая проверка
 * при закрытом процессе"). A WorkManager periodic job (about once a day, only with a network) starts a
 * second, headless FlutterEngine whose entry point is Dart's `updateJobMain` (lib/core/update_job.dart);
 * that isolate does the whole check with the same AppUpdater the app has (manifest, signature, feeds,
 * delta) and posts the notification through the same [AppNotifier] / "announced" record. Nothing is
 * checked or verified here in Kotlin.
 *
 * The job never touches the VPN and never starts the core: its engine has only the notification
 * channel (not the primary one: [NotifyChannel.dart] stays the app's) and [UpdateJobChannel]. It does
 * nothing while the app's process lives ([AppEngine.isAlive] or the tunnel service is up): the Dart
 * schedule of that process covers the check, and its updater owns the updates folder. If the app comes
 * up while the job runs, the job stops at once (a half-done download is resumed later: `.part`).
 *
 * The settings it needs are mirrored by the app into SharedPreferences `jorm_updatejob` on every change
 * ([UpdateJobChannel] `sync`), which also registers the unique work `jorm-update-check` (KEEP) or
 * cancels it when auto-check is off. WorkManager brings registered work back after a reboot; after the
 * package is replaced [ResumeReceiver] registers it again.
 */
object UpdateJob {
    const val WORK_NAME = "jorm-update-check"
    private const val TAG = "JormungandUpdateJob"
    private const val PREFS = "jorm_updatejob"

    /** WorkManager stops a job at about ten minutes; the engine is torn down a little before. */
    const val LIMIT_MS = 9 * 60_000L

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The app's process (a window, the Dart core) or the tunnel service is up. */
    fun processAlive(): Boolean = AppEngine.isAlive || JormungandVpnService.instance != null

    fun autoCheck(ctx: Context): Boolean = prefs(ctx).getBoolean("autoCheck", true)

    /** From Dart (`sync`): keep the settings, then register or cancel the periodic work. */
    fun sync(ctx: Context, args: Map<*, *>) {
        prefs(ctx).edit()
            .putBoolean("autoCheck", args["autoCheck"] != false)
            .putString("channel", args["channel"] as? String ?: "stable")
            .putString("autoDownload", args["autoDownload"] as? String ?: "wifi")
            .putBoolean("notify", args["notify"] != false)
            .putString("lang", args["lang"] as? String ?: "")
            .apply()
        ensure(ctx)
    }

    /** Registers the work when auto-check is on (idempotent: KEEP), cancels it when off. */
    fun ensure(ctx: Context) {
        try {
            val wm = WorkManager.getInstance(ctx.applicationContext)
            if (!autoCheck(ctx)) {
                wm.cancelUniqueWork(WORK_NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<UpdateCheckWorker>(24, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                // the app's own schedule checks at every start: the first job run is a day after the registration
                .setInitialDelay(24, TimeUnit.HOURS)
                .build()
            wm.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        } catch (e: Throwable) {
            Log.w(TAG, "scheduling failed", e)
        }
    }

    /** What the Dart side of a run gets: the mirrored settings and the facts that are read when it runs. */
    fun input(ctx: Context): Map<String, Any?> {
        val p = prefs(ctx)
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        return mapOf(
            "autoCheck" to p.getBoolean("autoCheck", true),
            "channel" to (p.getString("channel", null) ?: "stable"),
            "autoDownload" to (p.getString("autoDownload", null) ?: "wifi"),
            "notify" to p.getBoolean("notify", true),
            "lang" to (p.getString("lang", null) ?: ""),
            "systemLang" to Locale.getDefault().language,
            "metered" to NetworkChannel.isMetered(ctx),
            "versionName" to (info.versionName ?: ""),
            "versionCode" to ResumeStore.versionCode(ctx),
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "installedPackage" to ctx.applicationInfo.sourceDir,
            "alive" to processAlive(),
        )
    }

    fun log(text: String) = Log.i(TAG, text)
}

/** The periodic job. The work itself is [UpdateJobSession]; this only waits for it (or for WorkManager to stop it). */
class UpdateCheckWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        suspendCancellableCoroutine { cont ->
            val session = UpdateJobSession(applicationContext) { cont.resume(Result.success()) }
            // WorkManager stops the work (constraints lost, time up): the engine goes with it
            cont.invokeOnCancellation { Handler(Looper.getMainLooper()).post { session.stop("stopped by WorkManager") } }
            session.start()
        }
    }
}

/**
 * One run: the headless engine with Dart's `updateJobMain`, the channel it asks its input on and tells
 * it is done on. Main thread only. [onEnd] is called once, whatever ended the run.
 */
class UpdateJobSession(private val app: Context, private val onEnd: () -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var ended = false

    private val timeUp = Runnable { stop("time limit") }
    private val watch = object : Runnable {
        override fun run() {
            if (AppEngine.isAlive || JormungandVpnService.instance != null) stop("the app started") else main.postDelayed(this, 2_000L)
        }
    }

    fun start() {
        if (UpdateJob.processAlive()) return stop("skipped: the app is running")
        if (!UpdateJob.autoCheck(app)) return stop("skipped: auto-check is off")
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
            val e = FlutterEngine(app)
            engine = e
            GeneratedPluginRegister.registerGeneratedPlugins(e) // path_provider: the same data dir as the app
            val messenger = e.dartExecutor.binaryMessenger
            NotifyChannel(app).register(messenger, primary = false)
            MethodChannel(messenger, UpdateJobChannel.NAME).setMethodCallHandler(::onCall)
            e.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "package:jormungand/core/update_job.dart", "updateJobMain"),
            )
            main.postDelayed(timeUp, UpdateJob.LIMIT_MS)
            main.postDelayed(watch, 2_000L)
            UpdateJob.log("started")
        } catch (t: Throwable) {
            Log.e("JormungandUpdateJob", "could not start", t)
            stop("could not start: $t")
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "input" -> result.success(UpdateJob.input(app))
            "done" -> {
                result.success(null)
                stop("done: ${call.argument<String>("summary") ?: ""}")
            }
            else -> result.notImplemented()
        }
    }

    fun stop(why: String) {
        if (ended) return
        ended = true
        main.removeCallbacks(timeUp)
        main.removeCallbacks(watch)
        UpdateJob.log(why)
        // after the reply of `done` has left
        main.post {
            runCatching { engine?.destroy() }
            engine = null
            onEnd()
        }
    }
}

/**
 * MethodChannel `jormungand/updatejob` (Dart side: lib/platform/update_job_channel.dart).
 *
 * In the app's engine (this class, [AppEngine]):
 *  sync -> null  args {autoCheck, channel, autoDownload, notify, lang}: keep the settings the background
 *                check needs, register / cancel the periodic work ([UpdateJob.sync])
 *
 * In the job's own engine ([UpdateJobSession], same channel name):
 *  input -> Map  the settings, the version and ABIs, the installed APK, whether the network is metered
 *  done  -> null args {summary}: the run is over, the engine goes
 */
class UpdateJobChannel(private val app: Context) {
    companion object {
        const val NAME = "jormungand/updatejob"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "sync" -> {
                    UpdateJob.sync(app, call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
