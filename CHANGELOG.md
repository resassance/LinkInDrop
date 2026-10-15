# Changelog

## Unreleased

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
