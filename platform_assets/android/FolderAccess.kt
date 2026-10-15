package dev.resassance.nearbridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

// The system document picker grants read access to one tree. Relative paths are
// resolved one child at a time under that tree; client input never becomes a URI.
class FolderAccess(private val activity: Activity) {
    private val resolver = activity.contentResolver
    private val worker = Executors.newFixedThreadPool(3)
    private val readers = ConcurrentHashMap<String, InputStream>()
    private var picker: MethodChannel.Result? = null
    private val requestCode = 7314
    private val maxSize = 2147483648L
    private val directoryMime = DocumentsContract.Document.MIME_TYPE_DIR
    private val columns = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_FLAGS
    )

    private data class Document(val id: String, val name: String, val directory: Boolean,
        val size: Long?, val virtual: Boolean)

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method == "pickFolder") {
            if (picker != null) { result.error("folder_busy", "Выбор папки уже открыт", null); return true }
            picker = result
            try {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                activity.startActivityForResult(intent, requestCode)
            } catch (error: Exception) {
                picker = null
                result.error("folder", error.message, null)
            }
            return true
        }
        if (call.method !in setOf("checkFolder", "revokeFolder", "listFolder", "openFolderFile",
                "readFolderFile", "closeFolderFile")) return false
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "checkFolder" -> { root(call.argument<String>("uri")!!); null }
                    "revokeFolder" -> {
                        val uri = Uri.parse(call.argument<String>("uri")!!)
                        if (resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) {
                            resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        null
                    }
                    "listFolder" -> list(call.argument<String>("uri")!!,
                        call.argument<String>("path") ?: "", call.argument<Int>("offset") ?: 0)
                    "openFolderFile" -> open(call.argument<String>("uri")!!, call.argument<String>("path")!!)
                    "readFolderFile" -> {
                        val id = call.argument<String>("reader")!!
                        val input = readers[id] ?: throw IllegalStateException("Чтение файла закрыто")
                        val bytes = ByteArray(256 * 1024)
                        val count = input.read(bytes)
                        if (count < 0) { readers.remove(id)?.close(); null } else bytes.copyOf(count)
                    }
                    "closeFolderFile" -> { readers.remove(call.argument<String>("reader")!!)?.close(); null }
                    else -> null
                }
                activity.runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread { result.error("folder", error.message ?: "Папка недоступна", null) }
            }
        }
        return true
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        worker.execute {
            try {
                val read = ((data?.flags ?: 0) and Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (read == 0) throw SecurityException("Нет разрешения на чтение папки")
                resolver.takePersistableUriPermission(uri, read)
                val info = describe(root(uri.toString()))
                activity.runOnUiThread { result.success(mapOf("uri" to uri.toString(), "name" to info.name)) }
            } catch (error: Exception) {
                activity.runOnUiThread { result.error("folder", error.message, null) }
            }
        }
        return true
    }

    private fun root(location: String): Uri {
        val uri = Uri.parse(location)
        if (uri.scheme != "content" || !DocumentsContract.isTreeUri(uri) ||
            resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) {
            throw SecurityException("Доступ к папке отозван. Выберите папку заново.")
        }
        return DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
    }

    private fun validPath(path: String): Boolean = path.length <= 2048 &&
        !Regex("[\\\\:\\x00-\\x1f\\x7f]").containsMatchIn(path) &&
        (path.isEmpty() || path.split('/').all { it.isNotEmpty() && it != "." && it != ".." && it.length <= 255 })

    private fun describe(uri: Uri): Document {
        resolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return Document(cursor.getString(0), cursor.getString(1) ?: "file",
                cursor.getString(2) == directoryMime, if (cursor.isNull(3)) null else cursor.getLong(3),
                (cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0)
        }
        throw IllegalArgumentException("Папка или файл недоступны")
    }

    private fun children(parent: Uri): Uri = DocumentsContract.buildChildDocumentsUriUsingTree(
        parent, DocumentsContract.getDocumentId(parent))

    private fun resolve(location: String, path: String): Uri {
        if (!validPath(path)) throw IllegalArgumentException("Недопустимый путь")
        var current = root(location)
        for (part in path.split('/').filter { it.isNotEmpty() }) {
            if (!describe(current).directory) throw IllegalArgumentException("Это не папка")
            var next: String? = null
            resolver.query(children(current), columns, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (cursor.getString(1) == part) { next = cursor.getString(0); break }
                }
            }
            current = DocumentsContract.buildDocumentUriUsingTree(current,
                next ?: throw IllegalArgumentException("Папка или файл больше не доступны"))
        }
        return current
    }

    private fun list(location: String, path: String, offset: Int): Map<String, Any?> {
        if (offset < 0 || offset > 100000) throw IllegalArgumentException("Недопустимая страница")
        val parent = resolve(location, path)
        if (!describe(parent).directory) throw IllegalArgumentException("Это не папка")
        val items = mutableListOf<Map<String, Any>>()
        var skipped = 0
        var more = false
        resolver.query(children(parent), columns, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                val relative = if (path.isEmpty()) name else "$path/$name"
                val directory = cursor.getString(2) == directoryMime
                val size = if (directory) 0L else if (cursor.isNull(3)) continue else cursor.getLong(3)
                val virtual = (cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0
                if (!validPath(relative) || size < 0 || size > maxSize || virtual) continue
                if (skipped++ < offset) continue
                if (items.size == 200) { more = true; break }
                items.add(mapOf("name" to name.takeLast(120), "relativePath" to relative,
                    "directory" to directory, "size" to size))
            }
        } ?: throw IllegalArgumentException("Нет доступа к папке")
        return mapOf("files" to items, "nextOffset" to if (more) offset + 200 else null)
    }

    private fun open(location: String, path: String): Map<String, Any> {
        if (path.isEmpty()) throw IllegalArgumentException("Выберите файл")
        if (readers.size >= 2) throw IllegalStateException("Дождитесь текущих скачиваний")
        val uri = resolve(location, path)
        val info = describe(uri)
        val size = info.size ?: throw IllegalArgumentException("Размер файла неизвестен")
        if (info.directory || info.virtual || size < 0 || size > maxSize) {
            throw IllegalArgumentException("Файл недоступен или больше 2 ГБ")
        }
        val input = resolver.openInputStream(uri) ?: throw IllegalArgumentException("Нет доступа к файлу")
        val id = UUID.randomUUID().toString()
        readers[id] = input
        return mapOf("reader" to id, "size" to size)
    }

    fun close() {
        picker?.error("folder", "Выбор папки закрыт", null)
        picker = null
        readers.values.forEach { try { it.close() } catch (_: Exception) {} }
        readers.clear()
        worker.shutdownNow()
    }
}
