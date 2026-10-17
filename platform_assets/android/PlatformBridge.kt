package dev.resassance.linkindrop

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class PlatformBridge(private val context: Context, engine: FlutterEngine) {
    private var activity: MainActivity? = null
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(2)
    val folders = FolderAccess(context) { activity }
    private val received = ReceiveFiles(context)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "linkindrop/system")
    private fun resolverType(uri: Uri): String = context.contentResolver.getType(uri) ?: "application/octet-stream"
    fun attach(value: MainActivity) { activity = value }
    fun detach(value: MainActivity) { if (activity === value) activity = null }
    fun shared() { channel.invokeMethod("shared", null) }
    private val localNetwork = LocalNetwork(context) { channel.invokeMethod("localNetworkChanged", null) }
    init {
        channel.setMethodCallHandler { call, result ->
            if (folders.handle(call, result)) return@setMethodCallHandler
            try {
                when (call.method) {
                    "setDirectWifi" -> result.success(localNetwork.setEnabled(call.argument<Boolean>("enabled") == true))
                    "localNetworkStatus" -> result.success(localNetwork.status())
                    "openReceivedFolder" -> {
                        val tree = call.argument<String>("tree")
                        val uri = if (tree == null) android.provider.DocumentsContract.buildRootUri("${context.packageName}.received", "received") else android.provider.DocumentsContract.buildDocumentUriUsingTree(Uri.parse(tree), android.provider.DocumentsContract.getTreeDocumentId(Uri.parse(tree)))
                        val type = if (tree == null) android.provider.DocumentsContract.Root.MIME_TYPE_ITEM else android.provider.DocumentsContract.Document.MIME_TYPE_DIR
                        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, type).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        try { context.startActivity(intent) }
                        catch (_: android.content.ActivityNotFoundException) {
                            context.startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE).putExtra(android.provider.DocumentsContract.EXTRA_INITIAL_URI, if (tree == null) android.provider.DocumentsContract.buildDocumentUri("${context.packageName}.received", "received") else uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        }
                        result.success(null)
                    }
                    "setLanguage" -> {
                        val language = call.argument<String>("language") ?: "system"
                        require(language in listOf("system", "ru", "en"))
                        context.getSharedPreferences("connection", Context.MODE_PRIVATE).edit().putString("language", language).commit()
                        ConnectionService.update(context, NativeStrings.text(context, "Служба передачи файлов работает"))
                        result.success(null)
                    }
                    "setBackgroundSettings" -> {
                        val enabled = call.argument<Boolean>("enabled") == true
                        val boot = enabled && call.argument<Boolean>("boot") == true
                        context.getSharedPreferences("connection", Context.MODE_PRIVATE).edit().putBoolean("enabled", enabled).putBoolean("boot", boot).commit()
                        val service = Intent(context, ConnectionService::class.java)
                        if (enabled) {
                            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(service) else context.startService(service)
                            val current = activity
                            if (Build.VERSION.SDK_INT >= 33 && current != null && current.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) current.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 42)
                        } else context.stopService(service)
                        result.success(null)
                    }
                    "stopConnection" -> { context.stopService(Intent(context, ConnectionService::class.java)); result.success(null) }
                    "backgroundStatus" -> {
                        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                        result.success(mapOf("running" to ConnectionService.running, "activityAttached" to (activity != null),
                            "batteryUnrestricted" to power.isIgnoringBatteryOptimizations(context.packageName),
                            "notifications" to (Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled())))
                    }
                    "batterySettings" -> {
                        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                        val intent = if (!power.isIgnoringBatteryOptimizations(context.packageName)) Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")) else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
                        try { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        catch (_: android.content.ActivityNotFoundException) { context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                        result.success(null)
                    }
                    "notificationSettings" -> { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(null) }
                    "updateConnectionStatus" -> { ConnectionService.update(context, call.argument<String>("text") ?: NativeStrings.text(context, "Ожидание устройств")); result.success(null) }
                    "openReceivedFile" -> {
                        val uri = Uri.parse(call.argument<String>("location")!!)
                        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, resolverType(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)); result.success(null)
                    }
                    "openRelease" -> {
                        val uri = Uri.parse(call.argument<String>("url")!!)
                        if (uri.scheme != "https" || uri.host != "github.com" || !uri.path.orEmpty().startsWith("/resassance/LinkInDrop/releases/")) throw IllegalArgumentException("Invalid release URL")
                        context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(null)
                    }
                    "clipboardSensitive" -> {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        result.success(clipboard.primaryClipDescription?.extras?.getBoolean("android.content.extra.IS_SENSITIVE", false) == true)
                    }
                    "freeBytes" -> result.success(StatFs(call.argument<String>("path")!!).availableBytes)
                    "takeShared" -> {
                        val current = activity
                        val shared = current?.intent
                        if (current != null) current.intent = Intent(context, MainActivity::class.java)
                        worker.execute {
                            try { val data = readShared(shared); main.post { result.success(data) } }
                            catch (error: Exception) { main.post { result.error("share", error.message, null) } }
                        }
                    }
                    "exportReceived", "verifyReceived", "createReceivedDirectory" -> worker.execute {
                        try { val value = received.handle(call); main.post { result.success(value) } }
                        catch (error: Exception) { main.post { result.error("received", error.message, null) } }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("system", error.message, null) }
        }
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
        if (uris.size > 100) throw IllegalArgumentException(NativeStrings.text(context, "Не больше 100 файлов за раз"))
        val paths = uris.map { uri ->
            var name = "file"
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) name = cursor.getString(0) ?: "file"
            }
            name = name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\x00-\\x1f<>:\"/\\\\|?*]"), "_")
            if (name.isBlank() || name == "." || name == "..") name = "file"
            if (name.length > 120) name = name.takeLast(120)
            val directory = File(context.filesDir, "shared/${UUID.randomUUID()}")
            directory.mkdirs()
            val output = File(directory, name)
            try {
                context.contentResolver.openInputStream(uri)?.use { input ->
                    output.outputStream().buffered().use { target ->
                        val buffer = ByteArray(65536)
                        var total = 0L
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > 8796093022208L) throw IllegalArgumentException(NativeStrings.text(context, "Лимит файла — 8 ТБ"))
                            target.write(buffer, 0, count)
                        }
                    }
                } ?: throw IllegalArgumentException(NativeStrings.text(context, "Нет доступа к файлу"))
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
