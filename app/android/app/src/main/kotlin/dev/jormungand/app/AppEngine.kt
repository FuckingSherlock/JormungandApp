package dev.jormungand.app

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.plugins.util.GeneratedPluginRegister

/**
 * The Flutter engine (the Dart isolate with the app's core) and the platform channels, owned by
 * the PROCESS, not by [MainActivity] (docs/platforms.md, "Работа в фоне").
 *
 * The tunnel ([JormungandVpnService], a foreground service) outlives the window: Back, a swipe from
 * Recents or the system recreating the activity must not take the Dart core (Auto, pings, the log,
 * notifications, the tile's actions) down with it, nor leave a tunnel nobody controls. So the
 * engine is made once, on the first activity, and every later [MainActivity] only attaches to it
 * ([MainActivity.provideFlutterEngine]; it never destroys it). The channels hold the application
 * context; what needs a window (the VPN consent, file / permission dialogs, moveTaskToBack) uses
 * [activity], the one on screen now, or answers "no" when there is none.
 *
 * The process ending ends the engine, the service and the tunnel together; a new process starts
 * from nothing (the Dart core then finds no tunnel to take over).
 */
object AppEngine {
    /** The MainActivity on screen (created and not destroyed yet), or null. Main thread. */
    @Volatile
    var activity: Activity? = null

    @Volatile
    private var engine: FlutterEngine? = null

    lateinit var vpn: VpnChannel
        private set
    lateinit var files: FilesChannel
        private set
    lateinit var tile: TileChannel
        private set
    lateinit var notify: NotifyChannel
        private set
    lateinit var power: PowerChannel
        private set
    lateinit var resume: ResumeChannel
        private set

    @Synchronized
    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val e = FlutterEngine(app)
        // plugins attach to the activity by themselves whenever one attaches to this engine
        GeneratedPluginRegister.registerGeneratedPlugins(e)
        val messenger = e.dartExecutor.binaryMessenger
        vpn = VpnChannel(app).also { it.register(messenger) }
        files = FilesChannel(app).also { it.register(messenger) }
        AppsChannel(app).register(messenger)
        tile = TileChannel(app).also { it.register(messenger) }
        notify = NotifyChannel(app).also { it.register(messenger) }
        power = PowerChannel(app).also { it.register(messenger) }
        resume = ResumeChannel(app).also { it.register(messenger) }
        NetworkChannel(app).register(messenger)
        engine = e
        // A process that starts with no tunnel: nothing of an earlier run may stay on show
        // (the service's notification goes with its process, but a stale tile model is cheap to fix).
        if (JormungandVpnService.instance == null) {
            runCatching {
                app.getSystemService(NotificationManager::class.java).cancel(JormungandVpnService.NOTIFICATION_ID)
            }
            TileBridge.refresh(app)
            // "was on" of a process that died on its own is over (one from a replaced build is armed instead)
            ResumeStore.processStarted(app)
        }
        return e
    }

    /**
     * Runs the app's Dart `main` on the engine when no window has done it (the process was started
     * by the package replacement, [ResumeReceiver], and no activity may be opened from there). Dart's
     * `main` copes with having no view yet; the first [MainActivity] later finds Dart running and
     * only attaches its view (FlutterActivity skips the entrypoint of an engine that executes Dart).
     */
    @Synchronized
    fun startDart(context: Context): Boolean {
        val e = get(context)
        if (e.dartExecutor.isExecutingDart) return false
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return true
    }
}
