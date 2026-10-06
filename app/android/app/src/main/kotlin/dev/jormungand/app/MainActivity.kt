package dev.jormungand.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var vpn: VpnChannel
    private lateinit var files: FilesChannel
    private lateinit var tile: TileChannel
    private lateinit var notify: NotifyChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vpn = VpnChannel(this)
        vpn.register(flutterEngine.dartExecutor.binaryMessenger)
        files = FilesChannel(this)
        files.register(flutterEngine.dartExecutor.binaryMessenger)
        AppsChannel(applicationContext).register(flutterEngine.dartExecutor.binaryMessenger)
        tile = TileChannel(this)
        tile.register(flutterEngine.dartExecutor.binaryMessenger)
        notify = NotifyChannel(this)
        notify.register(flutterEngine.dartExecutor.binaryMessenger)
        notify.onIntent(intent) // started by a tap on an event notification: Dart pulls it once it is up
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (::notify.isInitialized) notify.unregister()
        if (::tile.isInitialized) tile.unregister() // Dart is gone: the tile goes back to what native knows
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        TileBridge.onLaunchIntent(intent, live = false) // started by the tile: Dart pulls it once it is up
    }

    // singleTop: the tile (or the launcher) opens an app that is already running
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        TileBridge.onLaunchIntent(intent, live = true)
        if (::notify.isInitialized) notify.onIntent(intent)
    }

    // the Android 13 notification permission dialog answers here
    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (::notify.isInitialized && notify.onRequestPermissionsResult(requestCode)) return
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    // FlutterActivity is a plain Activity: the VPN consent dialog and the file dialogs answer here.
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::vpn.isInitialized && vpn.onActivityResult(requestCode, resultCode)) return
        if (::files.isInitialized && files.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
