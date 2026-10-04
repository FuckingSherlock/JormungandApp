package dev.jormungand.app

import android.content.Context
import android.os.Build
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import java.io.File

/** libbox's process-wide setup, once. */
object LibboxSetup {
    private var done = false

    @Synchronized
    fun ensure(context: Context) {
        if (done) return
        val base = File(context.filesDir, "libbox").apply { mkdirs() }
        val work = File(base, "work").apply { mkdirs() }
        val temp = File(context.cacheDir, "libbox").apply { mkdirs() }
        Libbox.setup(
            SetupOptions().also {
                it.basePath = base.path
                it.workingPath = work.path
                it.tempPath = temp.path
                // https://github.com/golang/go/issues/68760 (sing-box-for-android: Android 9+)
                it.fixAndroidStack = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                it.logMaxLines = 3000
                it.debug = false
                it.crashReportSource = "Jormungand"
            },
        )
        done = true
    }
}

/**
 * One running sing-box (libbox): the config the Dart core built, started with [platform].
 *
 * Only the engine, not libbox's own command server: its gRPC listener (a unix socket) is never
 * opened. The core talks to sing-box through the `api` service that sits in the config itself
 * (core/lib/src/runtime.dart `withApiService`), exactly as with the desktop process, so any number
 * of these can live side by side (the tunnel and the throwaway ones).
 */
class LibboxBox(
    private val context: Context,
    private val platform: PlatformInterface,
    /** What the lines of the raw log call it: "tunnel", "box3". */
    private val name: String = "box",
) : CommandServerHandler {
    private var server: CommandServer? = null

    /** Starts it and returns when it is up; throws with sing-box's reason when it is not. */
    @Synchronized
    fun start(config: String) {
        val t0 = System.currentTimeMillis()
        VpnBridge.log("debug", "$name: starting libbox (config ${config.length} bytes)")
        LibboxSetup.ensure(context)
        stop()
        val s = CommandServer(this, platform)
        server = s
        try {
            s.startOrReloadService(config, OverrideOptions())
        } catch (e: Throwable) {
            VpnBridge.log("error", "$name: libbox did not start (${System.currentTimeMillis() - t0} ms): ${e.message ?: e}")
            stop()
            throw e
        }
        VpnBridge.log("debug", "$name: libbox started in ${System.currentTimeMillis() - t0} ms")
    }

    @Synchronized
    fun stop() {
        val s = server ?: return
        server = null
        runCatching { s.closeService() }.onFailure { Log.w(TAG, "close service", it) }
        runCatching { s.close() }.onFailure { Log.w(TAG, "close server", it) }
        VpnBridge.log("debug", "$name: libbox stopped")
    }

    // CommandServerHandler: calls that come from libbox's own clients, which we do not have.
    override fun serviceStop() {}

    override fun serviceReload() {}

    override fun getSystemProxyStatus(): SystemProxyStatus? = SystemProxyStatus()

    override fun setSystemProxyEnabled(isEnabled: Boolean) {}

    override fun triggerNativeCrash() {}

    override fun writeDebugMessage(message: String?) {
        if (message != null) VpnBridge.log("debug", "$name: libbox: $message")
    }

    override fun connectSSHAgent(): Int = -1

    companion object {
        private const val TAG = "LibboxBox"
    }
}
