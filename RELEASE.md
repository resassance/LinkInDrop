Nearbridge 0.3.0-alpha.1 for Android, Windows and Linux.

- Permanent Android release signing and manual update checks.
- Network route/latency diagnostics with a report that excludes keys, tokens, names, addresses and paths.
- Selected receive folders, rename/skip/replace policies and free-space checks.
- Queue priorities, speed, remaining-time estimates, whole-folder progress and bandwidth limits.
- Files larger than 2 GiB using 64-bit offsets, up to 8 TiB subject to storage limits.
- Receiver-side SHA-256 verification of photo backups and restoration to RestoredPhotos.
- Android transfer engine retained after the window closes, opt-in boot recovery and battery/notification status.
- Favorite remote folders, recent recipients and repeat transfers.

Update both devices. Upgrading Android from 0.2 or earlier may require one uninstall because earlier APKs used temporary signing certificates; back up received files first. From this release onward the signing certificate is stable and updates preserve application data and pairing. Android force-stop and manufacturer power restrictions can still stop background availability. Background clipboard reading remains unavailable.

Rename is the default conflict policy; replacing an existing file requires selecting Replace in settings. Receiving uses staging and a verified final copy, so reserve roughly twice the active file size temporarily. Android document-provider quotas may be unknown; writable providers must support temporary documents and renaming. Old backups without receipts cannot be verified retroactively. Speed limits pace blocks and allow short bursts.

Internet access without a VPN still requires a deployed Nearbridge relay. Its server and Docker/HTTPS instructions are included; no public relay is deployed automatically.

Windows: extract the complete ZIP. Linux: GTK 3 and the Ayatana AppIndicator runtime are required (libayatana-appindicator3-1 on Debian/Ubuntu). Desktop builds are unsigned. Download the platform package and its SHA-256 file.
