package dev.resassance.nearbridge

import android.content.Context
import android.os.Build
import java.util.Locale

object NativeStrings {
    private val english = mapOf(
        "Android не разрешил прямой маршрут. Проверьте настройки NekoBox и запрет соединений без VPN." to "Android did not allow direct routing. Check NekoBox settings and Block connections without VPN.",
        "VPN запрещает обход. Разрешите LAN или исключите LinkInDrop в NekoBox." to "The VPN blocks bypassing. Allow LAN access or exclude LinkInDrop in NekoBox.",
        "Выбор папки уже открыт" to "The folder picker is already open",
        "Откройте LinkInDrop для выбора папки" to "Open LinkInDrop to choose a folder",
        "Размер файла неизвестен" to "Unknown file size",
        "Файл недоступен" to "File unavailable",
        "Чтение файла закрыто" to "The file reader is closed",
        "Папка недоступна" to "Folder unavailable",
        "Нет разрешения на запись папки" to "No permission to write to this folder",
        "Нет разрешения на чтение папки" to "No permission to read this folder",
        "Доступ к файлу отозван. Выберите файл заново." to "File access was revoked. Choose the file again.",
        "Доступ к папке отозван. Выберите папку заново." to "Folder access was revoked. Choose the folder again.",
        "Папка или файл недоступны" to "Folder or file unavailable",
        "Недопустимый путь" to "Invalid path",
        "Это не папка" to "This is not a folder",
        "Папка или файл больше не доступны" to "This folder or file is no longer available",
        "Недопустимая страница" to "Invalid page",
        "Нет доступа к папке" to "No access to this folder",
        "Выберите файл" to "Choose a file",
        "Дождитесь текущих скачиваний" to "Wait for the current downloads",
        "Файл недоступен или больше 8 ТБ" to "This file is unavailable or larger than 8 TB",
        "Нет доступа к файлу" to "No access to this file",
        "Выбор папки закрыт" to "The folder picker was closed",
        "LinkInDrop — Полученные" to "LinkInDrop — Received",
        "Нет доступа к копии" to "No access to this copy",
        "Выберите папку получения заново" to "Choose the received folder again",
        "Вместо папки уже существует файл" to "A file already exists in place of this folder",
        "Не удалось создать папку" to "Could not create folder",
        "Вместо файла уже существует папка" to "A folder already exists in place of this file",
        "Не удалось создать файл" to "Could not create file",
        "Нет разрешения на запись" to "No write permission",
        "Контрольная сумма копии не совпала" to "The copy checksum does not match",
        "Не удалось сохранить предыдущий файл" to "Could not preserve the previous file",
        "Не удалось завершить получение" to "Could not finish receiving",
        "Отправить буфер" to "Send clipboard",
        "Подключение устройств" to "Device connection",
        "Служба передачи файлов работает" to "File transfer service is running",
        "Ожидание устройств" to "Waiting for devices",
        "Не больше 100 файлов за раз" to "Choose no more than 100 files at a time",
        "Лимит файла — 8 ТБ" to "The file size limit is 8 TB"
    )
    fun text(context: Context, key: String): String {
        val language = context.getSharedPreferences("connection", Context.MODE_PRIVATE).getString("language", "system")
        var selected = language
        if (selected == "system") {
            selected = "en"
            if (Build.VERSION.SDK_INT >= 24) {
                val locales = context.resources.configuration.locales
                for (index in 0 until locales.size()) {
                    val code = locales[index].language
                    if (code == "ru" || code == "en") { selected = code; break }
                }
            } else if (Locale.getDefault().language == "ru") selected = "ru"
        }
        return if (selected == "ru") key else english[key] ?: key
    }
}
