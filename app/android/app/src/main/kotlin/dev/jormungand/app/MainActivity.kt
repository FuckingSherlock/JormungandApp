package dev.jormungand.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var vpn: VpnChannel
    private lateinit var files: FilesChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vpn = VpnChannel(this)
        vpn.register(flutterEngine.dartExecutor.binaryMessenger)
        files = FilesChannel(this)
        files.register(flutterEngine.dartExecutor.binaryMessenger)
    }

    // FlutterActivity is a plain Activity: the VPN consent dialog and the file dialogs answer here.
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::vpn.isInitialized && vpn.onActivityResult(requestCode, resultCode)) return
        if (::files.isInitialized && files.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
