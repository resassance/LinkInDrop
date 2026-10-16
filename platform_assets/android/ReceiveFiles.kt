package dev.resassance.nearbridge

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import java.util.Locale
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class ReceiveFiles(private val context: Context) {
    private val resolver = context.contentResolver
    private val directoryMime = DocumentsContract.Document.MIME_TYPE_DIR
    private fun digest(uri: Uri): String {
        val hash = MessageDigest.getInstance("SHA-256")
        resolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
        } ?: throw IllegalArgumentException("Нет доступа к копии")
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
    private fun root(tree: String): Uri {
        val uri = Uri.parse(tree)
        if (!DocumentsContract.isTreeUri(uri) || resolver.persistedUriPermissions.none { it.uri == uri && it.isWritePermission && it.isReadPermission }) throw SecurityException("Выберите папку получения заново")
        return DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
    }
    private fun parts(path: String): List<String> {
        val result = path.split('/')
        if (path.length > 2048 || result.any { it.isEmpty() || it == "." || it == ".." || it.contains('\\') || it.contains(':') }) throw IllegalArgumentException("Invalid destination")
        return result
    }
    private fun find(parent: Uri, name: String): Pair<Uri, Boolean>? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(1) == name) return Pair(DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(0)), cursor.getString(2) == directoryMime)
        }
        return null
    }
    private fun folder(parent: Uri, name: String): Uri {
        val found = find(parent, name)
        if (found != null) {
            if (!found.second) throw IllegalArgumentException("Вместо папки уже существует файл")
            return found.first
        }
        return DocumentsContract.createDocument(resolver, parent, directoryMime, name) ?: throw IllegalArgumentException("Не удалось создать папку")
    }
    fun handle(call: MethodCall): Any? {
        if (call.method == "verifyReceived") {
            return try { digest(Uri.parse(call.argument<String>("location")!!)) == call.argument<String>("digest") } catch (_: Exception) { false }
        }
        var parent = root(call.argument<String>("tree")!!)
        val path = parts(call.argument<String>("relative")!!)
        if (call.method == "createReceivedDirectory") {
            for (part in path) parent = folder(parent, part)
            return null
        }
        for (part in path.dropLast(1)) parent = folder(parent, part)
        var name = path.last()
        var existing = find(parent, name)
        if (existing?.second == true) throw IllegalArgumentException("Вместо файла уже существует папка")
        val policy = call.argument<String>("policy") ?: "rename"
        if (existing != null && policy == "skip") return mapOf("location" to existing.first.toString(), "skipped" to true)
        if (existing != null && policy != "replace") {
            val index = name.lastIndexOf('.')
            val stem = if (index > 0) name.substring(0, index) else name
            val extension = if (index > 0) name.substring(index) else ""
            var number = 1
            do { name = "$stem (${number++})$extension"; existing = find(parent, name) } while (existing != null)
        }
        val source = File(call.argument<String>("source")!!)
        val privateRoot = context.filesDir.canonicalFile
        if (!source.canonicalPath.startsWith(privateRoot.path + File.separator)) throw SecurityException("Invalid source")
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.ROOT)) ?: "application/octet-stream"
        val temporary = DocumentsContract.createDocument(resolver, parent, mime, ".nearbridge-${UUID.randomUUID()}") ?: throw IllegalArgumentException("Не удалось создать файл")
        var oldBackup: Uri? = null
        try {
            resolver.openOutputStream(temporary, "wt")?.use { output -> source.inputStream().use { it.copyTo(output, 65536) } } ?: throw IllegalArgumentException("Нет разрешения на запись")
            if (digest(temporary) != call.argument<String>("digest")) throw IllegalStateException("Контрольная сумма копии не совпала")
            if (existing != null) oldBackup = DocumentsContract.renameDocument(resolver, existing.first, ".nearbridge-old-${UUID.randomUUID()}") ?: throw IllegalArgumentException("Не удалось сохранить предыдущий файл")
            val target = DocumentsContract.renameDocument(resolver, temporary, name) ?: throw IllegalArgumentException("Не удалось завершить получение")
            oldBackup?.let { try { DocumentsContract.deleteDocument(resolver, it) } catch (_: Exception) {} }
            return mapOf("location" to target.toString(), "skipped" to false)
        } catch (error: Exception) {
            oldBackup?.let { try { DocumentsContract.renameDocument(resolver, it, name) } catch (_: Exception) {} }
            try { DocumentsContract.deleteDocument(resolver, temporary) } catch (_: Exception) {}
            throw error
        }
    }
}
