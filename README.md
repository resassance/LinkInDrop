# Nearbridge

Shared clipboard and file transfers for Android, Windows and Linux.

Copy text or an image on one computer, paste it on another. Pair your phone once and send files through Android's Share menu.

## Install

Download a build from [Releases](https://github.com/resassance/nearbridge/releases).

- Windows: extract the entire ZIP and run `nearbridge.exe`.
- Linux: extract the archive and run `nearbridge/nearbridge`. Requires GTK 3 and a compatible desktop session.
- Android: install the APK. Android 6 or newer. Alpha APKs use a development signing key; replacing a build may require uninstalling it and pairing again.

Keep the app running. Use one local network; guest Wi-Fi may prevent devices from connecting. Allow Nearbridge through the Windows firewall on private networks. Default ports: TCP 45831, UDP 45832.

## Pair

1. Choose **Добавить** on the computer.
2. Scan the QR code on the phone, or copy the connection code to the other device and choose **Ввести код**.
3. Approve the request on the first device.

Codes expire after five minutes and are single-use. Share them only with your own devices. If there are several network adapters, choose the address belonging to the same network as the other device.

## Clipboard

Text and PNG images are transferred between paired devices. Automatic sending and receiving can be disabled globally or per device. Existing clipboard contents are not automatically sent on first connection; **Отправить буфер** sends them explicitly.

On Android 10+, ordinary apps cannot read another app's clipboard in the background. This release does not bypass that restriction. Open Nearbridge and choose **Отправить буфер**, use the notification / Quick Settings tile, or share content to Nearbridge. The tile opens the app before reading the clipboard. Automatic monitoring on Android runs only while Nearbridge is open. Foreground service availability and background receiving depend on Android's battery restrictions.

Linux clipboard support depends on the desktop session. GNOME/Wayland background clipboard monitoring is not guaranteed in this alpha. There is no claim of universal Wayland support.

Clipboard images are limited to 8 MiB and text to 256 KiB. Some applications expose images as file references rather than PNG clipboard data; use file sharing in that case. Android clips marked sensitive are not sent. Sensitive detection on other platforms is not guaranteed: pause sharing before copying secrets.

## Files

Choose a recipient and **Выбрать файлы**, or share files to Nearbridge on Android. Files stream over the local connection, with a 2 GiB limit per file. Received files appear in **Последние передачи**. File receipt does not open or execute them automatically. Transfers interrupted by a disconnect must be sent again.

## Data and connection

No accounts, relay server or cloud storage. TLS connections pin the certificate fingerprint from the pairing code. Paired devices use separate random authentication tokens for each direction. Device keys and pairing records live in the application's private support directory; received files live in its `inbox` subdirectory. Android backups are disabled. Clipboard contents are not written to history. Activity metadata is kept in memory for the current session.

Pairing grants file receipt and clipboard access to the selected device. **Забыть устройство** revokes its local token immediately. Disable receipt in the app to pause it. The protocol is new and has not undergone an independent security audit.

## Develop

Flutter 3.32.8, Python 3, and the usual Flutter toolchain for the target platform.

```sh
python tool/bootstrap.py
flutter pub get
flutter test
flutter run -d linux
```

`tool/bootstrap.py` creates platform runners and installs the Android integration. Platform runners are generated, not stored in the repository. `super_clipboard` uses native code and may install its Rust/NDK dependencies on the first build.

```sh
flutter build apk --release
flutter build linux --release
flutter build windows --release
```

The build workflow runs analysis and tests before packaging all three targets. Releases include SHA-256 checksum files. The tests cover pairing, certificate mismatch, clipboard validation and deduplication, file transfer, token revocation, and compact/desktop layouts.

## Next

- Android automatic clipboard access: investigate an optional advanced setup without replacing the user's keyboard.
- Tray, autostart and drag-and-drop.
- Transfer resume and richer file history.
- Test and document supported Linux desktop sessions.
- Direct nearby transfer without an existing Wi-Fi router.

MIT License. Copyright 2026 Александр Орлов.
