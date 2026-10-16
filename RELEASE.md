Nearbridge 0.2.0-alpha.1 for Android, Windows and Linux.

- Resume checked file blocks after interruptions; persist transfer queues with pause, retry and cancellation.
- Transfer complete folder trees, including empty directories.
- Keep the desktop app in the tray, opt into autostart, and drop files or folders onto a device card.
- Limit shared files and folders to selected devices and set temporary access.
- Search shared folders recursively and preview images or text before downloading.
- Back up selected photo folders automatically without deleting originals or resending acknowledged content.
- Pair through a self-hosted internet relay without a VPN, with pinned device TLS preserved end to end.
- Remove source comments and record the no-comments rule in AGENTS.md.

Update both devices for resumable uploads and the new browser. File sharing and photo backup require explicit selection and enabling. Direct LAN/VPN transfers remain supported. For internet access a deployed Nearbridge relay is required; the server, tests, Docker Compose and HTTPS configuration are included in relay_server/. No public relay has been deployed automatically.

Android battery/process restrictions still affect background availability, and its document picker may restrict protected folders. Linux tray availability depends on the desktop. Desktop builds are unsigned and Android builds use a development signing key.

Download the build for your platform and its SHA-256 file. Windows users must extract the complete ZIP.
Linux requires GTK 3 and the Ayatana AppIndicator runtime (`libayatana-appindicator3-1` on Debian/Ubuntu).
