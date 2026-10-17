# Changelog

## 1.0.0

- Keep the Android gallery scroll position and selected album while choosing photos.
- Show recent photos and videos newest first with stable pagination.
- Preserve original photo names and the selected source folder tree in automatic backups.
- Keep separate copies of identical photos in different source folders.
- Refresh desktop and Android controls, spacing, navigation, settings, dropdowns and the app icon.
- Add the Android attachment gallery, album selection and media previews.
- Separate text editing from instant clipboard sending and expose the receive-folder picker on Received.
- Add recent media thumbnails and fix Android receive-folder paths.
- Link separate English and Russian READMEs from the top of each file.

## 0.3.0-alpha.4

- Introduce the LinkInDrop desktop/mobile design with selected-file previews and explicit send confirmation.
- Add persistent light/dark/system themes and Russian/English/system language preferences.
- Use one shared logo for the app, Android launcher, desktop icons and tray.
- Rename the Dart package, Android application ID, pairing scheme, protocol headers, discovery identity and package outputs.
- Start a separate application profile and pairing protocol version 2; install on every device and pair again.
- Publish English and Russian READMEs with navigation, technology badges, setup and build instructions.
- Preserve the permanent Android signing key under the new key alias and verify the packaged certificate.
- Require a successful main-branch build at the exact release tag before uploading release artifacts.

## 0.3.0-alpha.3

- Open the receive directory from the transfer panel; expose the Android private inbox through a read-only DocumentsProvider.
- Mark the desktop drop zone and allow choosing a recipient after dropping files.
- Compact the dashboard and collapse clipboard, settings and diagnostic sections.
- Use a full-screen mobile file browser, wide filenames and a single action menu per row.
- Sort loose incoming files into media/document/archive/application categories while preserving transferred folder trees.
- Add an explicit Android direct Wi-Fi mode with route status and NekoBox LAN guidance; other apps retain their VPN route.
- Open the tray context menu on right-click with a complete application exit action.

## 0.3.0-alpha.2

- Stabilize the page scrollbar and preserve scroll position during transfer updates.
- Adapt queue and remote-folder actions to narrow windows and avoid dropdown overflow.
- Disabling photo backup now interrupts scanning and pauses its queued transfers; enabling resumes only automatically paused jobs.
- Keep remote browsing available during other operations, select the only paired device automatically and offer a device chooser.
- Start the transfer controller independently of UI frames for Android boot recovery.
- Persist Android document-file grants for remote browsing and downloading, and enable sharing when content is added.
- Keep Android CPU and Wi-Fi available while the background service is enabled, expose battery exemption and notification settings, and show transfer progress in its notification.

## 0.3.0-alpha.1

- Pin a permanent Android signing certificate and verify every release APK; add manual GitHub update checks.
- Add selected receive directories, Android writable document-tree export, conflict policies and free-space preflight.
- Report route, latency and connection failures with a redacted diagnostic export.
- Add queue priority, transfer rates, time estimates, folder progress and configurable bandwidth limits.
- Support 64-bit file sizes and offsets up to 8 TiB.
- Verify photo copies with peer-bound receipts and restore them with SHA-256 validation.
- Retain the Android Flutter engine in the foreground service, optionally recover after boot/update, and show battery/notification status.
- Save favorite remote folders, recent recipients and repeat actions.

## 0.2.0-alpha.1

- Resume checked file blocks and persist transfer queues with pause, retry and cancellation.
- Upload/download entire folder trees, including empty directories.
- Add desktop tray operation, opt-in autostart and dropping files onto device cards.
- Add per-device sharing rules, expiring file/folder grants and per-device upload receipt controls.
- Search shared folder names recursively and preview image thumbnails or bounded text.
- Back up selected photo folders automatically, deduplicating acknowledged content while preserving originals.
- Pair and connect without VPN through an optional self-hosted WebSocket relay that forwards pinned TLS bytes.
- Include the Node relay, tests and HTTPS deployment configuration.

- Select shared folders on Windows/Linux or Android's system document picker; keep grants after a restart.
- Browse nested folders, return to parents, refresh and load additional directory pages.
- Download files directly from a selected folder without copying its whole subtree into app storage.
- Revoke an entire folder grant, reject traversal and symlinks, and keep app-private storage outside the shared view.
- Keep individual-file sharing compatible with alpha.3 devices.

## 0.1.0-alpha.3

- Probe alternative LAN/VPN adapter addresses concurrently during pairing and reconnection, with pinned TLS and device authentication.
- Refresh peer addresses over authenticated health checks; keep the listening port stable across restarts and show it beside the QR.
- Retry transient clipboard failures without discarding the pending clipboard change.
- Publish selected files to paired devices, browse their shared files, and pull downloads with progress, cancellation and one network retry.
- Configure and verify a remote IPv4/DNS endpoint for access through a private VPN such as Tailscale.
- Keep file sharing disabled by default; reject app-private files, symbolic-link substitutions and paths supplied in place of file IDs.
- Document WARP/zapret routing exclusions and VPN firewall requirements. A completely blocked route still requires configuration of the blocking software.

Interrupted uploads require a new send; interrupted downloads retry from the beginning. Offset resume and automatic NAT traversal remain future work.
