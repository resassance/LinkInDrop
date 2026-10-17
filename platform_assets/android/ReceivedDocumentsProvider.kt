package dev.resassance.linkindrop

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

class ReceivedDocumentsProvider : DocumentsProvider() {
    private val root get() = File(context!!.filesDir, "inbox").apply { mkdirs() }.canonicalFile
    private val documentColumns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
    override fun onCreate(): Boolean = true
    private fun resolve(id: String): File {
        if (id != "received" && !id.startsWith("received:")) throw FileNotFoundException()
        val relative = if (id == "received") "" else id.substringAfter(':')
        if (relative.startsWith('/') || relative.split('/').any { it == ".." || it == "." || it.startsWith('.') }) throw FileNotFoundException()
        val file = if (relative.isEmpty()) root else File(root, relative)
        val canonical = file.canonicalFile
        if (file.absolutePath != canonical.path || (canonical != root && !canonical.path.startsWith(root.path + File.separator)) || !file.exists()) throw FileNotFoundException()
        return file
    }
    private fun id(file: File): String = if (file == root) "received" else "received:" + file.relativeTo(root).path.replace(File.separatorChar, '/')
    private fun mime(file: File): String = if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
    private fun row(cursor: MatrixCursor, file: File) {
        val values = mapOf<String, Any>(DocumentsContract.Document.COLUMN_DOCUMENT_ID to id(file),
            DocumentsContract.Document.COLUMN_DISPLAY_NAME to if (file == root) NativeStrings.text(context!!, "LinkInDrop — Полученные") else file.name,
            DocumentsContract.Document.COLUMN_MIME_TYPE to mime(file), DocumentsContract.Document.COLUMN_FLAGS to 0,
            DocumentsContract.Document.COLUMN_SIZE to if (file.isFile) file.length() else 0L, DocumentsContract.Document.COLUMN_LAST_MODIFIED to file.lastModified())
        val row = cursor.newRow()
        for (column in cursor.columnNames) row.add(column, values[column])
    }
    override fun queryRoots(projection: Array<out String>?): Cursor {
        val columns = projection ?: arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_DOCUMENT_ID,
            DocumentsContract.Root.COLUMN_TITLE, DocumentsContract.Root.COLUMN_FLAGS, DocumentsContract.Root.COLUMN_ICON, DocumentsContract.Root.COLUMN_MIME_TYPES, DocumentsContract.Root.COLUMN_AVAILABLE_BYTES)
        val cursor = MatrixCursor(columns)
        val values = mapOf<String, Any>(DocumentsContract.Root.COLUMN_ROOT_ID to "received", DocumentsContract.Root.COLUMN_DOCUMENT_ID to "received",
            DocumentsContract.Root.COLUMN_TITLE to NativeStrings.text(context!!, "LinkInDrop — Полученные"), DocumentsContract.Root.COLUMN_FLAGS to DocumentsContract.Root.FLAG_LOCAL_ONLY,
            DocumentsContract.Root.COLUMN_ICON to R.drawable.tile_icon, DocumentsContract.Root.COLUMN_MIME_TYPES to "*/*", DocumentsContract.Root.COLUMN_AVAILABLE_BYTES to root.usableSpace)
        val row = cursor.newRow()
        for (column in columns) row.add(column, values[column])
        return cursor
    }
    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor = MatrixCursor(projection ?: documentColumns).apply { row(this, resolve(documentId)) }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val parent = resolve(parentDocumentId)
        if (!parent.isDirectory) throw FileNotFoundException()
        return MatrixCursor(projection ?: documentColumns).apply {
            for (file in parent.listFiles()?.sortedWith(compareBy<File> { !it.isDirectory }.thenBy { it.name.lowercase() }) ?: emptyList()) {
                try { row(this, resolve(id(file))) } catch (_: FileNotFoundException) {}
            }
        }
    }
    override fun getDocumentType(documentId: String): String = mime(resolve(documentId))
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read only")
        val file = resolve(documentId)
        if (!file.isFile) throw FileNotFoundException()
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }
}
