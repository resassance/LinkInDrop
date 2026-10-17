package dev.resassance.linkindrop

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class BridgeApplication : Application() {
    private var engine: FlutterEngine? = null
    lateinit var platform: PlatformBridge
        private set
    fun ensureEngine(): FlutterEngine {
        engine?.let { return it }
        val created = FlutterEngine(this)
        engine = created
        platform = PlatformBridge(this, created)
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }
}
