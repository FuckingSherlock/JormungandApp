package dev.jormungand.app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The window. The Flutter engine and the channels are the process's ([AppEngine]): this activity
 * only attaches to them, and going away (Back, a swipe from Recents, the system) never destroys
 * the engine, so the Dart core and the tunnel keep running without a window.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine? = AppEngine.get(context)

    // the engine is the process's, not this window's
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        AppEngine.activity = this // before Dart can ask for a window (VPN consent, dialogs)
        super.onCreate(savedInstanceState)
        // started by the tile: a live Dart core (the engine outlived the last window) gets it at once,
        // a cold one pulls it once it is up
        TileBridge.onLaunchIntent(intent, live = TileBridge.sink != null)
        AppEngine.notify.onIntent(intent) // a tap on an event notification, same
    }

    // an engine that started with no window (after the app's update) waits for the first one: say it is here
    override fun onStart() {
        super.onStart()
        AppEngine.resume.windowAttached()
    }

    override fun onDestroy() {
        if (AppEngine.activity === this) AppEngine.activity = null
        super.onDestroy()
    }

    // singleTop: the tile (or the launcher) opens an app that is already running
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        TileBridge.onLaunchIntent(intent, live = true)
        AppEngine.notify.onIntent(intent)
    }

    // the Android 13 notification permission dialog answers here
    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (AppEngine.notify.onRequestPermissionsResult(requestCode)) return
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    // FlutterActivity is a plain Activity: the VPN consent dialog, the file dialogs and the battery
    // exemption dialog answer here.
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (AppEngine.vpn.onActivityResult(requestCode, resultCode)) return
        if (AppEngine.files.onActivityResult(requestCode, resultCode, data)) return
        if (AppEngine.power.onActivityResult(requestCode)) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
