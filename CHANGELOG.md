# Changelog

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
- Remove existing source comments and record the rule in AGENTS.md.

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
