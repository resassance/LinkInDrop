Nearbridge 0.1.0-alpha.3 for Android, Windows and Linux.

- Pair and reconnect through alternative LAN/VPN adapter addresses in parallel, with bounded retries and pinned TLS.
- Keep the listening port stable across restarts and show it below the QR.
- Retry transient clipboard sends and preserve changes after failed automatic delivery.
- Publish selected files to paired devices and browse/download their shared files with progress, cancellation and one retry after a network interruption.
- Verify and save a remote IPv4/DNS endpoint for access through a private VPN such as Tailscale.

Update both devices. File sharing is off by default: add files under «Мои общие файлы» and enable sharing on the source device, then select it and open «Файлы устройства» on the receiver. Only explicitly selected files are exposed to paired devices.

Keep both apps running on a reachable LAN or private VPN. WARP alone does not connect remote peers. If WARP/VPN/zapret blocks local or VPN traffic, configure exclusions; Nearbridge cannot override a kill switch or blocked route. The Windows LAN firewall rule does not include VPN peers automatically. Allow the actual TCP port from the intended VPN peer if needed.

Downloads retry from the beginning once; uploads interrupted after sending bytes need a new send. Offset resume and automatic NAT traversal are not included. Android background clipboard reading is not supported; the send action opens the app. GNOME/Wayland background monitoring is not guaranteed. Desktop builds are unsigned; Android builds use a development signing key.

Download the build for your platform and its `.sha256` file. Windows users must extract the complete ZIP.

