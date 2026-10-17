package dev.resassance.linkindrop

import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val app get() = application as BridgeApplication
    override fun provideFlutterEngine(context: Context): FlutterEngine = app.ensureEngine()
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        app.platform.attach(this)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        app.platform.shared()
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!app.platform.folders.onActivityResult(requestCode, resultCode, data)) super.onActivityResult(requestCode, resultCode, data)
    }
    override fun onDestroy() {
        app.platform.detach(this)
        super.onDestroy()
    }
}
