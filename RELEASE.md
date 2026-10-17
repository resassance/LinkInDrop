# LinkInDrop 0.3.0-alpha.4

## Русский

Новый дизайн для ПК и телефона, предпросмотр файлов перед отправкой, светлая и тёмная темы, русский и английский интерфейс с выбором языка системы.

- Полное переименование приложения, Android ID, кодов подключения, сетевого протокола и файлов сборки.
- Папки и файлы на привязанных устройствах, очередь передач, фотобэкап и работа в фоне сохранены.
- Настройки находятся внизу навигации на ПК; кнопка полученных файлов выровнена с заголовком передачи на телефоне.
- README на двух языках: оглавление, технологии, установка, NekoBox и инструкции по сборке.

### Установка

Это отдельное приложение с ID `dev.resassance.linkindrop` и протоколом версии 2. Установите новый APK и новые сборки на все устройства, затем заново выполните привязку. Старые версии несовместимы. Сохраните полученные файлы перед удалением прежней установки; внутренние данные автоматически не переносятся. Одновременный запуск старой и новой версий может занять те же сетевые порты, поэтому закройте прежнее приложение.

Для NekoBox разрешите LAN или исключите `dev.resassance.linkindrop` из VPN. Android может запрещать обход VPN даже при выбранном прямом Wi-Fi. Для передачи в фоне включите службу и необходимые разрешения.

Windows: распакуйте ZIP целиком и запустите `LinkInDrop.exe`. Linux: запустите `LinkInDrop/LinkInDrop`; нужны GTK 3 и AppIndicator. APK подписан постоянным ключом проекта. Для каждого пакета приложен SHA-256.

## English

New desktop/mobile design, selected-file previews, persistent light/dark/system themes and Russian/English/system language preferences. The project, application identifiers, pairing scheme, protocol and package names now use LinkInDrop throughout.

This release uses a separate Android application ID, `dev.resassance.linkindrop`, and protocol version 2. Install it on every device and pair again. Old versions cannot connect. Private data is not migrated automatically; save received files before removing a previous installation. Close the previous app to avoid competing for the same network ports.

Windows, Linux and Android packages include SHA-256 checksums. APK signing is verified against the permanent project certificate. Native background behavior and VPN restrictions still depend on device settings. Visual comparison with the approved design remains pending; this is an alpha release.
