**[Русская версия](README.ru.md)**

<p align="center"><img src="assets/icons/brand.png" width="96" height="96" alt="LinkInDrop logo"></p>
<h1 align="center">LinkInDrop</h1>
<p align="center">Files, folders and clipboard. Across your devices.</p>
<p align="center"><a href="https://github.com/resassance/LinkInDrop/releases">Downloads</a></p>

<p align="center">
  <a href="https://github.com/resassance/LinkInDrop/actions/workflows/build.yml"><img src="https://github.com/resassance/LinkInDrop/actions/workflows/build.yml/badge.svg?branch=main" alt="Build status"></a>
  <a href="https://github.com/resassance/LinkInDrop/releases"><img src="https://img.shields.io/github/v/release/resassance/LinkInDrop?label=release&color=2457ff" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b" alt="MIT license"></a>
</p>
<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.32.8-02569B?logo=flutter&logoColor=white" alt="Flutter 3.32.8">
  <img src="https://img.shields.io/badge/Dart-3.8-0175C2?logo=dart&logoColor=white" alt="Dart 3.8">
  <img src="https://img.shields.io/badge/Kotlin-Android-7F52FF?logo=kotlin&logoColor=white" alt="Kotlin for Android">
  <img src="https://img.shields.io/badge/Node.js-22+-5FA04E?logo=nodedotjs&logoColor=white" alt="Node.js 22 or later">
</p>

LinkInDrop connects Android, Windows and Linux devices for file transfers and a shared clipboard. Pair once, select a recipient, review your files and send. Connect over your local network, a private VPN linking your devices, or an optional self-hosted relay for remote access.

**Version 1.0.0.** Install the current version on each device. You can update an existing LinkInDrop installation without removing it; saved settings and paired devices are kept. Both devices must be running for transfers and remote browsing.

## Contents

- [Features](#features)
- [Install](#install)
- [Connect and transfer](#connect-and-transfer)
- [Remote access and VPN](#remote-access-and-vpn)
- [Privacy and access](#privacy-and-access)
- [Technology](#technology)
- [Build from source](#build-from-source)
- [Project structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

## Features

| Feature | What it does |
| --- | --- |
| Files and folders | Add files with a picker, desktop drag-and-drop or Android Share. Review photo thumbnails and documents before sending. |
| Remote file browser | Browse explicitly shared files and folders on paired devices. Search, preview, download and save favorite folders. |
| Shared clipboard | Send text and images. Automatic exchange is optional and configurable. |
| Transfer queue | Pause, resume, retry and prioritize transfers. Show progress, speed and estimated time; resume verified blocks. |
| Received files | Open the destination quickly and optionally sort loose files into type-based folders. Transferred folder trees stay intact. |
| Photo backup | Copy photos with their original names and folder tree, including separate copies at different paths. Originals stay on the source device. |
| Background operation | Use the desktop tray or enable Android's foreground service, battery exemption and optional boot recovery. |
| Appearance | Compact desktop/mobile navigation, light/dark/system themes and Russian/English/system language preferences. |

## Install

Get packages and SHA-256 checksums from [Releases](https://github.com/resassance/LinkInDrop/releases).

| Platform | Package | Start |
| --- | --- | --- |
| Windows x64 | `linkindrop-*-windows-x64.zip` | Extract the entire archive and run `LinkInDrop.exe`. |
| Linux x64 | `linkindrop-*-linux-x64.tar.gz` | Extract and run `LinkInDrop/LinkInDrop`. Requires GTK 3 and an AppIndicator-compatible desktop session. |
| Android 6+ | `linkindrop-*-android.apk` | Install the APK. Allow installation from the app used to download it. |

On Debian/Ubuntu, Linux runtime dependencies include `libgtk-3-0` and `libayatana-appindicator3-1`; package names vary by distribution. Official APKs use the permanent project signing key, so they can be installed over earlier LinkInDrop versions.

## Connect and transfer

1. Open LinkInDrop on both devices and connect them to networks they can reach each other on.
2. Choose **Add device**. Scan its QR code or enter its pairing code on the other device.
3. Approve the request. Invitations expire after five minutes.
4. Select a recipient, add files or a folder, review the selection and press **Transfer**.
5. For browsing, enable sharing on the source device and choose the files or folders to expose. Open **Device files** from the other device.

On Windows, use **Allow local connections** if needed. Administrator approval creates application-specific inbound firewall rules for the local subnet. Default ports are TCP `45831` and UDP `45832`; the actual listening port can differ. Guest Wi-Fi and client isolation may prevent connections.

### Photo backup

Select a source folder and a destination device in Settings, then enable automatic photo backup. Selecting `DCIM` saves photos as `DCIM/Camera/photo.jpg`, `DCIM/Screenshots/screenshot.png`, and so on inside the destination’s receive folder. Names and subfolders stay intact; unchanged files at the same path are not copied again. Files outside the supported photo formats are not included.

Backups made by earlier versions remain in their existing folders. The next backup also creates copies in the original folder tree; it does not remove or move existing files.

## Remote access and VPN

For internet access, configure the same self-hosted relay on your devices, or connect them through a private network such as Tailscale and set the remote address. See [relay deployment](relay_server/README.md). LinkInDrop does not include a hosted relay service.

**NekoBox on Android:** allow LAN bypass or exclude `dev.resassance.linkindrop` from VPN app routing. Optional direct Wi-Fi mode binds all LinkInDrop traffic to physical Wi-Fi/Ethernet while available, then returns to the system route. Other apps' routing stays unchanged. Android VPN lockdown or a VPN that forbids bypass can still block connections.

Enable Android background operation explicitly. Battery exemption and notifications help keep transfers alive, but manufacturer restrictions and force-stop can interrupt them. Photo backup has an independent toggle.

## Privacy and access

- Device connections use TLS with pinned device certificates and authenticated tokens. Pairing requires approval.
- Remote browsing exposes selected files and folders. Limit access per device, set expiry times or revoke grants.
- The relay forwards the encrypted connection without decrypting contents. Its operator can observe connection metadata and traffic volume.
- Received files stay in the selected destination. New files and changes inside a shared folder may become visible while its grant remains active.

## Technology

| Layer | Stack |
| --- | --- |
| App and UI | Flutter, Dart, Material 3, Flutter localizations |
| Android | Kotlin, Storage Access Framework, foreground service, DocumentsProvider |
| Desktop | `window_manager`, `tray_manager`, `desktop_drop`, `launch_at_startup` |
| Transfers | Dart sockets/HTTP, TLS, certificate pinning, SHA-256, resumable blocks |
| Optional relay | Node.js 22+, WebSocket (`ws`), Docker Compose, Caddy |
| Checks and packaging | Flutter Test, Python tools, GitHub Actions |

## Build from source

Use Flutter **3.32.8**, Python 3 and platform build tools. Android needs Java 17 and the Android SDK; Windows needs Visual Studio desktop C++ tools; Linux needs Clang, CMake, Ninja and GTK/AppIndicator development headers.

```sh
git clone https://github.com/resassance/LinkInDrop.git
cd LinkInDrop
python tool/bootstrap.py
flutter pub get
flutter run
```

Run the checks:

```sh
python tool/check_design.py
python -m unittest tool/bootstrap_test.py tool/signing_test.py
npm install --prefix relay_server
npm test --prefix relay_server
flutter analyze --no-fatal-infos
flutter test --timeout 2m
```

Build with `flutter build windows --release`, `flutter build linux --release` or `flutter build apk --release`. Run `python tool/package.py windows`, `linux` or `android` to create packages and checksums in `dist/`. Local Android builds without release credentials use development signing; official builds use the pinned release key.

## Project structure

| Path | Purpose |
| --- | --- |
| [`lib/ui/`](lib/ui/) | Responsive screens and themes |
| [`lib/core/`](lib/core/) | Pairing, transport, queue, sharing and backup |
| [`lib/l10n/`](lib/l10n/) | Russian/English strings and formatting |
| [`platform_assets/android/`](platform_assets/android/) | Native Android integration and icons |
| [`relay_server/`](relay_server/) | Optional relay and deployment |
| [`test/`](test/) · [`tool/`](tool/) | Tests, validation, signing and packaging |

## Contributing



## License

[MIT](LICENSE). Copyright © 2026 Александр Орлов.
