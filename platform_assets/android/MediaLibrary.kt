package dev.resassance.linkindrop

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Size
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MediaLibrary(private val context: Context, private val activity: () -> Activity?) {
    private val resolver = context.contentResolver
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newFixedThreadPool(2)
    private var permission: MethodChannel.Result? = null
    private var picker: MethodChannel.Result? = null
    private val permissionCode = 7411
    private val pickerCode = 7412
    private val collection = MediaStore.Files.getContentUri("external")
    private val image = MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
    private val video = MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
    private data class Entry(val id: Long, val name: String, val size: Long, val video: Boolean,
        val duration: Long, val taken: Long, val modified: Long, val added: Long, val album: String?, val albumName: String?)
    @Volatile private var media: List<Entry>? = null

    private fun access(): String {
        fun granted(name: String) = context.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED
        return if (Build.VERSION.SDK_INT >= 33) {
            if (granted(Manifest.permission.READ_MEDIA_IMAGES) && granted(Manifest.permission.READ_MEDIA_VIDEO)) "full"
            else if (granted(Manifest.permission.READ_MEDIA_IMAGES) || granted(Manifest.permission.READ_MEDIA_VIDEO) ||
                (Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))) "limited" else "denied"
        } else if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) "full" else "denied"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method == "mediaAccess") {
            val current = activity()
            if (call.argument<Boolean>("request") == true && access() != "full" && current != null) {
                if (permission != null) { result.error("media_busy", "Permission request is open", null); return true }
                permission = result
                val names = if (Build.VERSION.SDK_INT >= 34) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                    else if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
                    else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
                current.requestPermissions(names, permissionCode)
            } else result.success(access())
            return true
        }
        if (call.method == "pickMedia") {
            if (picker != null) { result.error("media_busy", "Picker is open", null); return true }
            try {
                val current = activity() ?: throw IllegalStateException("Open LinkInDrop to choose files")
                picker = result
                val intent = if (Build.VERSION.SDK_INT >= 33) Intent(MediaStore.ACTION_PICK_IMAGES)
                    .putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, minOf(100, MediaStore.getPickImagesMaxLimit()))
                    else Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                        .addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                current.startActivityForResult(intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), pickerCode)
            } catch (error: Exception) { picker = null; result.error("media", error.message, null) }
            return true
        }
        if (call.method !in setOf("mediaPage", "mediaAlbums", "mediaThumbnail", "importMedia", "importFolder")) return false
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "mediaPage" -> page(call.argument<String>("album"), call.argument<Int>("offset") ?: 0)
                    "mediaAlbums" -> albums()
                    "mediaThumbnail" -> thumbnail(call.argument<String>("uri")!!, call.argument<Boolean>("video") == true)
                    "importMedia" -> importItems(call.argument<List<String>>("uris") ?: emptyList())
                    "importFolder" -> importFolder(call.argument<String>("uri")!!)
                    else -> null
                }
                main.post { result.success(value) }
            } catch (error: Exception) { main.post { result.error("media", error.message, null) } }
        }
        return true
    }

    fun onPermissionsResult(code: Int): Boolean {
        if (code != permissionCode) return false
        permission?.success(access())
        permission = null
        return true
    }

    fun onActivityResult(code: Int, status: Int, data: Intent?): Boolean {
        if (code != pickerCode) return false
        val result = picker ?: return true
        picker = null
        if (status != Activity.RESULT_OK || data == null) { result.success(emptyList<String>()); return true }
        val uris = mutableListOf<String>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri.toString()) }
        if (uris.isEmpty()) data.data?.let { uris.add(it.toString()) }
        result.success(uris.distinct().take(100))
        return true
    }

    fun detach() {
        permission?.error("media_closed", "Activity closed", null)
        permission = null
        picker?.success(emptyList<String>())
        picker = null
    }

    private fun page(album: String?, offset: Int): List<Map<String, Any>> {
        require(offset in 0..1000000)
        if (access() == "denied") return emptyList()
        return (media ?: readMedia()).asSequence().filter { album == null || it.album == album }.drop(offset).take(60).map {
            mapOf("uri" to ContentUris.withAppendedId(collection, it.id).toString(), "name" to it.name,
                "size" to it.size, "video" to it.video, "duration" to it.duration)
        }.toList()
    }

    private fun albums(): List<Map<String, String>> {
        if (access() == "denied") { media = null; return emptyList() }
        val output = linkedMapOf<String, String>()
        for (entry in readMedia()) entry.album?.let { output.putIfAbsent(it, entry.albumName ?: "Photos") }
        return output.map { mapOf("id" to it.key, "name" to it.value) }
    }

    private fun readMedia(): List<Entry> {
        val columns = arrayOf("_id", "_display_name", "_size", "media_type", "duration", "datetaken", "date_modified", "date_added", "bucket_id", "bucket_display_name")
        val output = mutableListOf<Entry>()
        resolver.query(collection, columns, "media_type IN (?,?)", arrayOf(image.toString(), video.toString()), null)?.use {
            while (it.moveToNext()) {
                val size = it.getLong(2)
                if (size >= 0) output.add(Entry(it.getLong(0), it.getString(1) ?: "file", size, it.getInt(3) == video,
                    it.getLong(4), it.getLong(5), it.getLong(6), it.getLong(7), it.getString(8), it.getString(9)))
            }
        }
        output.sortWith { a, b -> MediaOrder.compare(a.taken, a.modified, a.added, a.id, b.taken, b.modified, b.added, b.id) }
        return output.also { media = it }
    }

    private fun thumbnail(location: String, video: Boolean): ByteArray? {
        val uri = if (location.startsWith("content://")) Uri.parse(location) else Uri.fromFile(File(location))
        val bitmap: Bitmap? = if (Build.VERSION.SDK_INT >= 29 && uri.scheme == "content") resolver.loadThumbnail(uri, Size(640, 640), null)
            else if (video) {
                val reader = MediaMetadataRetriever()
                try { reader.setDataSource(context, uri); if (Build.VERSION.SDK_INT >= 27) reader.getScaledFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 640, 480) else reader.getFrameAtTime(0) }
                finally { reader.release() }
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
                val options = BitmapFactory.Options().apply { inSampleSize = maxOf(1, maxOf(bounds.outWidth, bounds.outHeight) / 640) }
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
            }
        bitmap ?: return null
        return try { ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, it); it.toByteArray() } } finally { bitmap.recycle() }
    }

    private fun safeName(value: String): String = value.substringAfterLast('/').substringAfterLast('\\')
        .replace(Regex("[\\x00-\\x1f<>:\"/\\\\|?*]"), "_").takeLast(120).let { if (it.isBlank() || it == "." || it == "..") "file" else it }

    private fun copy(uri: Uri, output: File) {
        output.parentFile?.mkdirs()
        resolver.openInputStream(uri)?.use { input -> output.outputStream().buffered().use { target ->
            val buffer = ByteArray(65536)
            var sinceCheck = 1024 * 1024
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                sinceCheck += count
                if (sinceCheck >= 1024 * 1024) {
                    if (StatFs(context.filesDir.path).availableBytes < 16L * 1024 * 1024) throw IllegalStateException(NativeStrings.text(context, "Недостаточно свободного места для получения файла"))
                    sinceCheck = 0
                }
                target.write(buffer, 0, count)
            }
        } } ?: throw IllegalArgumentException(NativeStrings.text(context, "Файл недоступен"))
    }

    private fun importItems(locations: List<String>): List<String> {
        require(locations.size <= 100)
        val root = File(context.filesDir, "shared/${UUID.randomUUID()}")
        try {
            return locations.distinct().mapIndexed { index, location ->
                val uri = Uri.parse(location)
                require(uri.scheme == "content")
                var name = "file"
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) name = it.getString(0) ?: "file" }
                val output = File(root, "$index/${safeName(name)}")
                copy(uri, output)
                output.absolutePath
            }
        } catch (error: Exception) { root.deleteRecursively(); throw error }
    }

    private fun importFolder(location: String): String {
        val tree = Uri.parse(location)
        require(DocumentsContract.isTreeUri(tree))
        val id = DocumentsContract.getTreeDocumentId(tree)
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        var name = "folder"
        resolver.query(document, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) name = it.getString(0) ?: "folder" }
        val root = File(context.filesDir, "shared/${UUID.randomUUID()}")
        val folder = File(root, safeName(name))
        folder.mkdirs()
        val pending = ArrayDeque<Pair<String, File>>()
        pending.add(id to folder)
        var count = 0
        try {
            while (pending.isNotEmpty()) {
                val (parent, target) = pending.removeLast()
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
                resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use {
                    while (it.moveToNext()) {
                        require(++count <= 20000) { "Choose a smaller folder" }
                        val childId = it.getString(0)
                        val child = File(target, safeName(it.getString(1) ?: "file"))
                        require(!child.exists()) { "Duplicate file name" }
                        if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) { child.mkdirs(); pending.add(childId to child) }
                        else copy(DocumentsContract.buildDocumentUriUsingTree(tree, childId), child)
                    }
                } ?: throw IllegalArgumentException(NativeStrings.text(context, "Папка недоступна"))
            }
            return folder.absolutePath
        } catch (error: Exception) { root.deleteRecursively(); throw error }
    }
}
