# Nearbridge

Shared clipboard and file transfers for Android, Windows and Linux.

Copy text or an image on one computer, paste it on another. Pair your phone once and send files through Android's Share menu.

## Install

Download a build from [Releases](https://github.com/resassance/nearbridge/releases).

- Windows: extract the entire ZIP and run `nearbridge.exe`.
- Linux: extract the archive and run `nearbridge/nearbridge`. Requires GTK 3, the Ayatana AppIndicator runtime (`libayatana-appindicator3-1` on Debian/Ubuntu) and a compatible desktop session.
- Android: install the APK. Android 6 or newer. Starting with 0.3.0-alpha.1, APKs use a permanent signing key stored in GitHub Actions secrets. Upgrading from an earlier alpha may require one uninstall because its temporary certificate differs; subsequent releases retain app data and device pairing. Back up received files before uninstalling an earlier build.

Keep the app running. Use one local network or a private VPN connecting both devices; guest Wi-Fi may prevent devices from connecting. On Windows, choose **Разрешить локальные подключения** and approve the Windows administrator prompt. This adds app-specific inbound rules limited to the local subnet, without changing the firewall or network profile globally. Default ports: TCP 45831, UDP 45832. The actual listening port is shown below the QR and saved across restarts; if it changes because it is occupied, update the firewall rule.

## Pair

1. Choose **Добавить** on the computer.
2. Scan the QR code on the phone, or copy the connection code to the other device and choose **Ввести код**.
3. Approve the request on the first device.

Codes expire after five minutes and are single-use. Internet codes also contain the relay endpoint and an unguessable tunnel identifier. Closing the QR window does not revoke the copied code. Share them only with your own devices. If there are several network adapters, choose the address belonging to the same network as the other device.

New QR codes include alternative adapter addresses. Nearbridge probes them concurrently with certificate pinning, so an unreachable VPN adapter does not delay a reachable LAN adapter. Paired devices exchange updated addresses over authenticated connections and automatically reconnect through a working endpoint. Network probes have bounded timeouts and a short retry. Clipboard sends retry transient network failures with the same deduplicated message ID. A failed automatic clipboard send remains eligible for the next poll.

If pairing still times out, allow local-network traffic in VPN/WARP on both devices. WARP's local-network exclusion and a zapret filter that excludes private/VPN subnets are configuration requirements when those tools intercept the connection. Nearbridge uses direct sockets and never disables certificate checks. It cannot override a VPN kill switch, OS firewall, or packet filter that blocks every route. Connection errors include the destination address and can be tapped to show full details. Scan the PC's QR with the phone, then approve on the PC.

## Clipboard

Text and PNG images are transferred between paired devices. Automatic sending and receiving can be disabled globally or per device. Existing clipboard contents are not automatically sent on first connection; **Отправить буфер** sends them explicitly.

On Android 10+, ordinary apps cannot read another app's clipboard in the background. This release does not bypass that restriction. Open Nearbridge and choose **Отправить буфер**, use the notification / Quick Settings tile, or share content to Nearbridge. The tile opens the app before reading the clipboard. Automatic monitoring on Android runs only while Nearbridge is open. The foreground transfer service retains the Flutter engine after the window closes. Optional boot recovery and package-update recovery restart it. Force-stop, Doze and manufacturer battery restrictions can still interrupt availability; use the battery and notification status controls in the app.

Linux clipboard support depends on the desktop session. GNOME/Wayland background clipboard monitoring is not guaranteed in this alpha. There is no claim of universal Wayland support.

Clipboard images are limited to 8 MiB and text to 256 KiB. Some applications expose images as file references rather than PNG clipboard data; use file sharing in that case. Android clips marked sensitive are not sent. Sensitive detection on other platforms is not guaranteed: pause sharing before copying secrets.

## Files, folders and transfer queue

Select a device and choose **Выбрать файлы**, or drag files and folders onto its card on Windows/Linux. Android's Share menu adds files to the selected device's queue. Transfers can be paused, resumed, cancelled or retried. The queue survives app restarts; an interrupted active transfer is restored paused. Received folders retain their structure, including empty subfolders. A folder batch supports up to 20,000 items; select a smaller subtree for larger jobs.

Files support 64-bit sizes and offsets up to 8 TiB each, subject to filesystem limits and available space. Current devices transfer checked blocks of up to 4 MiB. Uploads keep a persistent offset on the receiver and are verified against the whole-file SHA-256 before completion. Downloads retain checked blocks and use versioned HTTP ranges; a changed source starts a new download rather than appending a different version. Acknowledged block uploads and completion requests are idempotent. Older devices can still send ordinary files and serve full-file downloads; resumable uploads require this version on both sides.

### Shared files and folders

On the source, open **Мои файлы и папки**, choose **Добавить файлы** or **Добавить папку**, and enable **Разрешить доступ к моим файлам и папкам**. On the receiver choose **Файлы устройства**. Open folders to navigate, use the download icon for one file or **Скачать папку** for a subtree, and load further pages with **Показать ещё**.

Sharing a folder includes its readable descendants and future files. Up to 50 folders and 200 individual files can be published. Absolute paths, traversal, symbolic links and Nearbridge's private data are excluded from the shared view. Each page contains at most 200 items. Files larger than 8 TiB, virtual Android documents and documents with unknown size are omitted.

On Android the system picker grants read access to the selected document tree and retains it across restarts. Protected storage roots remain subject to Android's restrictions. Folder contents are streamed rather than copied wholesale into the app. If a document provider disappears or Android revokes permission, choose the folder again.

### Device-specific and temporary access

Use **Кому доступно и срок** beside a shared item to select allowed paired devices and set an expiry of 15 minutes, one hour or one day. Unrestricted existing shares remain available to paired devices until configured otherwise. The rule applies to an entire shared subtree and is checked on browsing, search, preview and each new block request. Removing a share closes new access immediately. Expiry cannot erase files already received by another device.

The device menu can separately disable incoming file uploads or clipboard sharing. Global receipt and sharing switches still apply. **Забыть устройство** revokes its local authentication token.

### Search and previews

The remote browser searches names recursively through the selected shared folder, or through accessible roots from the main shared view. Large searches return a continuation button instead of blocking the interface indefinitely. Image thumbnails and a text preview appear before downloading. Images are decoded off the UI isolate and thumbnails are bounded to 400 pixels; text previews show at most 64 KiB. Unsupported formats remain downloadable.

### Automatic photo backup

Choose a source under **Резервное копирование фото**, choose the destination device and enable automatic copying. The app checks once a minute while running and connected, and **Проверить сейчас** starts a manual scan. JPEG, PNG, HEIC and WebP photos are queued into `Photos/year/month` on the receiver. Content hashes prevent sending a second copy of the same acknowledged photo to the same device. Originals are never removed or renamed. This is an additive backup, not two-way synchronization or deletion mirroring. Android activity/process lifetime and battery restrictions still affect background availability.

### Desktop background operation

Windows/Linux can keep Nearbridge in the system tray when its window closes. The tray menu reopens the window or exits the app. **Запускать вместе с системой** opts into autostart. Tray support depends on the Linux desktop's indicator support; if the tray cannot be created the window uses ordinary close behavior. File drops on a device card enqueue uploads without blocking other controls.

### Internet access without VPN

Set the HTTPS WebSocket address of a Nearbridge relay under **Настроить доступ без VPN**, then pair using the normal QR or connection code. A device without a configured relay adopts the address from the code. The app tries authenticated direct addresses alongside the relay and uses a working route. Both devices only need outgoing connections to the relay; private-network VPN access remains supported.

The relay forwards the devices' pinned TLS stream and does not decrypt clipboard or file contents. It can observe IP addresses, timing and traffic volume. The included Node server applies message-size, pending-connection and connection-count limits, with backpressure for binary forwarding. Public endpoints require `wss://`; `ws://` is permitted only on loopback for tests.

No public relay is bundled or deployed automatically. A server and domain are required. See [relay_server/README.md](relay_server/README.md) for the runnable server, Docker Compose and automatic HTTPS setup. WARP alone does not provide peer-to-peer connectivity. A VPN kill switch that blocks every available direct or relay route still requires an exclusion in that VPN.

## Data and connection

No account or cloud storage is required. An optional self-hosted relay forwards encrypted connections for internet access. TLS connections pin the certificate fingerprint from the pairing code. Paired devices use separate random authentication tokens for each direction. Device keys and pairing records live in the application's private support directory; received files live in its `inbox` subdirectory. Android backups are disabled. Clipboard contents are not written to history. Activity metadata is kept in memory for the current session.

Pairing grants file receipt and clipboard access to the selected device. **Забыть устройство** revokes its local token immediately. Disable receipt in the app to pause it. The protocol is new and has not undergone an independent security audit.

## Reliability and quick actions

The app checks GitHub releases when **Проверить обновления** is pressed and opens the official release page for installation. It does not execute downloaded code automatically. Settings and pairing records stay in the same application directory across updates. The Android build fails if signing secrets are absent or the APK certificate differs from the committed public certificate fingerprint. Keep a secure backup of the signing keystore and its password; do not rotate these secrets between releases.

Choose **Выбрать папку получения** and select rename, skip or replace for name conflicts. Rename is the default. Android uses a persisted read/write document-tree grant; supported document providers must allow temporary files and rename. Failed delivery retains the staged source for retry. Free-space preflight reserves room for staging and a checked final copy; Android document-provider quotas can remain unknown. A folder can therefore require roughly twice its largest active file's size temporarily. Existing files replaced by the explicit replace policy are not retained as version history.

The queue shows transferred bytes, average speed, estimated time and folder progress. Priority applies to waiting tasks, including the complete folder batch; it does not interrupt an active transfer. Speed limits pace checked blocks, so short bursts up to one block are possible. Repeat actions create a new transfer and require the original file or remote share to remain available. Favorite remote folders and recent recipients survive app restarts. Revoking a folder grant also blocks a saved favorite.

Network diagnostics show the selected direct LAN/VPN or relay route, ping latency and failure category. Direct adapter classification is advisory; encrypted overlays can use ordinary private addresses. The copied diagnostic report includes only platform, version, service state, route categories and timings. It excludes device names, addresses, filesystem paths, pairing codes, fingerprints and authentication tokens.

New photo transfers receive peer-bound receipts. **Проверить сохранённые копии** hashes the actual receiver-side file, detects deleted or modified copies and makes them eligible for copying again from the originals. **Копии и восстановление** downloads selected copies into `RestoredPhotos` in the receiving directory and validates the original digest. This can restore a copy even when the original source photo is gone. Both devices need this version for verification and restoration. Older backups without receipts remain unverified; successful upload alone is not a current integrity check. The transfer service does not bypass Android's background clipboard restrictions.

## Develop

Flutter 3.32.8, Python 3, and the usual Flutter toolchain for the target platform.

```sh
python tool/bootstrap.py
npm install --prefix relay_server
npm test --prefix relay_server
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
- Test and document supported Linux desktop sessions.
- Direct nearby transfer without an existing Wi-Fi router.

MIT License. Copyright 2026 Александр Орлов.

