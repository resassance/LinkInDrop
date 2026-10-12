package dev.resassance.nearbridge

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nearbridge/system")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startConnection" -> {
                    val service = Intent(this, ConnectionService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 42)
                    }
                    result.success(null)
                }
                "stopConnection" -> {
                    stopService(Intent(this, ConnectionService::class.java))
                    result.success(null)
                }
                "clipboardSensitive" -> {
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    result.success(clipboard.primaryClipDescription?.extras?.getBoolean("android.content.extra.IS_SENSITIVE", false) == true)
                }
                "takeShared" -> {
                    val shared = intent
                    intent = Intent(this, MainActivity::class.java)
                    worker.execute {
                        try {
                            val data = readShared(shared)
                            runOnUiThread { result.success(data) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("share", error.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        channel?.invokeMethod("shared", null)
    }

    @Suppress("DEPRECATION")
    private fun readShared(shared: Intent?): Map<String, Any>? {
        if (shared == null) return null
        if (shared.getBooleanExtra("clipboard", false)) return mapOf("clipboard" to true)
        if (shared.action != Intent.ACTION_SEND && shared.action != Intent.ACTION_SEND_MULTIPLE) return null
        val text = shared.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val uris = mutableListOf<Uri>()
        if (shared.action == Intent.ACTION_SEND_MULTIPLE) {
            shared.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            shared.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        if (uris.size > 100) throw IllegalArgumentException("Не больше 100 файлов за раз")
        val paths = uris.map { uri ->
            var name = "file"
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) name = cursor.getString(0) ?: "file"
            }
            name = name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\x00-\\x1f<>:\"/\\\\|?*]"), "_")
            if (name.isBlank() || name == "." || name == "..") name = "file"
            if (name.length > 120) name = name.takeLast(120)
            val directory = File(filesDir, "shared/${UUID.randomUUID()}")
            directory.mkdirs()
            val output = File(directory, name)
            try {
                contentResolver.openInputStream(uri)?.use { input ->
                    output.outputStream().buffered().use { target ->
                        val buffer = ByteArray(65536)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > 2147483648L) throw IllegalArgumentException("Лимит файла — 2 ГБ")
                            target.write(buffer, 0, count)
                        }
                    }
                } ?: throw IllegalArgumentException("Нет доступа к файлу")
            } catch (error: Exception) {
                directory.deleteRecursively()
                throw error
            }
            output.absolutePath
        }
        val data = mutableMapOf<String, Any>("files" to paths)
        if (text != null) data["text"] = text
        return data
    }
}
